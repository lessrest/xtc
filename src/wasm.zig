const std = @import("std");
const ansi = @import("ansi");
const live = @import("lib/live_session.zig");
const LiveSession = live.LiveSession;

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

pub const has_threads = live.has_threads;

const ScriptConfig = live.ScriptConfig;
const SessionInput = live.SessionInput;
const default_script = live.default_script;

pub const WasmLiveSession = LiveSession;

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
