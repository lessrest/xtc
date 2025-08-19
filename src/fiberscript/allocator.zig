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

    /// C callback function for Wren's memory allocation needs.
    /// 
    /// Handles allocation, reallocation, and deallocation according to Wren's
    /// memory management contract:
    /// - memory=null, new_size>0: allocate new memory
    /// - memory!=null, new_size>0: reallocate existing memory  
    /// - memory!=null, new_size=0: free memory
    /// - memory=null, new_size=0: no-op, return null
    pub fn reallocateFn(
        memory: ?*anyopaque,
        new_size: usize,
        user_data: *anyopaque,
    ) callconv(.C) ?*anyopaque {
        const self: *WrenAllocator = @ptrCast(@alignCast(user_data));
        var tracked = TrackingAllocator.create(self.allocator);
        
        if (memory) |mem| {
            const ptr: [*]u8 = @ptrCast(mem);
            if (new_size == 0) {
                // Free memory
                tracked.free(ptr);
                return null;
            } else {
                // Reallocate memory
                return tracked.realloc(ptr, new_size);
            }
        } else {
            if (new_size == 0) {
                // No-op case
                return null;
            }
            // Allocate new memory
            return tracked.alloc(new_size);
        }
    }
};