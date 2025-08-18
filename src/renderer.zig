const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const tty = @import("tty.zig");
const ansi = @import("ansi");
const Trace = @import("Trace.zig").Trace;

pub const Options = struct {
    width: usize,
    height: usize,
};

pub const Deps = struct {
    allocator: std.mem.Allocator,
    unicode: *paint.UnicodeData,
    glyphs: *tty.GlyphTable,
};

pub const State = struct {
    front: tty.Raster,
    back: tty.Raster,
    needs_clear: bool = true,
};

pub const Renderer = struct {
    deps: Deps,
    opts: Options,
    state: State,

    pub fn init(deps: Deps, opts: Options) !Renderer {
        const front = try tty.Raster.init(deps.allocator, opts.width, opts.height);
        const back = try tty.Raster.init(deps.allocator, opts.width, opts.height);

        return Renderer{
            .deps = deps,
            .opts = opts,
            .state = .{
                .front = front,
                .back = back,
            },
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.state.front.deinit(self.deps.allocator);
        self.state.back.deinit(self.deps.allocator);
    }

    pub fn setViewport(self: *Renderer, width: usize, height: usize) !void {
        if (width == self.state.front.width and height == self.state.front.height) return;

        // Reallocate rasters with new dimensions
        self.state.front.deinit(self.deps.allocator);
        self.state.back.deinit(self.deps.allocator);

        self.state.front = try tty.Raster.init(self.deps.allocator, width, height);
        self.state.back = try tty.Raster.init(self.deps.allocator, width, height);

        self.opts.width = width;
        self.opts.height = height;
    }

    pub fn render(self: *Renderer, document: *dom.Dom, root: dom.DomNodeId, tracer: *Trace) !void {
        // Clear the back buffer before rendering
        self.state.back.clear();

        // Allocate box tree from DOM
        var tree = try layout.allocateBoxTreeFromDOM(self.deps.allocator, document, root);
        defer tree.deinit();

        // Compute layout
        var layout_engine = layout.init(self.deps.allocator, self.deps.unicode, tracer);
        try layout_engine.computeFlexLayout(&tree, document, tree.getNodeMut(0), .{
            .x = 0,
            .y = 0,
            .w = @intCast(self.opts.width),
            .h = @intCast(self.opts.height),
        });

        // Generate paint commands
        var paint_ctx = paint.PaintContext.init(self.deps.allocator, self.deps.unicode, tracer);
        defer paint_ctx.deinit();
        try paint.computePaintCommands(&paint_ctx, document, &tree, self.deps.glyphs);

        // Rasterize to back buffer
        try tty.rasterizeDisplayList(&self.state.back, self.deps.allocator, self.deps.glyphs, &paint_ctx);
    }

    pub fn present(self: *Renderer, writer: anytype) !void {
        // Write diff from front to back buffer
        var buffer = std.ArrayList(u8).init(self.deps.allocator);
        defer buffer.deinit();

        var ansi_writer = ansi.arrayListWriter(&buffer);
        try ansi_writer.resetStyle();

        if (self.state.needs_clear) {
            try ansi_writer.initializeTerminal();
            self.state.needs_clear = false;
        }

        var diff_iter = tty.RasterDiff.iterateChanges(&self.state.front, &self.state.back);
        while (diff_iter.next()) |change_run| {
            // Move cursor to 1-based row/col
            try ansi_writer.moveCursor(change_run.y + 1, change_run.x + 1);

            // Handle color changes and resets
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

            // Write the entire run of glyphs
            try ansi_writer.writeGlyphs(change_run.glyphs, self.deps.glyphs);
        }

        try ansi_writer.resetStyle();
        try writer.writeAll(buffer.items);

        // Swap buffers
        std.mem.swap(tty.Raster, &self.state.front, &self.state.back);
    }

    pub fn renderAndPresent(self: *Renderer, document: *dom.Dom, root: dom.DomNodeId, tracer: *Trace, writer: anytype) !void {
        if (document.dirty) {
            try self.render(document, root, tracer);
            try self.present(writer);
            document.dirty = false;
        }
    }

    /// Write the full raster to output (for one-shot mode)
    pub fn writeFullRaster(self: *const Renderer, writer: anytype) !void {
        _ = writer; // For now we write to stdout directly
        var ansi_writer = ansi.stdout();
        try self.state.back.writeAnsiToWriter(&ansi_writer, self.deps.glyphs);
    }

    pub fn getBackBuffer(self: *const Renderer) *const tty.Raster {
        return &self.state.back;
    }
};
