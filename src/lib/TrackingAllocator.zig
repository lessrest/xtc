/// This allocator wraps another allocator and sneaks in headers before
/// allocated chunks of memory, which contain the size of the allocation.
///
/// This lets us implement a `realloc` and `free` that find the old size of the
/// allocation implicitly.
const std = @import("std");

host: std.mem.Allocator,

const vtable = std.mem.Allocator.VTable{
    .alloc = &alloc_impl,
    .realloc = &realloc_impl,
    .free = &free_impl,
};

pub fn allocator(self: @This()) std.mem.Allocator {
    return std.mem.Allocator{
        .ptr = @ptrCast(self),
        .vtable = &vtable,
    };
}

pub fn create(host: std.mem.Allocator) @This() {
    return @This(){
        .host = host,
    };
}

const Header = struct {
    size: usize,
};

const header_size = 8;

fn alloc_impl(
    ctx: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    const total_size = header_size + len;
    const slice = self.host.rawAlloc(
        total_size,
        alignment,
        ret_addr,
    ) orelse return null;

    const header: *Header = @ptrCast(@alignCast(slice));
    header.size = len;

    return slice + header_size;
}

fn realloc_impl(
    ctx: *anyopaque,
    old_ptr: [*]u8,
    new_size: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    const self: *@This() = @ptrCast(@alignCast(ctx));

    // Get old size from header
    const old_header_ptr = old_ptr - header_size;
    const old_header: *Header = @ptrCast(@alignCast(old_header_ptr));
    const old_size: usize = old_header.size;

    // Allocate new memory
    const new_ptr = alloc_impl(
        self,
        new_size,
        alignment,
        ret_addr,
    ) orelse return null;

    // Copy old data
    const copy_size = @min(old_size, new_size);
    @memcpy(new_ptr[0..copy_size], old_ptr[0..copy_size]);

    // Free old allocation
    const old_slice = old_header_ptr[0 .. header_size + old_size];
    self.host.rawFree(old_slice, alignment, ret_addr);

    return new_ptr;
}

pub fn alloc(self: *@This(), size: usize) ?[*]u8 {
    return alloc_impl(
        self,
        size,
        std.mem.Alignment.fromByteUnits(8),
        @returnAddress(),
    );
}

pub fn realloc(self: *@This(), old_ptr: [*]u8, new_size: usize) ?[*]u8 {
    return realloc_impl(
        self,
        old_ptr,
        new_size,
        std.mem.Alignment.fromByteUnits(8),
        @returnAddress(),
    );
}

pub fn free(self: *@This(), ptr: [*]u8) void {
    return free_impl(
        self,
        ptr,
        std.mem.Alignment.fromByteUnits(8),
        @returnAddress(),
    );
}

pub fn free_impl(
    ctx: *anyopaque,
    ptr: [*]u8,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    const self: *@This() = @ptrCast(@alignCast(ctx));

    const header_ptr = ptr - header_size;
    const header: *Header = @ptrCast(@alignCast(header_ptr));
    const size: usize = header.size;

    const slice = header_ptr[0 .. header_size + size];
    self.host.rawFree(slice, alignment, ret_addr);
}
