const std = @import("std");
const miniflex = @import("miniflex");
const dom = miniflex.dom;
const WindowType = miniflex.Window;
const Engine = @import("fiberscript/vm.zig");
const ansi = @import("ansi");
const builtin = @import("builtin");
const Context = Engine.Context;
const Request = Engine.Request;

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

var nest: ansi.nest.TreeNest = undefined;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) void {
    logprint(level, scope, format, args) catch unreachable;
}

fn logprint(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) !void {
    try nest.dk().log(level, scope, format, args);
    try nest.writer.flush();
}

const log = std.log.scoped(.wasm);

pub const has_threads = !builtin.single_threaded;

const ScriptConfig = struct {
    module: []const u8,
    source: []const u8,
};

const SessionInput = union(enum) {
    script: ScriptConfig,
    default: void,
};

const default_script =
    \\import "dom" for Document, Element, Text, Window
    \\Window.immediately {
    \\  Document.root.classes = "flex flex-col items-center justify-center h-full bg-gray-900"
    \\  var panel = Document.createElement("p-2 text-gray-200")
    \\  panel.append(Document.createText("xtc wasm ready"))
    \\  Document.root.append(panel)
    \\}
;

pub const WasmLiveSession = struct {
    allocator: std.mem.Allocator,
    config: Config,
    document: ?*dom.Dom = null,
    window: ?*WindowType = null,
    context: ?*Context = null,
    engine: ?*Engine = null,
    is_initialized: bool = false,
    needs_present: bool = false,

    pub const Config = struct {
        output: OutputConfig,
    };

    pub const OutputConfig = struct {
        width: usize,
        height: usize,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) WasmLiveSession {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn initSession(self: *WasmLiveSession, input: SessionInput) !void {
        self.deinit();
        errdefer self.deinit();

        const document = try dom.Dom.init(self.allocator);
        self.document = document;

        const context_ptr = try self.allocator.create(Context);
        context_ptr.* = Context.init(self.allocator, document);
        context_ptr.setViewport(self.config.output.width, self.config.output.height);
        self.context = context_ptr;

        const engine_ptr = try Engine.init(self.allocator, .{ .context = context_ptr });
        self.engine = engine_ptr;

        const window_ptr = try self.allocator.create(WindowType);
        window_ptr.* = try WindowType.init(self.allocator, .{
            .width = self.config.output.width,
            .height = self.config.output.height,
        });
        self.window = window_ptr;

        switch (input) {
            .script => |script| try self.runTopLevel(script.module, script.source),
            .default => try self.runTopLevel("main", default_script),
        }

        try self.flushEngineOutput();

        self.is_initialized = true;
        self.needs_present = true;
    }

    pub fn processFrame(self: *WasmLiveSession) !bool {
        if (!self.is_initialized) return false;
        try self.pumpFibers();

        const document = self.document orelse return false;
        if (document.dirty) {
            self.needs_present = true;
        }

        return self.needs_present;
    }

    pub fn render(self: *WasmLiveSession) !void {
        if (!self.is_initialized) return;
        const document = self.document orelse return;
        const window = self.window orelse return;

        var out_buf: [4096]u8 = undefined;
        var out_state = std.fs.File.stdout().writer(&out_buf);
        const out: *std.Io.Writer = &out_state.interface;

        try window.renderAndPresent(document, 0, out);
        try out.flush();
        self.needs_present = false;
    }

    pub fn handleKeypress(self: *WasmLiveSession, key: u8) void {
        _ = self;
        _ = key;
    }

    pub fn handleResize(self: *WasmLiveSession, width: usize, height: usize) !void {
        if (!self.is_initialized) return;
        if (self.window) |window| {
            try window.setViewport(width, height);
        }
        if (self.context) |context| {
            context.setViewport(width, height);
        }
        if (self.document) |document| {
            document.dirty = true;
        }
        self.config.output.width = width;
        self.config.output.height = height;
        self.needs_present = true;
    }

    pub fn deinit(self: *WasmLiveSession) void {
        if (self.engine) |engine| {
            if (self.context) |context| {
                context.deinit();
            }
            engine.deinit();
            self.engine = null;
        }

        if (self.context) |context| {
            self.allocator.destroy(context);
            self.context = null;
        }

        if (self.window) |win| {
            win.deinit();
            self.allocator.destroy(win);
            self.window = null;
        }

        if (self.document) |doc| {
            doc.deinit();
            self.document = null;
        }

        self.is_initialized = false;
        self.needs_present = false;
    }

    fn runTopLevel(self: *WasmLiveSession, module: []const u8, source: []const u8) !void {
        const engine = self.engine orelse return error.MissingEngine;
        try engine.runTopLevel(module, source);
        try engine.checkError();
    }

    fn pumpFibers(self: *WasmLiveSession) !void {
        const engine = self.engine orelse return;
        const context = self.context orelse return;

        try self.runThunks(engine, context);
        try self.resumeFrameFibers(engine, context);
        try self.flushEngineOutput();
    }

    fn runThunks(self: *WasmLiveSession, engine: *Engine, context: *Context) !void {
        const thunks = try context.thunks.toOwnedSlice(self.allocator);
        defer if (thunks.len != 0) self.allocator.free(thunks);

        for (thunks) |fiber| {
            try runFiberOnce(engine, fiber);
            if (try fiberIsDone(engine, context, fiber)) {
                fiber.deinit(engine.vm);
            }
        }
    }

    fn resumeFrameFibers(self: *WasmLiveSession, engine: *Engine, context: *Context) !void {
        const fibers = try context.drainFrameFibers();
        defer if (fibers.len != 0) self.allocator.free(fibers);

        for (fibers) |fiber| {
            try runFiberOnce(engine, fiber);

            if (try fiberIsDone(engine, context, fiber)) {
                fiber.deinit(engine.vm);
            }
        }
    }

    fn flushEngineOutput(self: *WasmLiveSession) !void {
        const engine = self.engine orelse return;
        const output = try engine.takeOutput(self.allocator);
        defer if (output.len != 0) self.allocator.free(output);

        if (output.len == 0) return;

        var out_buf: [512]u8 = undefined;
        var out_state = std.fs.File.stdout().writer(&out_buf);
        const out: *std.Io.Writer = &out_state.interface;
        try out.writeAll(output);
        try out.flush();
    }
};

fn runFiberOnce(engine: *Engine, fiber: Engine.FiberID) !void {
    var slots = engine.slots();
    _ = slots.set(0, fiber);
    var fiber_result = try slots.call("call()").asForeign(Request);
    while (fiber_result) |req| {
        const result = try engine.syscaller.dispatch(req.*, fiber, &slots);
        switch (result) {
            .immediate => |res| {
                _ = slots.set(0, fiber);
                _ = slots.set(1, res);
                fiber_result = try slots.call("call(_)").asForeign(Request);
            },
            .pending => {
                break;
            },
        }
    }
}

fn fiberIsDone(engine: *Engine, context: *Context, fiber: Engine.FiberID) !bool {
    var slots = engine.slots();
    _ = slots.set(0, fiber);
    return try slots.callWithHandle(context.methodHandle(.isDone)).as(bool);
}

// WASM exports

var global_live_session: ?WasmLiveSession = null;

export fn main() c_int {
    return 0;
}

export fn clock() i64 {
    return @as(i64, @intFromFloat(@floor(js_performance_now() * 1_000_000)));
}

extern fn js_performance_now() f64;

export fn xtc_hello() void {
    var out_buf: [256]u8 = undefined;
    var out_state = std.fs.File.stdout().writer(&out_buf);
    const out: *std.Io.Writer = &out_state.interface;
    out.print("XTC WASM Live Session Ready!\n", .{}) catch return;
    out.flush() catch {};
}

export fn xtc_init_session(
    script_ptr: [*]const u8,
    script_len: usize,
    module_ptr: [*]const u8,
    module_len: usize,
    width: u32,
    height: u32,
) c_int {
    nest = ansi.nest.stderr(global_allocator);
    nest.no_color = true;

    const script_bytes = script_ptr[0..script_len];
    const module_bytes = module_ptr[0..module_len];

    if (global_live_session) |*session| {
        session.deinit();
    }

    global_live_session = initLiveSessionWasm(script_bytes, module_bytes, width, height) catch |err| {
        var err_buf: [256]u8 = undefined;
        var err_state = std.fs.File.stderr().writer(&err_buf);
        const stderr: *std.Io.Writer = &err_state.interface;
        stderr.print("Init session error: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return -1;
    };

    return 0;
}

export fn xtc_process_frame() c_int {
    if (global_live_session) |*session| {
        const needs_render = session.processFrame() catch |err| {
            var err_buf: [256]u8 = undefined;
            var err_state = std.fs.File.stderr().writer(&err_buf);
            const stderr: *std.Io.Writer = &err_state.interface;
            stderr.print("process frame error: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            session.engine.?.croak() catch {};
            return -1;
        };
        return if (needs_render) 1 else 0;
    }
    return -1;
}

export fn xtc_render_frame() c_int {
    if (global_live_session) |*session| {
        session.render() catch |err| {
            var err_buf: [256]u8 = undefined;
            var err_state = std.fs.File.stderr().writer(&err_buf);
            const stderr: *std.Io.Writer = &err_state.interface;
            stderr.print("Render frame error: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return -1;
        };
        return 0;
    }
    return -1;
}

export fn xtc_keypress(key: u8) c_int {
    if (global_live_session) |*session| {
        session.handleKeypress(key);
        return 0;
    }
    return -1;
}

export fn xtc_resize(width: u32, height: u32) c_int {
    if (global_live_session) |*session| {
        session.handleResize(@as(usize, @intCast(width)), @as(usize, @intCast(height))) catch |err| {
            var err_buf: [256]u8 = undefined;
            var err_state = std.fs.File.stderr().writer(&err_buf);
            const stderr: *std.Io.Writer = &err_state.interface;
            stderr.print("Resize error: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return -1;
        };
        return 0;
    }
    return -1;
}

export fn xtc_cleanup() void {
    if (global_live_session) |*session| {
        session.deinit();
        global_live_session = null;
    }
}

fn initLiveSessionWasm(script: []const u8, module_name: []const u8, width: u32, height: u32) !WasmLiveSession {
    const config = WasmLiveSession.Config{
        .output = .{
            .width = @as(usize, @intCast(width)),
            .height = @as(usize, @intCast(height)),
        },
    };

    var session = WasmLiveSession.init(global_allocator, config);
    if (script.len == 0) {
        try session.initSession(.default);
    } else {
        const module = if (module_name.len == 0) "main" else module_name;
        try session.initSession(.{ .script = .{ .module = module, .source = script } });
    }

    spawnDemoThread();

    return session;
}

var global_allocator = std.heap.raw_c_allocator;

fn spawnDemoThread() void {
    if (!has_threads) return;

    const config = std.Thread.SpawnConfig{
        .stack_size = 128 * 1024,
        .allocator = global_allocator,
    };

    const thread = std.Thread.spawn(config, wasmThreadMain, .{}) catch |err| {
        log.err("failed to spawn wasm thread: {}", .{err});
        return;
    };
    thread.detach();
}

fn wasmThreadMain() !void {
    var out_buf: [256]u8 = undefined;
    var out_state = std.fs.File.stderr().writer(&out_buf);
    const out: *std.Io.Writer = &out_state.interface;

    const tid = std.Thread.getCurrentId();
    try out.print("wasm thread {d} started\n", .{tid});
    try out.flush();

    var tick: usize = 0;
    while (tick < 3) : (tick += 1) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        try out.print("wasm thread {d} tick {d}\n", .{ tid, tick + 1 });
        try out.flush();
    }

    try out.print("wasm thread {d} finished\n", .{tid});
    try out.flush();
}

export fn wasm_alloc(size: usize) ?[*]u8 {
    const slice = global_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, size: usize) void {
    const slice = ptr[0..size];
    global_allocator.free(slice);
}
