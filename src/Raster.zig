const std = @import("std");

const ansi = @import("ansi");

const GlyphTable = @import("GlyphTable.zig");
const GlyphId = GlyphTable.GlyphId;

const paint = @import("paint.zig");
const Rgba8 = paint.Rgba8;
const PaintBorderStyle = paint.PaintBorderStyle;
const Painter = @import("Painter.zig").Painter;

const Cell = struct {
    glyph: GlyphId,
    fg: Rgba8,
    bg: Rgba8,
};

const Raster = @This();

pub const TERMINAL_DEFAULT_COLOR: Rgba8 = 0x00000000;

width: usize,
height: usize,
cells: std.MultiArrayList(Cell),

pub fn init(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
) !Raster {
    const n = width * height;
    var cells = std.MultiArrayList(Cell){};
    try cells.ensureTotalCapacity(allocator, n);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        cells.appendAssumeCapacity(.{
            .glyph = @as(GlyphId, 32), // space
            .fg = TERMINAL_DEFAULT_COLOR,
            .bg = TERMINAL_DEFAULT_COLOR,
        });
    }

    return .{
        .width = width,
        .height = height,
        .cells = cells,
    };
}

pub fn deinit(self: *Raster, allocator: std.mem.Allocator) void {
    self.cells.deinit(allocator);
    self.* = undefined;
}

pub fn drawBorderAscii(
    r: *Raster,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
) void {
    if (w == 0 or h == 0) return;
    const x2 = if (x + w == 0) 0 else x + w - 1;
    const y2 = if (y + h == 0) 0 else y + h - 1;
    r.set(x, y, '+');
    r.set(x2, y, '+');
    r.set(x, y2, '+');
    r.set(x2, y2, '+');
    var xi: usize = x + 1;
    while (xi < x2) : (xi += 1) {
        r.set(xi, y, '-');
        r.set(xi, y2, '-');
    }
    var yi: usize = y + 1;
    while (yi < y2) : (yi += 1) {
        r.set(x, yi, '|');
        r.set(x2, yi, '|');
    }
}

pub fn getCell(self: *const Raster, x: usize, y: usize) Cell {
    const idx = y * self.width + x;
    return self.cells.get(idx);
}

/// Set an ASCII glyph at a cell
pub fn set(self: *Raster, x: usize, y: usize, ch: u8) void {
    if (x >= self.width or y >= self.height) return;
    const idx = y * self.width + x;
    self.cells.items(.glyph)[idx] = @as(GlyphId, ch);
}

/// Set a glyph id at a cell
pub fn setGlyph(self: *Raster, x: usize, y: usize, gid: GlyphId) void {
    if (x >= self.width or y >= self.height) return;
    const idx = y * self.width + x;
    self.cells.items(.glyph)[idx] = gid;
}

pub fn setFg(self: *Raster, x: usize, y: usize, color: Rgba8) void {
    if (x >= self.width or y >= self.height) return;
    const idx = y * self.width + x;
    self.cells.items(.fg)[idx] = color;
}

pub fn setBg(self: *Raster, x: usize, y: usize, color: Rgba8) void {
    if (x >= self.width or y >= self.height) return;
    const idx = y * self.width + x;
    self.cells.items(.bg)[idx] = color;
}

pub fn clear(self: *Raster) void {
    const glyphs = self.cells.items(.glyph);
    const fgs = self.cells.items(.fg);
    const bgs = self.cells.items(.bg);

    @memset(glyphs, @as(GlyphId, 32));
    @memset(fgs, TERMINAL_DEFAULT_COLOR);
    @memset(bgs, TERMINAL_DEFAULT_COLOR);
}

/// Fill entire raster with a single glyph id
pub fn fillAllGlyph(self: *Raster, gid: GlyphId) void {
    var y: usize = 0;
    while (y < self.height) : (y += 1) {
        var x: usize = 0;
        while (x < self.width) : (x += 1) self.setGlyph(x, y, gid);
    }
}

/// Fill a rectangle with a single glyph id
pub fn fillGlyphRect(
    self: *Raster,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    gid: GlyphId,
    color: Rgba8,
) void {
    if (w == 0 or h == 0) return;

    const x0 = if (x >= self.width) self.width else x;
    const y0 = if (y >= self.height) self.height else y;
    const x1_unclamped = x + w;
    const y1_unclamped = y + h;
    const x1 = if (x1_unclamped > self.width) self.width else x1_unclamped;
    const y1 = if (y1_unclamped > self.height) self.height else y1_unclamped;

    if (x0 >= x1 or y0 >= y1) return;

    const glyphs = self.cells.items(.glyph);
    const fgs = self.cells.items(.fg);

    var yy: usize = y0;
    while (yy < y1) : (yy += 1) {
        const row_start = yy * self.width + x0;
        const row_end = yy * self.width + x1;
        @memset(glyphs[row_start..row_end], gid);
        @memset(fgs[row_start..row_end], color);
    }
}

