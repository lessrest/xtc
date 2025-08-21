const std = @import("std");
const c = @import("wren.zig");
const TrackingAllocator = @import("../lib/TrackingAllocator.zig");

/// Wren allocator wrapper that integrates with Zig's allocator system.
///
/// This module provides the memory management bridge between Wren's C-style
/// allocation callbacks and Zig's allocator interface, using TrackingAllocator
/// for proper memory tracking.
pub const WrenAllocator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WrenAllocator {
        return .{ .allocator = allocator };
    }
};
