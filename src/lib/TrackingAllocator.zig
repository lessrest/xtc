const std = @import("std");

allocator: std.mem.Allocator,

const Header = struct {
    size: u64,
};

const header_size = @sizeOf(Header);
const alignment = std.mem.Alignment.fromByteUnits(8);

pub fn alloc(self: @This(), size: usize) ?[*]u8 {
    const total_size = header_size + size;
    const slice = self.allocator.rawAlloc(
        total_size,
        alignment,
        @returnAddress(),
    ) orelse return null;

    const header: *Header = @ptrCast(@alignCast(slice));
    header.size = @intCast(size);

    return slice + header_size;
}

pub fn realloc(self: @This(), old_ptr: [*]u8, new_size: usize) ?[*]u8 {
    // Get old size from header
    const old_header_ptr = old_ptr - header_size;
    const old_header: *Header = @ptrCast(@alignCast(old_header_ptr));
    const old_size: usize = @intCast(old_header.size);

    // Allocate new memory
    const new_ptr = self.alloc(new_size) orelse return null;

    // Copy old data
    const copy_size = @min(old_size, new_size);
    @memcpy(new_ptr[0..copy_size], old_ptr[0..copy_size]);

    // Free old allocation
    const old_slice = old_header_ptr[0 .. header_size + old_size];
    self.allocator.rawFree(old_slice, alignment, @returnAddress());

    return new_ptr;
}

pub fn free(self: @This(), ptr: [*]u8) void {
    const header_ptr = ptr - header_size;
    const header: *Header = @ptrCast(@alignCast(header_ptr));
    const size: usize = @intCast(header.size);

    const slice = header_ptr[0 .. header_size + size];
    self.allocator.rawFree(slice, alignment, @returnAddress());
}
