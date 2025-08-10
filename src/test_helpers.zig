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

pub fn b(width: usize, height: usize) BoxSize {
    return .{ .width = width, .height = height };
}
