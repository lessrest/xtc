const std = @import("std");

pub const Graphemes = struct {
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};
pub const DisplayWidth = struct {
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};
pub const Words = struct {
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        _ = allocator; // autofix
        self.* = undefined;
    }
};
