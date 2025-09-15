const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const ansi = @import("ansi");
const Trace = @import("ansi").FileTrace;
const Raster = @import("Raster.zig");
const GlyphTable = @import("GlyphTable.zig");
const GlyphId = GlyphTable.GlyphId;
const Rgba8 = @import("paint.zig").Rgba8;
const Unicode = @import("unicode.zig");
const Painter = @import("Painter.zig").Painter;
const RasterDiff = @import("RasterDiff.zig");

pub const Options = struct {
    width: usize,
    height: usize,
};

pub const State = struct {
    front: Raster,
    back: Raster,
    needs_clear: bool = true,
    needs_tty_restore: bool = false,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    unicode: *Unicode,
    glyphs: *GlyphTable,
    trace: *Trace,

    opts: Options,
    state: State,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Window {
        // Dependencies
        var unicode = try allocator.create(Unicode);
        unicode.* = try Unicode.init(allocator);
        errdefer unicode.deinit(allocator);

        const glyphs = try GlyphTable.init(allocator);
        errdefer glyphs.deinit();

        const trace = try allocator.create(Trace);
        trace.* = @import("ansi").nest.stderr(allocator);
        trace.setEnabled(false);

        // Rasters
        var front = try Raster.init(allocator, opts.width, opts.height);
        errdefer front.deinit(allocator);
        var back = try Raster.init(allocator, opts.width, opts.height);
        errdefer back.deinit(allocator);

        return .{
            .allocator = allocator,
            .unicode = unicode,
            .glyphs = glyphs,
            .trace = trace,
            .opts = opts,
            .state = .{ .front = front, .back = back, .needs_clear = true },
        };
    }

    pub fn deinit(self: *Window) void {
        self.state.front.deinit(self.allocator);
        self.state.back.deinit(self.allocator);
        self.glyphs.deinit();
        self.unicode.deinit(self.allocator);
        self.trace.deinit();
        self.allocator.destroy(self.trace);
        //        self.allocator.destroy(self.unicode);
        if (self.state.needs_tty_restore) {
            var ansi_writer = ansi.stdout();
            ansi_writer.exitAlternateScreen() catch {};
            ansi_writer.resetStyle() catch {};
            ansi_writer.showCursor() catch {};
            _ = ansi_writer.writer.interface.flush() catch {};
        }
    }

    pub fn setViewport(self: *Window, width: usize, height: usize) !void {
        if (width == self.state.front.width and height == self.state.front.height) return;
        self.state.front.deinit(self.allocator);
        self.state.back.deinit(self.allocator);
        self.state.front = try Raster.init(self.allocator, width, height);
        self.state.back = try Raster.init(self.allocator, width, height);
        self.opts.width = width;
        self.opts.height = height;
        // Force clear on next present
        self.state.needs_clear = true;
    }

    pub fn render(self: *Window, document: *dom.Dom, root: dom.DomNodeId) !void {
        self.state.back.clear();
        var tree = try layout.allocateBoxTreeFromDOM(self.allocator, document, root);
        defer tree.deinit();

        var layout_engine = layout.init(self.allocator, self.unicode, self.trace);
        try layout_engine.layoutSubtree(&tree, document, tree.getNodeMut(0), .{
            .x = 0,
            .y = 0,
            .w = @intCast(self.opts.width),
            .h = @intCast(self.opts.height),
        });

        var painter: Painter = Painter.init(self.allocator, self.unicode, self.trace);

        defer painter.deinit();
        try painter.computePaintCommands(document, &tree, self.glyphs);

        try self.state.back.rasterizeDisplayList(self.allocator, self.glyphs, &painter);
    }

    pub fn present(self: *Window, writer: anytype) !void {
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(self.allocator);

        var ansi_writer = ansi.arrayListWriter(&buffer, self.allocator);
        try ansi_writer.resetStyle();

        if (self.state.needs_clear) {
            try ansi_writer.initializeTerminal();
            self.state.needs_clear = false;
            self.state.needs_tty_restore = true;
        }

        if (self.state.needs_tty_restore) {
            // Alternate screen - use diff and cursor positioning as before
            var diff_iter = RasterDiff.iterateChanges(&self.state.front, &self.state.back);
            while (diff_iter.next()) |change_run| {
                try ansi_writer.moveCursor(change_run.y + 1, change_run.x + 1);
                if (change_run.bg_reset) {
                    try ansi_writer.resetBackground();
                } else if (change_run.bg_change) |bg| {
                    try ansi_writer.setBackground(bg);
                }
                if (change_run.fg_reset) {
                    try ansi_writer.resetForeground();
                } else if (change_run.fg_change) |fg| {
                    try ansi_writer.setForeground(fg);
                }
                try ansi_writer.writeGlyphs(change_run.glyphs, self.glyphs);
            }
        } else {
            // Primary buffer rendering: walk runs using RasterDiff but emit sequential
            // text with SGR transitions instead of cursor positioning.
            // Use a scratch copy of the front buffer so RasterDiff yields the entire frame
            // without mutating the real previous state (keeps subsequent frames correct).
            var scratch_front = try Raster.init(self.allocator, self.state.front.width, self.state.front.height);
            defer scratch_front.deinit(self.allocator);
            scratch_front.clear();

            var diff_iter = RasterDiff.iterateChanges(&scratch_front, &self.state.back);
            var next_run = diff_iter.next();

            const back_cells = self.state.back.cells.slice();
            const back_fg = back_cells.items(.fg);
            const back_bg = back_cells.items(.bg);

            var line: usize = 0;
            while (line < self.state.back.height) : (line += 1) {
                var column: usize = 0;
                var active_fg: ?Rgba8 = null;
                var active_bg: ?Rgba8 = null;

                while (next_run) |run| {
                    if (run.y > line) break;

                    const current = run;
                    next_run = diff_iter.next();
                    if (current.y < line) continue;

                    while (column < current.x) : (column += 1) {
                        try ansi_writer.writeAll(" ");
                    }

                    const cell_index = run.y * self.state.back.width + run.x;
                    const desired_bg: ?Rgba8 = if (back_bg[cell_index] == Raster.TERMINAL_DEFAULT_COLOR) null else back_bg[cell_index];
                    const desired_fg: ?Rgba8 = if (back_fg[cell_index] == Raster.TERMINAL_DEFAULT_COLOR) null else back_fg[cell_index];

                    if ((desired_bg == null and active_bg != null)) {
                        try ansi_writer.resetBackground();
                        active_bg = null;
                    } else if (desired_bg) |bg| {
                        if (active_bg == null or active_bg.? != bg) {
                            try ansi_writer.setBackground(bg);
                            active_bg = bg;
                        }
                    }

                    if ((desired_fg == null and active_fg != null)) {
                        try ansi_writer.resetForeground();
                        active_fg = null;
                    } else if (desired_fg) |fg| {
                        if (active_fg == null or active_fg.? != fg) {
                            try ansi_writer.setForeground(fg);
                            active_fg = fg;
                        }
                    }

                    column = current.x + try writeGlyphRun(&ansi_writer, self.unicode, current.glyphs, self.glyphs);
                }

                if (active_fg != null) try ansi_writer.resetForeground();
                if (active_bg != null) try ansi_writer.resetBackground();
                try ansi_writer.writeAll("\n");
            }
        }

        try ansi_writer.resetStyle();
        try writer.writeAll(buffer.items);
        if (@TypeOf(writer) == *std.Io.Writer) {
            try writer.flush();
        }
        std.mem.swap(Raster, &self.state.front, &self.state.back);
    }

    pub fn renderAndPresent(self: *Window, document: *dom.Dom, root: dom.DomNodeId, writer: anytype) !void {
        if (document.dirty) {
            try self.render(document, root);
            try self.present(writer);
            document.dirty = false;
        }
    }

    /// Write full back buffer as plain text (no alt screen), after a render
    pub fn writeFullRaster(self: *const Window, writer: anytype) !void {
        try self.state.back.writeAsPlainText(writer, self.glyphs);
    }
    pub fn getBackBuffer(self: *const Window) *const Raster {
        return &self.state.back;
    }
};

fn writeGlyphRun(
    writer: anytype,
    unicode: *Unicode,
    glyphs: []const GlyphId,
    glyph_table: *const GlyphTable,
) !usize {
    const space = [_]u8{' '};
    var single: [1]u8 = undefined;
    var written: usize = 0;

    for (glyphs) |gid| {
        if (gid == 0) {
            try writer.writeAll(space[0..]);
            written += 1;
        } else if (gid <= 255) {
            single[0] = @intCast(gid);
            try writer.writeAll(single[0..]);
            written += 1;
        } else if (glyph_table.getSlice(gid)) |bytes| {
            try writer.writeAll(bytes);
            written += unicode.monospacedTextWidth(bytes);
        } else {
            single[0] = '?';
            try writer.writeAll(single[0..]);
            written += 1;
        }
    }

    return written;
}
