const std = @import("std");

/// Global log file handle
var g_log_file: ?std.fs.File = null;

/// Set the global log file
pub fn setLogFile(file: std.fs.File) void {
    g_log_file = file;
}

/// Custom log function that writes to file if configured
pub fn logFn(
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

/// Custom panic handler that ensures terminal is readable
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    // Best-effort: reset attributes, show cursor, and exit alt screen buffer
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write("\x1b[0m\x1b[?25h\x1b[?1049l\n") catch {};
    
    // Print panic and stack trace
    _ = stderr.write("panic: ") catch {};
    _ = stderr.print("{s}\n", .{msg}) catch {};
    
    if (error_return_trace) |t| {
        std.debug.dumpStackTrace(t.*);
    }
    std.debug.dumpCurrentStackTrace(return_address);
    std.posix.abort();
}