/// Smart iterator that tracks color state and detects runs
const DiffIterator = @This();

const std = @import("std");

const Raster = @import("Raster.zig");
const GlyphId = @import("GlyphTable.zig").GlyphId;
const Rgba8 = @import("paint.zig").Rgba8;

const noColor = Raster.TERMINAL_DEFAULT_COLOR;

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

front: *const Raster,
back: *const Raster,
x: usize,
y: usize,
current_fg: ?Rgba8, // track current terminal fg state
current_bg: ?Rgba8, // track current terminal bg state

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

pub fn next(self: *DiffIterator) ?ChangeRun {
    while (self.y < self.back.height) {
        // Find next difference in current line
        if (self.findNextDifferenceInLine(self.y, self.x)) |start_x| {
            const start_y = self.y;
            const start_idx = start_y * self.back.width + start_x;

            // Update our position
            self.x = start_x;

            // Found a change - determine colors for this run
            const run_fg = if (self.back.cells.items(.fg)[start_idx] != noColor) self.back.cells.items(.fg)[start_idx] else null;
            const run_bg = if (self.back.cells.items(.bg)[start_idx] != noColor) self.back.cells.items(.bg)[start_idx] else null;

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
            if (back_fg[i] != noColor) {
                end_x = @min(end_x, i - line_start);
                break;
            }
        }
    }

    if (run_bg == null) {
        const back_bg = self.back.cells.items(.bg);
        var i = search_start;
        while (i < line_end) : (i += 1) {
            if (back_bg[i] != noColor) {
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

test "raster diff iterator detects runs of changes with consistent colors" {
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
    const red: Rgba8 = @import("paint.zig").rgba8(0xff, 0x00, 0x00, 0xff);
    back.setFg(1, 0, red);
    back.setFg(2, 0, red);
    back.setFg(3, 0, red);

    var runs = std.ArrayList(ChangeRun).init(al);
    defer runs.deinit();

    var iter = iterateChanges(&front, &back);
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
    iter = iterateChanges(&front, &back);
    while (iter.next()) |r| {
        try runs.append(r);
    }
    try std.testing.expectEqual(@as(usize, 0), runs.items.len);
}
