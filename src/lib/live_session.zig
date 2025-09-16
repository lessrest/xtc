const std = @import("std");
const builtin = @import("builtin");
const miniflex = @import("miniflex");
const dom = miniflex.dom;
const WindowType = miniflex.Window;
const Engine = @import("../fiberscript/vm.zig");
const Context = Engine.Context;
const Request = Engine.Request;

pub const has_threads = !builtin.single_threaded;

pub const ScriptConfig = struct {
    module: []const u8,
    source: []const u8,
};

pub const SessionInput = union(enum) {
    script: ScriptConfig,
    default: void,
};

pub const default_script =
    \\\\import "dom" for Document, Element, Text, Window
    \\\\Window.immediately {
    \\\\  Document.root.classes = "flex flex-col items-center justify-center h-full bg-gray-900"
    \\\\  var panel = Document.createElement("p-2 text-gray-200")
    \\\\  panel.append(Document.createText("xtc wasm ready"))
    \\\\  Document.root.append(panel)
    \\\\}
;

pub const LiveSession = struct {
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

    pub fn init(allocator: std.mem.Allocator, config: Config) LiveSession {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn initSession(self: *LiveSession, input: SessionInput) !void {
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

    pub fn processFrame(self: *LiveSession) !bool {
        if (!self.is_initialized) return false;
        try self.pumpFibers();

        const document = self.document orelse return false;
        if (document.dirty) {
            self.needs_present = true;
        }

        return self.needs_present;
    }

    pub fn render(self: *LiveSession) !void {
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

    pub fn handleKeypress(self: *LiveSession, key: u8) void {
        _ = self;
        _ = key;
    }

    pub fn handleResize(self: *LiveSession, width: usize, height: usize) !void {
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

    pub fn hasPendingWork(self: *LiveSession) bool {
        const context = self.context orelse return false;
        if (context.thunks.items.len != 0) return true;
        if (context.frame_fibers.items.len != 0) return true;
        return false;
    }

    pub fn joinBackgroundThreads(self: *LiveSession) !void {
        if (self.context) |context| {
            try context.joinBackgroundThreads();
        }
    }

    pub fn deinit(self: *LiveSession) void {
        if (self.engine) |engine| {
            if (self.context) |context| {
                context.joinBackgroundThreads() catch {};
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

    fn runTopLevel(self: *LiveSession, module: []const u8, source: []const u8) !void {
        const engine = self.engine orelse return error.MissingEngine;
        try engine.runTopLevel(module, source);
        try engine.checkError();
    }

    fn pumpFibers(self: *LiveSession) !void {
        const engine = self.engine orelse return;
        const context = self.context orelse return;

        try runThunks(self.allocator, engine, context);
        try resumeFrameFibers(self.allocator, engine, context);
        try self.flushEngineOutput();
    }

    fn flushEngineOutput(self: *LiveSession) !void {
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

pub fn runThunks(allocator: std.mem.Allocator, engine: *Engine, context: *Context) !void {
    const thunks = try context.thunks.toOwnedSlice(allocator);
    defer if (thunks.len != 0) allocator.free(thunks);

    for (thunks) |fiber| {
        try runFiberOnce(engine, fiber);
        if (try fiberIsDone(engine, context, fiber)) {
            fiber.deinit(engine.vm);
        }
    }
}

pub fn resumeFrameFibers(allocator: std.mem.Allocator, engine: *Engine, context: *Context) !void {
    const fibers = try context.drainFrameFibers();
    defer if (fibers.len != 0) allocator.free(fibers);

    for (fibers) |fiber| {
        try runFiberOnce(engine, fiber);

        if (try fiberIsDone(engine, context, fiber)) {
            fiber.deinit(engine.vm);
        }
    }
}

pub fn runFiberOnce(engine: *Engine, fiber: Engine.FiberID) !void {
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

pub fn fiberIsDone(engine: *Engine, context: *Context, fiber: Engine.FiberID) !bool {
    var slots = engine.slots();
    _ = slots.set(0, fiber);
    return try slots.callWithHandle(context.methodHandle(.isDone)).as(bool);
}

pub fn flushEngineOutput(
    allocator: std.mem.Allocator,
    engine: *Engine,
    out: *std.Io.Writer,
) !bool {
    const output = try engine.takeOutput(allocator);
    defer if (output.len != 0) allocator.free(output);

    if (output.len == 0) return false;

    try out.writeAll(output);
    try out.flush();
    return true;
}
