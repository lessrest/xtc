const std = @import("std");

pub fn trace(comptime src: std.builtin.SourceLocation, comptime _name: []const u8, _args: anytype) Tracer {
    _ = src;
    _ = _name;
    _ = _args;
    return .{};
}

pub const Tracer = struct {
    pub fn end(_: *const Tracer) void {}
};
