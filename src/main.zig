const std = @import("std");
const lib = @import("lib.zig");
const Graphemes = @import("Graphemes");
const live = @import("live.zig");
const tty = @import("tty.zig");

// Global logging options using std.log
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = myLogFn,
};

pub var g_log_file: ?std.fs.File = null; // set at runtime by --log
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
    var xml_input: ?[]const u8 = null;
    var out_width: usize = 80;
    var out_height: usize = 24;
    var unicode_boxes: ?bool = null; // tri-state: null => default

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
        } else if (std.mem.eql(u8, a, "--xml")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing string after --xml\n", .{});
                std.process.exit(2);
            }
            xml_input = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--width")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing number after --width\n", .{});
                std.process.exit(2);
            }
            out_width = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch {
                try std.io.getStdErr().writer().print("invalid --width value: {s}\n", .{args[i + 1]});
                std.process.exit(2);
                unreachable;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--height")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing number after --height\n", .{});
                std.process.exit(2);
            }
            out_height = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch {
                try std.io.getStdErr().writer().print("invalid --height value: {s}\n", .{args[i + 1]});
                std.process.exit(2);
                unreachable;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--unicode-boxes")) {
            unicode_boxes = true;
        } else if (std.mem.eql(u8, a, "--no-unicode-boxes")) {
            unicode_boxes = false;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.io.getStdOut().writer().print(
                "usage: xtc [--log <file>] [--xml <string>] [--width N] [--height N] [--[no-]unicode-boxes]\n",
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
        // Always create/truncate the log file to start fresh
        opened = std.fs.cwd().createFile(lp, .{ .truncate = true, .read = false, .exclusive = false }) catch null;
        if (opened) |f| {
            g_log_file = f;
            std.log.info("logging to {s}", .{lp});
        }
    }
    defer if (opened) |f| f.close();
    // Apply unicode boxes preference if specified (applies to both modes)
    if (unicode_boxes) |on| tty.setUseUnicodeBoxes(on);

    if (xml_input) |xml| {
        const out = try lib.renderXmlAscii(al, xml, out_width, out_height);
        defer al.free(out);
        _ = try std.io.getStdOut().write(out);
        return;
    }

    try live.run(al);
}
