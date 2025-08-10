const std = @import("std");
const PaintCommandBatch = @import("paint.zig").PaintCommandBatch;
const PaintBorderStyle = @import("paint.zig").PaintBorderStyle;
pub const Rgba8 = @import("paint.zig").Rgba8;
pub const GlyphId = u32; // 0..=255 self-map to single-byte ASCII

/// Fixed-capacity-friendly glyph interning built on std's unmanaged string map.
/// Keys are UTF-8 byte slices that live in a contiguous arena; values are `GlyphId`.
/// Glyph ids 0..=255 are reserved for single-byte glyphs (ASCII/self-mapped).
pub const GlyphTable = struct {
    const Span = struct { off: u32, len: u8 };

    alloc: std.mem.Allocator,
    map: std.StringArrayHashMap(GlyphId),
    arena: std.ArrayList(u8),
    spans: std.MultiArrayList(Span) = .{}, // index => (off,len), id == index

    pub fn init(allocator: std.mem.Allocator) !GlyphTable {
        var gt = GlyphTable{
            .alloc = allocator,
            .map = std.StringArrayHashMap(GlyphId).init(allocator),
            .arena = std.ArrayList(u8).init(allocator),
            .spans = .{},
        };
        // Prepopulate ASCII 0x00..0xFF as self-mapped one-byte spans
        try gt.spans.ensureTotalCapacity(allocator, 256);
        try gt.arena.ensureTotalCapacity(256);
        try gt.map.ensureTotalCapacity(256);
        var ascii_i: usize = 0;
        while (ascii_i < 256) : (ascii_i += 1) {
            const off: u32 = @intCast(gt.arena.items.len);
            try gt.arena.append(@as(u8, @intCast(ascii_i)));
            gt.spans.appendAssumeCapacity(.{ .off = off, .len = 1 });
            const key = gt.arena.items[@as(usize, off) .. @as(usize, off) + 1];
            gt.map.putAssumeCapacity(key, @as(GlyphId, @intCast(ascii_i)));
        }
        return gt;
    }

    pub fn deinit(self: *GlyphTable) void {
        self.map.deinit();
        self.arena.deinit();
        self.spans.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *GlyphTable) void {
        self.map.clearRetainingCapacity();
        self.arena.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
    }

    /// Interns `bytes` and returns a glyph id. Single-byte values map directly to that byte value.
    pub fn intern(self: *GlyphTable, allocator: std.mem.Allocator, bytes: []const u8) !GlyphId {
        if (bytes.len == 1) return @as(GlyphId, bytes[0]);
        if (self.map.get(bytes)) |existing| return existing;
        if (bytes.len > std.math.maxInt(u8)) return error.GlyphTooLong;

        const off_u32: u32 = @intCast(self.arena.items.len);
        try self.arena.appendSlice(bytes);
        const len_u8: u8 = @intCast(bytes.len);
        try self.spans.append(allocator, .{ .off = off_u32, .len = len_u8 });
        const id: GlyphId = @intCast(self.spans.len - 1);

        // Create a stable slice into arena memory for the key.
        const base_ptr: [*]u8 = self.arena.items.ptr;
        const key: []const u8 = base_ptr[off_u32 .. off_u32 + len_u8];
        try self.map.put(key, id);
        return id;
    }

    /// Returns the (off,len) span for any id including ASCII.
    pub fn getSpan(self: *const GlyphTable, id: GlyphId) ?Span {
        const idx: usize = @as(usize, @intCast(id));
        if (idx >= self.spans.len) return null;
        return self.spans.get(idx);
    }

    pub fn getSlice(self: *const GlyphTable, id: GlyphId) ?[]const u8 {
        const span = self.getSpan(id) orelse return null;
        const off: usize = span.off;
        const len: usize = span.len;
        return self.arena.items[off .. off + len];
    }
};

