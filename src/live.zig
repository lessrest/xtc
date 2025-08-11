const std = @import("std");
const posix = std.posix;

// Module imports
const tty = @import("tty.zig");
const wren = @import("wren.zig");
const layout = @import("layout.zig");
const dom = @import("dom.zig");
const paint = @import("paint.zig");
const ansi = @import("ansi.zig");
const Trace = @import("Trace.zig");
const xmlparse = @import("xmlparse.zig");
const wren_xml = @import("wren_xml.zig");
const WrenRunner = @import("wren_runner.zig");

// External dependencies
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

// Type aliases for convenience
const Raster = tty.Raster;
const Rgba8 = tty.Rgba8;
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;

pub fn run(allocator: std.mem.Allocator, xml_path: ?[]const u8) !void {
    // Initialize application-level trace that spans the entire live session
    const app_trace = Trace.init(true);
    const session_trace = app_trace.enter();
    defer session_trace.exit();
    session_trace.info("Starting XTC live session");

    var raw = try RawMode.enable(posix.STDIN_FILENO);
    defer raw.disable() catch {};

    // Enter alternate screen buffer and hide cursor; restore on exit
    var stdout_ansi = ansi.stdout();
    try stdout_ansi.initializeTerminal();
    defer {
        var restore_ansi = ansi.stdout();
        restore_ansi.restoreTerminal() catch {};
    }

    var unicode = try paint.UnicodeData.init(allocator);
    defer unicode.deinit(allocator);

    var document = Dom.init(allocator);
    // Note: WrenRunner.deinit() will handle document.deinit()

    var runner = try WrenRunner.init(allocator, &document);
    defer runner.deinit();

    var root_id: DomNodeId = undefined;

    if (xml_path) |path| {
        // Load and parse XML file
        const xml_content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(xml_content);

        var reader = std.io.fixedBufferStream(xml_content);
        var xml_doc = try xmlparse.parse(allocator, path, reader.reader());
        defer xml_doc.deinit();

        // Build DOM and execute any embedded scripts
        try wren_xml.buildDomIntoAndRunScripts(WrenRunner.ScriptContext, allocator, &xml_doc, &runner.vm, &document);

        // Get root element (assuming it's the first element)
        const headers = document.headers.slice();
        if (headers.len > 0) {
            root_id = 0;
        } else {
            // Create a default root if XML was empty
            root_id = try document.addElement("flex bg-slate-900");
        }
    } else {
        // Default demo UI when no XML provided
        root_id = try document.addElement(
            "flex flex-col bg-slate-900 items-center justify-center",
        );
        try document.setDebugId(root_id, "root");

        const text_id = try document.addText("No XML file provided. Use --xml <file> to load content.");
        document.appendChild(root_id, text_id);
    }

    var ctx = RenderCtx{
        .allocator = allocator,
        .unicode = &unicode,
        .width = 80,
        .height = 24,
        .dom = document,
        .root_id = root_id,
        .raster_front = null,
        .raster_back = null,
        .log = @import("main.zig").g_log_file,
    };
    defer {
        if (ctx.raster_front) |*r| r.deinit(allocator);
        if (ctx.raster_back) |*r| r.deinit(allocator);
    }

    // Initial render
    updateTerminalSize(&ctx);
    try renderDom(&ctx, session_trace);

    // Main event loop - wait for exit keys
    var in_buf: [64]u8 = undefined;
    while (true) {
        const nread = posix.read(posix.STDIN_FILENO, &in_buf) catch |e| switch (e) {
            error.InputOutput => continue,
            else => return e,
        };
        if (nread == 0) continue;

        for (in_buf[0..nread]) |b| {
            switch (b) {
                // Escape, Ctrl-C, or 'q' to exit
                0x1b, 0x03, 'q', 'Q' => return,
                else => {},
            }
        }
    }
}

const RenderCtx = struct {
    allocator: std.mem.Allocator,
    unicode: *paint.UnicodeData,
    width: usize = 80,
    height: usize = 24,
    dom: Dom,
    root_id: DomNodeId,
    resized: bool = false,
    raster_front: ?Raster = null,
    raster_back: ?Raster = null,
    log: ?std.fs.File = null,
};

fn setDomText(document: *Dom, text_id: DomNodeId, text: []const u8) !void {
    const off: u32 = @intCast(document.text_arena.items.len);
    try document.text_arena.appendSlice(text);
    const len: u32 = @intCast(text.len);
    var items = document.headers.slice();
    const idx: usize = @intCast(text_id);
    items.items(.first_child)[idx] = @as(DomNodeId, off);
    items.items(.child_count)[idx] = len;
}

fn ensureDoubleRaster(ctx: *RenderCtx) !struct { front: *Raster, back: *Raster } {
    const al = ctx.allocator;
    if (ctx.raster_front) |*r| {
        if (r.width != ctx.width or r.height != ctx.height) {
            r.deinit(al);
            ctx.raster_front = null;
        }
    }
    if (ctx.raster_back) |*r| {
        if (r.width != ctx.width or r.height != ctx.height) {
            r.deinit(al);
            ctx.raster_back = null;
        }
    }
    if (ctx.raster_front == null) {
        const r = try Raster.init(al, ctx.width, ctx.height);
        ctx.raster_front = r;
    }
    if (ctx.raster_back == null) {
        const r = try Raster.init(al, ctx.width, ctx.height);
        ctx.raster_back = r;
    }
    return .{ .front = &ctx.raster_front.?, .back = &ctx.raster_back.? };
}

