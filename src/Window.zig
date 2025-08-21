const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const ansi = @import("ansi");
const Trace = @import("ansi").FileTrace;
const Raster = @import("Raster.zig");
const GlyphTable = @import("GlyphTable.zig");
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
        trace.* = @import("ansi").nest.treeNest(allocator, std.io.getStdErr().writer());
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
        self.allocator.destroy(self.unicode);
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

        var painter = Painter.init(self.allocator, self.unicode, self.trace);
        defer painter.deinit();
        try painter.computePaintCommands(document, &tree, self.glyphs);

        try self.state.back.rasterizeDisplayList(self.allocator, self.glyphs, &painter);
    }

    pub fn present(self: *Window, writer: anytype) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        var ansi_writer = ansi.arrayListWriter(&buffer);
        try ansi_writer.resetStyle();

        if (self.state.needs_clear) {
            try ansi_writer.initializeTerminal();
            self.state.needs_clear = false;
        }

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

        try ansi_writer.resetStyle();
        try writer.writeAll(buffer.items);
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