pub const Raster = struct {
    width: usize,
    height: usize,
    cells: []GlyphId, // MxN grid of interned glyph identifiers
    fg: []Rgba8, // per-cell foreground color
    bg: []Rgba8, // per-cell background color
    fg_set: []bool, // whether a cell has an explicit foreground
    bg_set: []bool, // whether a cell has an explicit background

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Raster {
        const n = width * height;
        var cells = try allocator.alloc(GlyphId, n);
        var fg = try allocator.alloc(Rgba8, n);
        var bg = try allocator.alloc(Rgba8, n);
        var fg_set = try allocator.alloc(bool, n);
        var bg_set = try allocator.alloc(bool, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            cells[i] = @as(GlyphId, 32); // space
            fg[i] = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
            bg[i] = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            fg_set[i] = false;
            bg_set[i] = false;
        }
        return .{ .width = width, .height = height, .cells = cells, .fg = fg, .bg = bg, .fg_set = fg_set, .bg_set = bg_set };
    }

    pub fn deinit(self: *Raster, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.fg);
        allocator.free(self.bg);
        allocator.free(self.fg_set);
        allocator.free(self.bg_set);
        self.* = undefined;
    }

    /// Set an ASCII glyph at a cell
    pub fn set(self: *Raster, x: usize, y: usize, ch: u8) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = @as(GlyphId, ch);
    }

    /// Set a glyph id at a cell
    pub fn setGlyph(self: *Raster, x: usize, y: usize, gid: GlyphId) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = gid;
    }

    pub fn setFg(self: *Raster, x: usize, y: usize, color: Rgba8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = y * self.width + x;
        self.fg[idx] = color;
        self.fg_set[idx] = true;
    }

    pub fn setBg(self: *Raster, x: usize, y: usize, color: Rgba8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = y * self.width + x;
        self.bg[idx] = color;
        self.bg_set[idx] = true;
    }

    pub fn clear(self: *Raster) void {
        const n = self.width * self.height;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.cells[i] = @as(GlyphId, 32);
            self.fg[i] = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
            self.bg[i] = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            self.fg_set[i] = false;
            self.bg_set[i] = false;
        }
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
    pub fn fillGlyphRect(self: *Raster, x: usize, y: usize, w: usize, h: usize, gid: GlyphId, color: Rgba8) void {
        var yy: usize = y;
        const y_end = y + h;
        const x_end = x + w;
        while (yy < y_end and yy < self.height) : (yy += 1) {
            var xx: usize = x;
            while (xx < x_end and xx < self.width) : (xx += 1) {
                self.setGlyph(xx, yy, gid);
                self.setFg(xx, yy, color);
            }
        }
    }

    pub fn writeToWriter(self: *const Raster, writer: anytype, glyphs: *const GlyphTable) !void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const gid = self.cells[y * self.width + x];
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

    pub fn toStringAlloc(self: *const Raster, allocator: std.mem.Allocator, glyphs: *const GlyphTable) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try self.writeToWriter(buf.writer(), glyphs);
        return buf.toOwnedSlice();
    }
};

pub fn drawBorderAscii(r: *Raster, x: usize, y: usize, w: usize, h: usize) void {
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

const BorderBox = struct { grid: [3][3][]const u8 };

fn templateFor(style: PaintBorderStyle) BorderBox {
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

fn drawBorderUnicodeStyled(r: *Raster, allocator: std.mem.Allocator, glyphs: *GlyphTable, style: PaintBorderStyle, x: usize, y: usize, w: usize, h: usize, color: Rgba8) !void {
    if (w == 0 or h == 0) return;
    const tpl = templateFor(style);
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

pub var g_use_unicode_boxes: bool = true;
pub fn setUseUnicodeBoxes(on: bool) void {
    g_use_unicode_boxes = on;
}

pub fn rasterizeDisplayList(r: *Raster, alloc: std.mem.Allocator, glyphs: *GlyphTable, list: *const PaintCommandBatch) !void {
    for (list.ops.items) |op| switch (op) {
        .FillRect => |fr| {
            // Fill background color in cell buffer; keep ASCII glyphs as spaces
            var y: usize = fr.y;
            while (y < fr.y + fr.h and y < r.height) : (y += 1) {
                var x: usize = fr.x;
                while (x < fr.x + fr.w and x < r.width) : (x += 1) {
                    r.setBg(x, y, fr.color);
                    r.setGlyph(x, y, @as(GlyphId, 32));
                }
            }
        },
        .FillGlyphRect => |fg| {
            r.fillGlyphRect(fg.x, fg.y, fg.w, fg.h, fg.glyph, fg.color);
        },
        .StrokeRect => |sr| {
            if (!g_use_unicode_boxes) {
                drawBorderAscii(r, sr.x, sr.y, sr.w, sr.h);
                const x = sr.x;
                const y = sr.y;
                if (sr.w > 0 and sr.h > 0) {
                    const x2: usize = if (x + sr.w == 0) 0 else x + sr.w - 1;
                    const y2: usize = if (y + sr.h == 0) 0 else y + sr.h - 1;
                    if (sr.bg_color) |bgc| {
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
                    r.setFg(x, y, sr.color);
                    r.setFg(x2, y, sr.color);
                    r.setFg(x, y2, sr.color);
                    r.setFg(x2, y2, sr.color);
                    var xi: usize = x + 1;
                    while (xi < x2) : (xi += 1) {
                        r.setFg(xi, y, sr.color);
                        r.setFg(xi, y2, sr.color);
                    }
                    var yi: usize = y + 1;
                    while (yi < y2) : (yi += 1) {
                        r.setFg(x, yi, sr.color);
                        r.setFg(x2, yi, sr.color);
                    }
                }
            } else {
                if (sr.bg_color) |bgc| {
                    // Pre-fill border background cells before drawing glyphs
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
                try drawBorderUnicodeStyled(r, alloc, glyphs, sr.style, sr.x, sr.y, sr.w, sr.h, sr.color);
            }
        },
        .GlyphRun => |gr| {
            var i: usize = 0;
            while (i < gr.glyphs.len) : (i += 1) {
                r.setGlyph(gr.x + i, gr.y, gr.glyphs[i]);
                r.setFg(gr.x + i, gr.y, gr.color);
            }
        },
    };
}
