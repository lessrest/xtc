const std = @import("std");
const lib = @import("lib.zig");
const Graphemes = @import("Graphemes");
const live = @import("live.zig");

// Global logging options using std.log
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = myLogFn,
};

var g_log_file: ?std.fs.File = null; // set at runtime by --log
fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const ts = std.time.timestamp();
    const prefix = "[" ++ comptime level.asText() ++ "](" ++ @tagName(scope) ++ ") ";
    if (g_log_file) |*f| {
        var bw = std.io.bufferedWriter(f.writer());
        const w = bw.writer();
        w.print(format ++ "\n", args) catch unreachable;
        bw.flush() catch {};
        return;
    }
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    _ = stderr.print("{d} " ++ prefix ++ format ++ "\n", .{ts} ++ args) catch {};
}

// Ensure panics leave the terminal in a readable state when running in raw + alt screen.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    // Best-effort: reset attributes, show cursor, and exit alt screen buffer.
    // We cannot restore cooked termios here without the saved state, but this greatly improves readability.
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write("\x1b[0m\x1b[?25h\x1b[?1049l\n") catch {};
    // Print panic and stack trace similarly to std.debug.defaultPanic.
    _ = stderr.write("panic: ") catch {};
    _ = stderr.print("{s}\n", .{msg}) catch {};
    if (error_return_trace) |t| std.debug.dumpStackTrace(t.*);
    std.debug.dumpCurrentStackTrace(return_address);
    std.posix.abort();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const args = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, args);

    var log_path: ?[]const u8 = "xtc.log";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--log")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing path after --log\n", .{});
                std.process.exit(2);
            }
            log_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.io.getStdOut().writer().print(
                "usage: xtc [--log <file>]\n",
                .{},
            );
            return;
        } else {
            try std.io.getStdErr().writer().print("unknown argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }

    // Initialize optional log file for std.log override
    var opened: ?std.fs.File = null;
    if (log_path) |lp| {
        opened = std.fs.cwd().createFile(lp, .{ .truncate = false, .read = false, .exclusive = false }) catch |e| blk: {
            if (e == error.PathAlreadyExists) {
                break :blk std.fs.cwd().openFile(lp, .{ .mode = .write_only }) catch null;
            }
            break :blk null;
        };
        if (opened) |f| {
            _ = f.seekFromEnd(0) catch {};
            g_log_file = f;
            std.log.info("logging to {s}", .{lp});
        }
    }
    defer if (opened) |f| f.close();
    try live.run(al);
}
