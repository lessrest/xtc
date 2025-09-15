/// miniflex exposes the DOM → layout → paint pipeline used by xtc as a
/// standalone library.  It re-exports the building blocks so other Zig
/// programs can construct DOM trees and render them to terminal rasters
/// without depending on xtc's runtime layers.
pub const dom = @import("dom.zig");
pub const Dom = dom.Dom;
pub const DomNodeId = dom.DomNodeId;

pub const layout = @import("layout.zig");
pub const LayoutEngine = layout.LayoutEngine;
pub const Rect = layout.Rect;
pub const BoxTree = layout.BoxTree;

pub const measure = @import("measure.zig");
pub const style = @import("style.zig");
pub const tailwind = @import("tailwind.zig");

pub const tree = @import("tree.zig");

pub const paint = @import("paint.zig");

pub const painter = @import("Painter.zig");
pub const Painter = painter.Painter;

pub const raster = @import("Raster.zig");
pub const Raster = raster;

pub const raster_diff = @import("RasterDiff.zig");
pub const RasterDiff = raster_diff;

pub const window = @import("Window.zig");
pub const Window = window.Window;

pub const glyph_table = @import("GlyphTable.zig");
pub const GlyphTable = glyph_table;

pub const unicode = @import("unicode.zig");
pub const UnicodeData = unicode;

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