const pretty = @import("pretty");

fn renderDom(ctx: *RenderCtx, parent_trace: Trace) !void {
    const al = ctx.allocator;

    // Create render trace as child of parent (session or command)
    const render_trace = parent_trace.enter();
    defer render_trace.exit();
    render_trace.info("Live rendering DOM");
    render_trace.data("live-render-params").put("width", ctx.width).put("height", ctx.height).end();

    var tree = try layout.allocateBoxTreeFromDOM(al, &ctx.dom, ctx.root_id);
    defer tree.deinit();

    var layout_engine = layout.init(al, ctx.unicode, render_trace);
    try layout_engine.computeFlexLayout(
        &tree,
        &ctx.dom,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = ctx.width, .h = ctx.height },
    );

    var paint_ctx = paint.PaintContext.init(al, ctx.unicode, render_trace);
    defer paint_ctx.deinit();
    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();

    try paint.computePaintCommands(&paint_ctx, &ctx.dom, &tree, &glyphs);

    // Double-buffered raster: render into back, diff against front, then swap
    const rb = try ensureDoubleRaster(ctx);
    try tty.rasterizeDisplayList(rb.back, al, &glyphs, &paint_ctx);

    // Use simple non-diffing raster output
    try writeFullRaster(rb.back, &glyphs);

    // Swap front/back for next frame
    const tmp = ctx.raster_front.?;
    ctx.raster_front = ctx.raster_back.?;
    ctx.raster_back = tmp;
}

fn writeRasterDiff(front: *const Raster, back: *const Raster, glyphs: *const tty.GlyphTable) !void {
    // Emit diffs from front -> back directly to stdout
    var out_ansi = ansi.stdout();
    try out_ansi.resetStyle(); // reset styles; no clear, we'll position per change

    var diff_iter = tty.RasterDiff.iterateChanges(front, back);
    while (diff_iter.next()) |change_run| {
        // Move cursor to 1-based row/col
        try out_ansi.moveCursor(change_run.y + 1, change_run.x + 1);

        // Handle color changes and resets
        if (change_run.bg_reset) {
            try out_ansi.resetBackground();
        } else if (change_run.bg_change) |bg| {
            try out_ansi.setBackground(bg);
        }

        if (change_run.fg_reset) {
            try out_ansi.resetForeground();
        } else if (change_run.fg_change) |fg| {
            try out_ansi.setForeground(fg);
        }

        // Write the entire run of glyphs
        try out_ansi.writeGlyphs(change_run.glyphs, glyphs);
    }

    try out_ansi.resetStyle();
}

fn writeFullRaster(raster: *const Raster, glyphs: *const tty.GlyphTable) !void {
    var out_ansi = ansi.stdout();
    try out_ansi.moveCursor(1, 1); // Move to top-left
    try out_ansi.resetStyle();

    // Write the raster without line endings for alternate screen buffer
    for (0..raster.height) |y| {
        var current_bg: ?tty.Rgba8 = null;
        var current_fg: ?tty.Rgba8 = null;

        // Move cursor to beginning of line
        if (y > 0) {
            try out_ansi.moveCursor(@intCast(y + 1), 1);
        }

        for (0..raster.width) |x| {
            const cell = raster.getCell(x, y);

            // Update background if needed
            if (cell.bg != current_bg) {
                if (cell.bg != tty.TERMINAL_DEFAULT_COLOR) {
                    try out_ansi.setBackground(cell.bg);
                } else {
                    try out_ansi.resetBackground();
                }
                current_bg = cell.bg;
            }

            // Update foreground if needed
            if (cell.fg != current_fg) {
                if (cell.fg != tty.TERMINAL_DEFAULT_COLOR) {
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
    }

    try out_ansi.resetStyle();
}

fn updateTerminalSize(ctx: *RenderCtx) void {
    var ws: posix.winsize = .{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };

    const result = posix.system.ioctl(std.io.getStdOut().handle, posix.T.IOCGWINSZ, &ws);
    if (result >= 0) {
        if (ws.col > 0 and ws.row > 0) {
            ctx.width = ws.col;
            ctx.height = ws.row;
        }
    }
}

const LineEditor = @import("editor.zig");

const RawMode = struct {
    fd: posix.fd_t,
    orig: posix.termios,

    extern "c" fn cfmakeraw(termios_p: *posix.termios) void;

    pub fn enable(fd: posix.fd_t) !RawMode {
        var tio = try posix.tcgetattr(fd);
        const orig = tio;
        cfmakeraw(&tio);
        try posix.tcsetattr(fd, .FLUSH, tio);
        return .{ .fd = fd, .orig = orig };
    }

    pub fn disable(self: *RawMode) !void {
        try posix.tcsetattr(self.fd, .FLUSH, self.orig);
    }
};

test "editor basic insert/move/delete" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    var ed = try LineEditor.init(al);
    defer ed.deinit(al);

    try ed.insertByte('h');
    try ed.insertByte('i');
    try std.testing.expectEqualStrings("hi", ed.buffer.items);
    ed.moveLeft();
    try ed.insertByte('e');
    try std.testing.expectEqualStrings("hei", ed.buffer.items);
    ed.moveLeft();
    ed.deleteForward();
    try std.testing.expectEqualStrings("hi", ed.buffer.items);
    ed.moveHome();
    ed.deleteForward();
    try std.testing.expectEqualStrings("i", ed.buffer.items);
}
