const std = @import("std");
const c = @import("wren.zig");

/// Output buffer management for capturing Wren print statements.
///
/// This module handles text output from Wren's System.print() and related
/// functions, providing buffering and retrieval capabilities.
pub const OutputHandler = struct {
    buffer: std.heap.FixedBufferAllocator,
    current_output: std.ArrayListUnmanaged(u8) = .{},

    pub const Options = struct {
        buffer_size: usize = 1024 * 32,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !OutputHandler {
        return OutputHandler{
            .buffer = std.heap.FixedBufferAllocator.init(
                try allocator.alloc(u8, options.buffer_size),
            ),
        };
    }

    pub fn deinit(self: *OutputHandler, allocator: std.mem.Allocator) void {
        self.current_output.deinit(self.buffer.allocator());
        allocator.free(self.buffer.buffer);
    }

    /// C callback function for Wren's write operations.
    ///
    /// This is called when Wren executes System.print() or other output functions.
    /// Captures the text in an internal buffer for later retrieval.
    pub fn writeFn(self: *OutputHandler, vm: *c.VM, text: [*:0]const u8) callconv(.C) void {
        const str = std.mem.span(text);
        self.write(vm, str);
    }

    pub fn write(self: *OutputHandler, vm: *c.VM, text: []const u8) void {
        const allocator = self.buffer.allocator();
        self.current_output.appendSlice(allocator, text) catch {
            // If buffer is full, abort the fiber with an error
            const message = "output buffer full";
            c.wrenEnsureSlots(vm, 1);
            c.wrenSetSlotString(vm, 1, message);
            c.wrenAbortFiber(vm, 1);
        };
    }

    /// Retrieves accumulated output and clears the internal buffer.
    ///
    /// The caller owns the returned memory and must free it with the provided allocator.
    pub fn takeOutput(self: *OutputHandler, allocator: std.mem.Allocator) ![]const u8 {
        const output = try allocator.dupe(u8, self.current_output.items);
        self.current_output.clearAndFree(self.buffer.allocator());
        return output;
    }

    /// Clears the output buffer without returning the contents.
    pub fn clearOutput(self: *OutputHandler) void {
        self.current_output.clearAndFree(self.buffer.allocator());
    }

    /// Returns the current output length without consuming it.
    pub fn outputLength(self: *OutputHandler) usize {
        return self.current_output.items.len;
    }
};
