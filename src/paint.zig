const std = @import("std");
const GlyphId = @import("GlyphTable.zig").GlyphId;

/// RGBA color packed into a u32: 0xAABBGGRR (little-endian layout)
pub const Rgba8 = u32;

/// Create an Rgba8 color from individual components
pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Rgba8 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

/// Extract red component from Rgba8
pub fn rgba8Red(color: Rgba8) u8 {
    return @truncate(color);
}

/// Extract green component from Rgba8
pub fn rgba8Green(color: Rgba8) u8 {
    return @truncate(color >> 8);
}

/// Extract blue component from Rgba8
pub fn rgba8Blue(color: Rgba8) u8 {
    return @truncate(color >> 16);
}

/// Extract alpha component from Rgba8
pub fn rgba8Alpha(color: Rgba8) u8 {
    return @truncate(color >> 24);
}

fn mul255(x: u32, y: u32) u8 {
    // (x*y)/255 with rounding, inputs 0..255
    const prod: u32 = x * y + 127;
    return @intCast((prod + (prod >> 8)) >> 8);
}

pub fn blendOver(dst: *Rgba8, src: Rgba8) void {
    // Porter-Duff SrcOver for straight (non-premultiplied) 8-bit RGBA
    const as: u8 = rgba8Alpha(src);
    const ad: u8 = rgba8Alpha(dst.*);
    const one_minus_as: u8 = 255 - as;
    const out_a: u8 = as + mul255(ad, one_minus_as);
    if (out_a == 0) {
        dst.* = rgba8(0, 0, 0, 0);
        return;
    }
    // Premultiplied channel blend
    const dst_scale: u8 = mul255(ad, one_minus_as);
    const cp_r: u16 = @as(u16, mul255(rgba8Red(src), as)) + @as(u16, mul255(rgba8Red(dst.*), dst_scale));
    const cp_g: u16 = @as(u16, mul255(rgba8Green(src), as)) + @as(u16, mul255(rgba8Green(dst.*), dst_scale));
    const cp_b: u16 = @as(u16, mul255(rgba8Blue(src), as)) + @as(u16, mul255(rgba8Blue(dst.*), dst_scale));
    // Un-premultiply
    const oa: u16 = out_a;
    const out_r: u8 = @intCast((cp_r * 255 + oa / 2) / oa);
    const out_g: u8 = @intCast((cp_g * 255 + oa / 2) / oa);
    const out_b: u8 = @intCast((cp_b * 255 + oa / 2) / oa);
    dst.* = rgba8(out_r, out_g, out_b, out_a);
}

pub const PaintBorderStyle = enum {
    line_light,
    line_double,
    line_heavy,
    line_dashed,

    pub fn templateFor(style: PaintBorderStyle) BorderBox {
        return switch (style) {
            .line_light => .{ .grid = .{
                .{ "┌", "─", "┐" },
                .{ "│", " ", "│" },
                .{ "└", "─", "┘" },
            } },
            .line_heavy => .{ .grid = .{
                .{ "┏", "━", "┓" },
                .{ "┃", " ", "┃" },
                .{ "┗", "━", "┛" },
            } },
            .line_double => .{ .grid = .{
                .{ "╔", "═", "╗" },
                .{ "║", " ", "║" },
                .{ "╚", "═", "╝" },
            } },
            .line_dashed => .{ .grid = .{
                .{ "┌", "╌", "┐" },
                .{ "╎", " ", "╎" },
                .{ "└", "╌", "┘" },
            } },
        };
    }
};

const BorderBox = struct { grid: [3][3][]const u8 };

pub const PaintOpTag = enum { FillRect, StrokeRect, GlyphRun, FillGlyphRect };
pub const PaintOp = union(PaintOpTag) {
    FillRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8 },
    StrokeRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8, style: PaintBorderStyle, bg_color: ?Rgba8 = null },
    GlyphRun: struct { x: usize, y: usize, glyphs: []const GlyphId, color: Rgba8 },
    FillGlyphRect: struct { x: usize, y: usize, w: usize, h: usize, glyph: GlyphId, color: Rgba8 },
};

// --- Tests ---

test "source-over alpha blending mixes foreground and background colors correctly" {
    var dst = rgba8(0, 0, 255, 255);
    const src = rgba8(255, 0, 0, 128);
    blendOver(&dst, src);
    // Expect purple-ish, full alpha
    try std.testing.expect(rgba8Red(dst) > 120 and rgba8Red(dst) < 140);
    try std.testing.expect(rgba8Blue(dst) > 120 and rgba8Blue(dst) < 140);
    try std.testing.expectEqual(@as(u8, 255), rgba8Alpha(dst));
}
