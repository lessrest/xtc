const std = @import("std");
const Raster = @import("tty.zig").Raster;
const drawBorderAscii = @import("tty.zig").drawBorderAscii;
const calculateSpaces = @import("layout.zig").calculateSpaces;

pub const BoxSize = struct { width: usize, height: usize };
pub const Direction = @import("layout.zig").Direction;
pub const MainAxisAlignment = @import("layout.zig").MainAxisAlignment;
pub const CrossAxisAlignment = @import("layout.zig").CrossAxisAlignment;
pub const layoutFixedBoxesAlloc = @import("layout.zig").layoutFixedBoxesAlloc;

pub const Layout = struct {
    direction: Direction,
    main_align: MainAxisAlignment,
    cross_align: CrossAxisAlignment,
};

pub fn composeFixedBoxesAlloc(
    allocator: std.mem.Allocator,
    container_width: usize,
    container_height: usize,
    layout: Layout,
    children: []const BoxSize,
) !Raster {
    var r = try Raster.init(allocator, container_width, container_height);
    drawBorderAscii(&r, 0, 0, container_width, container_height);
    const inner_x: usize = if (container_width >= 2) 1 else 0;
    const inner_y: usize = if (container_height >= 2) 1 else 0;
    const inner_w: usize = if (container_width > 1) container_width - 2 else container_width;
    const inner_h: usize = if (container_height > 1) container_height - 2 else container_height;
    const rects = try layoutFixedBoxesAlloc(allocator, inner_x, inner_y, inner_w, inner_h, layout, children);
    defer allocator.free(rects);
    for (rects) |rc| if (rc.w > 0 and rc.h > 0) drawBorderAscii(&r, rc.x, rc.y, rc.w, rc.h);
    return r;
}

pub fn b(width: usize, height: usize) BoxSize {
    return .{ .width = width, .height = height };
}
