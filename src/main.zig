const std = @import("std");
const app = @import("app.zig");
const logging = @import("logging.zig");

comptime {
    _ = @import("fiberscript/vm.zig");
}

/// Global logging configuration
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

/// Override panic handler for clean terminal exit
pub const panic = logging.panic;

/// Main entry point - simple boot and delegate
pub fn main() !void {
    // Initialize memory management
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    // Create and run application
    var application = try app.Application.init(allocator);
    defer application.deinit();

    try application.run();
}