pub fn drawBorderUnicodeStyled(
    r: *Raster,
    allocator: std.mem.Allocator,
    glyphs: *GlyphTable,
    style: PaintBorderStyle,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    color: Rgba8,
) !void {
    if (w == 0 or h == 0) return;
    const tpl = PaintBorderStyle.templateFor(style);
    const tl = try glyphs.intern(allocator, tpl.grid[0][0]);
    const hz_top = try glyphs.intern(allocator, tpl.grid[0][1]);
    const tr = try glyphs.intern(allocator, tpl.grid[0][2]);
    const vt_left = try glyphs.intern(allocator, tpl.grid[1][0]);
    const vt_right = try glyphs.intern(allocator, tpl.grid[1][2]);
    const bl = try glyphs.intern(allocator, tpl.grid[2][0]);
    const hz_bot = try glyphs.intern(allocator, tpl.grid[2][1]);
    const br = try glyphs.intern(allocator, tpl.grid[2][2]);

    const x2 = if (x + w == 0) 0 else x + w - 1;
    const y2 = if (y + h == 0) 0 else y + h - 1;

    r.setGlyph(x, y, tl);
    r.setFg(x, y, color);
    r.setGlyph(x2, y, tr);
    r.setFg(x2, y, color);
    r.setGlyph(x, y2, bl);
    r.setFg(x, y2, color);
    r.setGlyph(x2, y2, br);
    r.setFg(x2, y2, color);

    var xi: usize = x + 1;
    const dashed = style == .line_dashed;
    var dash: bool = false;
    while (xi < x2) : (xi += 1) {
        if (!dashed or dash) {
            r.setGlyph(xi, y, hz_top);
            r.setFg(xi, y, color);
        }
        if (!dashed or dash) {
            r.setGlyph(xi, y2, hz_bot);
            r.setFg(xi, y2, color);
        }
        dash = !dash;
    }
    var yi: usize = y + 1;
    dash = false;
    while (yi < y2) : (yi += 1) {
        if (!dashed or dash) {
            r.setGlyph(x, yi, vt_left);
            r.setFg(x, yi, color);
        }
        if (!dashed or dash) {
            r.setGlyph(x2, yi, vt_right);
            r.setFg(x2, yi, color);
        }
        dash = !dash;
    }
}

pub fn rasterizeDisplayList(
    r: *Raster,
    alloc: std.mem.Allocator,
    glyphs: *GlyphTable,
    painter: *const Painter,
) !void {
    for (painter.ops.items) |op| switch (op) {
        .FillRect => |fr| {
            // Fill background color and glyphs using slice ops per row
            if (fr.w > 0 and fr.h > 0) {
                const x0 = if (fr.x >= r.width) r.width else fr.x;
                const y0 = if (fr.y >= r.height) r.height else fr.y;
                const x1_unclamped = fr.x + fr.w;
                const y1_unclamped = fr.y + fr.h;
                const x1 = if (x1_unclamped > r.width) r.width else x1_unclamped;
                const y1 = if (y1_unclamped > r.height) r.height else y1_unclamped;
                if (x0 < x1 and y0 < y1) {
                    const glyph_items = r.cells.items(.glyph);
                    const bgs = r.cells.items(.bg);
                    var y: usize = y0;
                    while (y < y1) : (y += 1) {
                        const row_start = y * r.width + x0;
                        const row_end = y * r.width + x1;
                        @memset(bgs[row_start..row_end], fr.color);
                        @memset(glyph_items[row_start..row_end], @as(GlyphId, 32));
                    }
                }
            }
        },
        .FillGlyphRect => |fg| {
            r.fillGlyphRect(fg.x, fg.y, fg.w, fg.h, fg.glyph, fg.color);
        },
        .StrokeRect => |sr| {
            if (sr.bg_color) |bgc| {
                const x = sr.x;
                const y = sr.y;
                if (sr.w > 0 and sr.h > 0) {
                    const x2: usize = if (x + sr.w == 0) 0 else x + sr.w - 1;
                    const y2: usize = if (y + sr.h == 0) 0 else y + sr.h - 1;
                    r.setBg(x, y, bgc);
                    r.setBg(x2, y, bgc);
                    r.setBg(x, y2, bgc);
                    r.setBg(x2, y2, bgc);
                    var xi2: usize = x + 1;
                    while (xi2 < x2) : (xi2 += 1) {
                        r.setBg(xi2, y, bgc);
                        r.setBg(xi2, y2, bgc);
                    }
                    var yi2: usize = y + 1;
                    while (yi2 < y2) : (yi2 += 1) {
                        r.setBg(x, yi2, bgc);
                        r.setBg(x2, yi2, bgc);
                    }
                }
            }

            try drawBorderUnicodeStyled(
                r,
                alloc,
                glyphs,
                sr.style,
                sr.x,
                sr.y,
                sr.w,
                sr.h,
                sr.color,
            );
        },

        .GlyphRun => |gr| {
            if (gr.glyphs.len == 0) break;
            if (gr.y >= r.height) break;

            const row_start = gr.y * r.width;
            const x0 = if (gr.x >= r.width) r.width else gr.x;
            if (x0 >= r.width) break;

            const max_len = r.width - x0;
            const copy_len = @min(max_len, gr.glyphs.len);

            const glyph_items = r.cells.items(.glyph);
            const fgs = r.cells.items(.fg);

            @memcpy(
                glyph_items[row_start + x0 .. row_start + x0 + copy_len],
                gr.glyphs[0..copy_len],
            );

            @memset(
                fgs[row_start + x0 .. row_start + x0 + copy_len],
                gr.color,
            );
        },
    };
}

pub fn writeAsPlainText(
    self: *const Raster,
    writer: anytype,
    glyphs: *const GlyphTable,
) !void {
    const glyph_data = self.cells.items(.glyph);
    var y: usize = 0;
    while (y < self.height) : (y += 1) {
        var x: usize = 0;
        while (x < self.width) : (x += 1) {
            const gid = glyph_data[y * self.width + x];
            if (gid <= 255) {
                try writer.writeByte(@as(u8, @intCast(gid)));
            } else if (glyphs.getSlice(gid)) |bytes| {
                try writer.writeAll(bytes);
            } else {
                try writer.writeByte('?');
            }
        }
        try writer.writeByte('\n');
    }
}

pub fn plainTextDump(
    self: *const Raster,
    allocator: std.mem.Allocator,
    glyphs: *const GlyphTable,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try self.writeAsPlainText(buf.writer(), glyphs);
    return buf.toOwnedSlice();
}
