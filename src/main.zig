const std = @import("std");
const ansi = @import("ansi");

const Engine = @import("fiberscript/vm.zig");
const miniflex = @import("miniflex");
const dom = miniflex.dom;
const c = @import("fiberscript/wren.zig");

test {
    _ = @import("miniflex");
    _ = @import("fiberscript/wren.zig");
    _ = @import("fiberscript/vm.zig");
    _ = @import("test/flex.test.zig");
}

pub const version = "0.5.0";

pub const panic = ansi.panic;

const log = std.log.scoped(.xtc);

pub const std_options: std.Options = .{
    .log_level = .debug,
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // arena
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    nest = ansi.nest.stderr(arena.allocator());

    var err_buf: [512]u8 = undefined;
    var err_state = std.fs.File.stderr().writer(&err_buf);
    const stderr: *std.Io.Writer = &err_state.interface;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const program = try allocator.dupe(u8, args.next() orelse "xtc");
    defer allocator.free(program);

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stderr.print("{s} v{s}\n", .{ program, version });
            try stderr.flush();
            return;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.print("Usage: {s} <file>\n", .{program});
            try stderr.flush();
            return;
        }

        if (std.mem.endsWith(u8, arg, ".wren")) {
            return run_script(allocator, arg);
        }
    }

    try stderr.print("Usage: {s} <file>\n", .{program});
    try stderr.flush();
    return error.Usage;
}

pub fn run_script(allocator: std.mem.Allocator, script_path: []const u8) !void {
    var document = try dom.Dom.init(allocator);
    defer document.deinit();

    var context: Engine.Context = .{
        .document = document,
        .allocator = allocator,
        .vm = undefined,
    };

    var engine = try Engine.init(allocator, .{ .context = &context });
    defer engine.deinit();
    defer context.deinit();

    const file_path = if (std.fs.path.isAbsolute(script_path))
        try allocator.dupe(u8, script_path)
    else
        try std.fs.cwd().realpathAlloc(allocator, script_path);
    defer allocator.free(file_path);

    const file_content = try std.fs.cwd().readFileAlloc(allocator, script_path, 1024 * 1024);
    defer allocator.free(file_content);

    log.info("running top-level script {s}", .{script_path});
    try engine.runTopLevel("main", file_content);

    const thunks = try context.thunks.toOwnedSlice(allocator);
    defer allocator.free(thunks);

    log.info("{d} thunk fibers in queue", .{thunks.len});
    for (thunks) |fiber| {
        var slots = engine.slots();
        _ = slots.set(0, fiber);
        log.warn("calling {s}", .{fiber.ticket});
        defer log.warn("called {s}", .{fiber.ticket});
        try slots.call("call()").checkSuccess();
        fiber.deinit(engine.vm);
    }

    log.info(
        "joining {d} background threads",
        .{engine.context.background_threads.items.len},
    );
    try engine.context.joinBackgroundThreads();
    log.info("done", .{});
    try nest.newline();
    try nest.writer.flush();

    log.info("winding down", .{});
}
