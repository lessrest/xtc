const std = @import("std");
const PaintCommandBatch = @import("paint.zig").PaintCommandBatch;
const PaintBorderStyle = @import("paint.zig").PaintBorderStyle;
pub const Rgba8 = @import("paint.zig").Rgba8;
const rgba8 = @import("paint.zig").rgba8;
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

/// Data for a single raster cell
pub const Cell = struct {
    glyph: GlyphId,
    fg: Rgba8, // 0x00000000 = terminal default color
    bg: Rgba8, // 0x00000000 = terminal default color
};

/// Sentinel value representing "use terminal default color"
pub const TERMINAL_DEFAULT_COLOR: Rgba8 = 0x00000000;

pub const Raster = struct {
    width: usize,
    height: usize,
    cells: std.MultiArrayList(Cell),

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Raster {
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

        return .{ .width = width, .height = height, .cells = cells };
    }

    pub fn deinit(self: *Raster, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
        self.* = undefined;
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
    pub fn fillGlyphRect(self: *Raster, x: usize, y: usize, w: usize, h: usize, gid: GlyphId, color: Rgba8) void {
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

    pub fn writeToWriter(self: *const Raster, writer: anytype, glyphs: *const GlyphTable) !void {
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

    pub fn writeAnsiToWriter(self: *const Raster, writer: anytype, glyphs: *const GlyphTable) !void {
        const ansi = @import("ansi.zig");
        var out_ansi = ansi.AnsiWriter(@TypeOf(writer)).init(writer);
        try out_ansi.resetStyle();

        for (0..self.height) |y| {
            var current_bg: ?Rgba8 = null;
            var current_fg: ?Rgba8 = null;

            for (0..self.width) |x| {
                const cell = self.getCell(x, y);

                // Update background if needed
                if (cell.bg != current_bg) {
                    if (cell.bg != TERMINAL_DEFAULT_COLOR) {
                        try out_ansi.setBackground(cell.bg);
                    } else {
                        try out_ansi.resetBackground();
                    }
                    current_bg = cell.bg;
                }

                // Update foreground if needed
                if (cell.fg != current_fg) {
                    if (cell.fg != TERMINAL_DEFAULT_COLOR) {
                        try out_ansi.setForeground(cell.fg);
                    } else {
                        try out_ansi.resetForeground();
                    }
                    current_fg = cell.fg;
                }

                // Write the glyph
                const glyph_slice = &[_]u32{cell.glyph};
                try out_ansi.writeGlyphs(glyph_slice, glyphs);
            }
            // Write newline after each line (for normal output to stdout)
            try out_ansi.writeAll("\n");
        }

        try out_ansi.resetStyle();
    }

    pub fn toStringAlloc(self: *const Raster, allocator: std.mem.Allocator, glyphs: *const GlyphTable) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try self.writeToWriter(buf.writer(), glyphs);
        return buf.toOwnedSlice();
    }
};

/// Utility for iterating over differences between two rasters
pub const RasterDiff = struct {
    /// A run of changed cells with consistent colors
    pub const ChangeRun = struct {
        x: usize,
        y: usize,
        glyphs: []const GlyphId, // slice into back raster cells
        fg_change: ?Rgba8, // new fg color, null if no change needed
        bg_change: ?Rgba8, // new bg color, null if no change needed
        fg_reset: bool = false, // true if fg should be reset to default
        bg_reset: bool = false, // true if bg should be reset to default
    };

    /// Smart iterator that tracks color state and detects runs
    pub const DiffIterator = struct {
        front: *const Raster,
        back: *const Raster,
        x: usize,
        y: usize,
        current_fg: ?Rgba8, // track current terminal fg state
        current_bg: ?Rgba8, // track current terminal bg state

        pub fn next(self: *DiffIterator) ?ChangeRun {
            while (self.y < self.back.height) {
                // Find next difference in current line
                if (self.findNextDifferenceInLine(self.y, self.x)) |start_x| {
                    const start_y = self.y;
                    const start_idx = start_y * self.back.width + start_x;

                    // Update our position
                    self.x = start_x;

                    // Found a change - determine colors for this run
                    const run_fg = if (self.back.cells.items(.fg)[start_idx] != TERMINAL_DEFAULT_COLOR) self.back.cells.items(.fg)[start_idx] else null;
                    const run_bg = if (self.back.cells.items(.bg)[start_idx] != TERMINAL_DEFAULT_COLOR) self.back.cells.items(.bg)[start_idx] else null;

                    // Find end of run efficiently using indexOfDiff
                    const end_x = self.findEndOfColorRun(start_y, start_x, run_fg, run_bg);

                    // Determine what color changes are needed
                    var fg_change: ?Rgba8 = null;
                    var fg_reset = false;
                    var bg_change: ?Rgba8 = null;
                    var bg_reset = false;

                    if (run_fg == null and self.current_fg != null) {
                        self.current_fg = null;
                        fg_reset = true;
                    } else if (run_fg != null and (self.current_fg == null or !std.meta.eql(self.current_fg.?, run_fg.?))) {
                        self.current_fg = run_fg;
                        fg_change = run_fg;
                    }

                    if (run_bg == null and self.current_bg != null) {
                        self.current_bg = null;
                        bg_reset = true;
                    } else if (run_bg != null and (self.current_bg == null or !std.meta.eql(self.current_bg.?, run_bg.?))) {
                        self.current_bg = run_bg;
                        bg_change = run_bg;
                    }

                    // Create slice into back raster glyph data
                    const glyph_slice = self.back.cells.items(.glyph)[start_idx .. start_idx + (end_x - start_x)];

                    // Update position for next iteration
                    self.x = end_x;

                    return ChangeRun{
                        .x = start_x,
                        .y = start_y,
                        .glyphs = glyph_slice,
                        .fg_change = fg_change,
                        .bg_change = bg_change,
                        .fg_reset = fg_reset,
                        .bg_reset = bg_reset,
                    };
                } else {
                    // No more differences in this line, move to next line
                    self.x = 0;
                    self.y += 1;
                }
            }

            return null;
        }

        fn findNextDifferenceInLine(self: *const DiffIterator, y: usize, start_x: usize) ?usize {
            if (y >= self.back.height or start_x >= self.back.width) return null;

            const line_start_idx = y * self.back.width;
            const search_start_idx = line_start_idx + start_x;
            const line_end_idx = line_start_idx + self.back.width;

            const front_glyphs = self.front.cells.items(.glyph);
            const back_glyphs = self.back.cells.items(.glyph);
            const front_fg = self.front.cells.items(.fg);
            const back_fg = self.back.cells.items(.fg);
            const front_bg = self.front.cells.items(.bg);
            const back_bg = self.back.cells.items(.bg);

            var min_diff: ?usize = null;

            // Check glyph differences within the line
            if (std.mem.indexOfDiff(GlyphId, front_glyphs[search_start_idx..line_end_idx], back_glyphs[search_start_idx..line_end_idx])) |diff| {
                min_diff = if (min_diff) |m| @min(m, diff) else diff;
            }

            // Check fg differences (now works since Rgba8 is u32!)
            if (std.mem.indexOfDiff(Rgba8, front_fg[search_start_idx..line_end_idx], back_fg[search_start_idx..line_end_idx])) |diff| {
                min_diff = if (min_diff) |m| @min(m, diff) else diff;
            }

            // Check bg differences
            if (std.mem.indexOfDiff(Rgba8, front_bg[search_start_idx..line_end_idx], back_bg[search_start_idx..line_end_idx])) |diff| {
                min_diff = if (min_diff) |m| @min(m, diff) else diff;
            }

            return if (min_diff) |d| start_x + d else null;
        }

        fn findEndOfColorRun(self: *const DiffIterator, y: usize, start_x: usize, run_fg: ?Rgba8, run_bg: ?Rgba8) usize {
            const line_start = y * self.back.width;
            const line_end = line_start + self.back.width;
            const search_start = line_start + start_x + 1;

            if (search_start >= line_end) return start_x + 1;

            var end_x = self.back.width; // default to end of line

            // Use indexOfDiff to efficiently find where fg color changes
            if (run_fg != null) {
                const back_fg = self.back.cells.items(.fg);

                // Find where fg color changes
                var i = search_start;
                while (i < line_end) : (i += 1) {
                    const fg = back_fg[i];
                    if (fg != run_fg.?) {
                        end_x = @min(end_x, i - line_start);
                        break;
                    }
                }
            }

            // Use indexOfDiff to efficiently find where bg color changes
            if (run_bg != null) {
                const back_bg = self.back.cells.items(.bg);

                // Find where bg color changes
                var i = search_start;
                while (i < line_end) : (i += 1) {
                    const bg = back_bg[i];
                    if (bg != run_bg.?) {
                        end_x = @min(end_x, i - line_start);
                        break;
                    }
                }
            }

            // For null colors (terminal default), find where color becomes non-default
            if (run_fg == null) {
                const back_fg = self.back.cells.items(.fg);
                var i = search_start;
                while (i < line_end) : (i += 1) {
                    if (back_fg[i] != TERMINAL_DEFAULT_COLOR) {
                        end_x = @min(end_x, i - line_start);
                        break;
                    }
                }
            }

            if (run_bg == null) {
                const back_bg = self.back.cells.items(.bg);
                var i = search_start;
                while (i < line_end) : (i += 1) {
                    if (back_bg[i] != TERMINAL_DEFAULT_COLOR) {
                        end_x = @min(end_x, i - line_start);
                        break;
                    }
                }
            }

            return end_x;
        }

        fn cellHasChanged(self: *const DiffIterator, idx: usize) bool {
            const g0 = self.front.cells.items(.glyph)[idx];
            const g1 = self.back.cells.items(.glyph)[idx];
            const fg0 = self.front.cells.items(.fg)[idx];
            const fg1 = self.back.cells.items(.fg)[idx];
            const bg0 = self.front.cells.items(.bg)[idx];
            const bg1 = self.back.cells.items(.bg)[idx];

            // Simple comparison: glyph, fg, and bg must all match
            return !(g0 == g1 and fg0 == fg1 and bg0 == bg1);
        }
    };

    /// Create a smart iterator over differences between front and back rasters
    pub fn iterateChanges(front: *const Raster, back: *const Raster) DiffIterator {
        return DiffIterator{
            .front = front,
            .back = back,
            .x = 0,
            .y = 0,
            .current_fg = null,
            .current_bg = null,
        };
    }
};

test "RasterDiff iterator with runs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    var front = try Raster.init(al, 5, 2);
    defer front.deinit(al);
    var back = try Raster.init(al, 5, 2);
    defer back.deinit(al);

    // Create a run of changes with same color
    back.set(1, 0, 'H');
    back.set(2, 0, 'i');
    back.set(3, 0, '!');
    const red = rgba8(255, 0, 0, 255);
    back.setFg(1, 0, red);
    back.setFg(2, 0, red);
    back.setFg(3, 0, red);

    var runs = std.ArrayList(RasterDiff.ChangeRun).init(al);
    defer runs.deinit();

    var iter = RasterDiff.iterateChanges(&front, &back);
    while (iter.next()) |run| {
        try runs.append(run);
    }

    // Should have exactly one run covering positions 1-3
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    const run = runs.items[0];
    try std.testing.expectEqual(@as(usize, 1), run.x);
    try std.testing.expectEqual(@as(usize, 0), run.y);
    try std.testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try std.testing.expectEqual(@as(GlyphId, 'H'), run.glyphs[0]);
    try std.testing.expectEqual(@as(GlyphId, 'i'), run.glyphs[1]);
    try std.testing.expectEqual(@as(GlyphId, '!'), run.glyphs[2]);
    try std.testing.expectEqual(red, run.fg_change.?);

    // Test with matching rasters - no changes should be detected
    front.set(1, 0, 'H');
    front.set(2, 0, 'i');
    front.set(3, 0, '!');
    front.setFg(1, 0, red);
    front.setFg(2, 0, red);
    front.setFg(3, 0, red);

    runs.clearRetainingCapacity();
    iter = RasterDiff.iterateChanges(&front, &back);
    while (iter.next()) |r| {
        try runs.append(r);
    }
    try std.testing.expectEqual(@as(usize, 0), runs.items.len);
}

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
            if (gr.glyphs.len == 0) break;
            if (gr.y >= r.height) break;
            const row_start = gr.y * r.width;
            const x0 = if (gr.x >= r.width) r.width else gr.x;
            if (x0 >= r.width) break;
            const max_len = r.width - x0;
            const copy_len = @min(max_len, gr.glyphs.len);

            const glyph_items = r.cells.items(.glyph);
            const fgs = r.cells.items(.fg);

            // Copy glyphs
            @memcpy(glyph_items[row_start + x0 .. row_start + x0 + copy_len], gr.glyphs[0..copy_len]);
            // Set fg color over the same span
            @memset(fgs[row_start + x0 .. row_start + x0 + copy_len], gr.color);
        },
    };
}
