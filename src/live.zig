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
const event_dispatch = @import("event_dispatch.zig");
const clock = @import("clock.zig");
const ticket = @import("ticket.zig");

// External dependencies
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

// Type aliases for convenience
const Raster = tty.Raster;
const Rgba8 = tty.Rgba8;
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;

pub fn run(allocator: std.mem.Allocator, xml_path: ?[]const u8, wren_path: ?[]const u8) !void {
    // Initialize application-level trace that spans the entire live session
    const app_trace = Trace.init(false); // Disabled for performance
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

    var clock_registry = clock.ClockRegistry.init(allocator);
    defer clock_registry.deinit();

    var runner = try WrenRunner.init(allocator, &document);
    defer runner.deinit();

    var root_id: DomNodeId = undefined;

    // Initial render
    var termsize = updateTerminalSize();

    // Expose viewport to Wren scripts
    runner.script_context.viewport_width = termsize[0];
    runner.script_context.viewport_height = termsize[1];

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
    } else if (wren_path) |path| {
        // Load and run Wren script
        const wren_content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(wren_content);

        // Create a basic root element
        root_id = try document.addElement("flex");
        try document.setDebugId(root_id, "root");

        // Run the Wren script which will populate the DOM
        const script_id = ticket.from(wren_content) catch @panic("Failed to generate script ID");
        try runner.runScript(&script_id, wren_content);
    } else {
        // Default demo UI when no XML or Wren provided
        root_id = try document.addElement(
            "flex flex-col bg-slate-900 items-center justify-center",
        );
        try document.setDebugId(root_id, "root");

        const text_id = try document.addText("No XML or Wren file provided. Use --xml <file> or --wren <file> to load content.");
        document.appendChild(root_id, text_id);
    }

    var ctx = RenderCtx{
        .allocator = allocator,
        .unicode = &unicode,
        .width = 80,
        .height = 24,
        .dom = &document,
        .root_id = root_id,
        .raster_front = null,
        .raster_back = null,
        .log = @import("main.zig").g_log_file,
        .clock_registry = &clock_registry,
        .glyphs = try tty.GlyphTable.init(allocator),
    };
    defer {
        if (ctx.raster_front) |*r| r.deinit(allocator);
        if (ctx.raster_back) |*r| r.deinit(allocator);
        ctx.glyphs.deinit();
    }

    try renderDom(&ctx, session_trace);

    // Start clock threads for any clock nodes in the DOM
    try startClockNodes(&ctx, &document);

    // Main event loop - process input and dispatch events
    var in_buf: [64]u8 = undefined;
    var key_buf: [8]u8 = undefined; // Buffer for multi-byte sequences

    while (true) {
        // Check for terminal resize every loop and re-render immediately on change
        const prev_w = ctx.width;
        const prev_h = ctx.height;
        termsize = updateTerminalSize();
        ctx.width = termsize[0];
        ctx.height = termsize[1];

        if (ctx.width != prev_w or ctx.height != prev_h) {
            runner.script_context.viewport_width = ctx.width;
            runner.script_context.viewport_height = ctx.height;
            try renderDom(&ctx, session_trace);
            continue;
        }

        // Check for clock events with a 10ms timeout
        if (ctx.clock_registry.waitForEvents(10)) {
            // Process clock events
            var temp_arena = std.heap.ArenaAllocator.init(allocator);
            defer temp_arena.deinit();

            const events = try ctx.clock_registry.processEvents(temp_arena.allocator());
            for (events) |event| {
                // Update the DOM node's tick count
                ctx.dom.updateClockTick(event.node_id, event.tick_count);

                // Dispatch tick event to the clock node
                event_dispatch.dispatchTick(
                    runner.vm.ptr,
                    ctx.dom,
                    event.node_id,
                    event.tick_count,
                ) catch |err| {
                    std.log.warn("Failed to dispatch tick event: {}", .{err});
                };
            }

            // Re-render after clock events
            // TODO: For better performance, we should only update the specific clock nodes
            // that ticked, rather than re-rendering the entire DOM
            if (events.len > 0) {
                // For now, skip renders if we're getting too many events (animation case)
                // Only render every 3rd frame for 60fps clocks, etc
                const should_render = if (events.len == 1) true else blk: {
                    // Multiple clocks ticking - likely animation
                    // Render less frequently
                    for (events) |event| {
                        if (event.tick_count % 3 == 0) break :blk true;
                    }
                    break :blk false;
                };

                if (should_render) {
                    // Keep Wren viewport in sync
                    runner.script_context.viewport_width = ctx.width;
                    runner.script_context.viewport_height = ctx.height;
                    try renderDom(&ctx, session_trace);
                }
            }
        }

        // Poll for input (non-blocking)
        var pollfd = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        };
        const poll_result = try posix.poll(&pollfd, 0); // 0 timeout = non-blocking

        if (poll_result == 0) continue; // No input available

        const nread = posix.read(posix.STDIN_FILENO, &in_buf) catch |e| switch (e) {
            error.InputOutput => continue,
            else => return e,
        };
        if (nread == 0) continue;

        for (in_buf[0..nread]) |b| {
            // First check for exit keys
            switch (b) {
                // Escape, Ctrl-C to exit (but not 'q' - let that go through as a keypress)
                0x1b, 0x03 => return,
                else => {},
            }

            // Convert byte to string and dispatch as keypress event
            const key_str = switch (b) {
                // Printable ASCII characters
                0x20...0x7E => blk: {
                    key_buf[0] = b;
                    break :blk key_buf[0..1];
                },
                // Enter key
                0x0D, 0x0A => "Enter",
                // Tab
                0x09 => "Tab",
                // Backspace
                0x08, 0x7F => "Backspace",
                // Other control characters
                0x01 => "Ctrl+A",
                0x02 => "Ctrl+B",
                0x04 => "Ctrl+D",
                0x05 => "Ctrl+E",
                0x06 => "Ctrl+F",
                0x0B => "Ctrl+K",
                0x0C => "Ctrl+L",
                0x0E => "Ctrl+N",
                0x10 => "Ctrl+P",
                0x14 => "Ctrl+T",
                0x15 => "Ctrl+U",
                0x17 => "Ctrl+W",
                0x18 => "Ctrl+X",
                0x19 => "Ctrl+Y",
                0x1A => "Ctrl+Z",
                // Skip other non-printable characters
                else => continue,
            };

            // Dispatch keypress event to any registered handlers
            event_dispatch.dispatchKeypress(
                runner.vm.ptr,
                ctx.dom,
                key_str,
            ) catch |err| {
                std.log.warn("Failed to dispatch keypress event: {}", .{err});
            };

            // Re-render the DOM after event handling (in case handlers modified it)
            runner.script_context.viewport_width = ctx.width;
            runner.script_context.viewport_height = ctx.height;
            try renderDom(&ctx, session_trace);

            // Check if 'q' was pressed to exit (after dispatching the event)
            if (b == 'q' or b == 'Q') {
                return;
            }
        }
    }
}

const RenderCtx = struct {
    allocator: std.mem.Allocator,
    unicode: *paint.UnicodeData,
    width: usize = 80,
    height: usize = 24,
    dom: *dom.Dom,
    root_id: DomNodeId,
    resized: bool = false,
    raster_front: ?Raster = null,
    raster_back: ?Raster = null,
    log: ?std.fs.File = null,
    clock_registry: *clock.ClockRegistry,
    glyphs: tty.GlyphTable,
};

fn startClockNodes(ctx: *RenderCtx, document: *Dom) !void {
    // Walk the DOM looking for clock nodes and start their threads
    const headers = document.headers.slice();
    const kinds = headers.items(.kind);
    const style_ids = headers.items(.style_id);

    for (kinds, 0..) |kind, i| {
        if (kind == .clock) {
            const node_id = @as(DomNodeId, @intCast(i));
            const style_id = style_ids[i];
            const style_row = document.styles.cols.items[@intCast(style_id)];

            if (style_row.clock_interval_ms > 0) {
                // Create and start a clock for this node
                const clk = try ctx.clock_registry.createClock(node_id, style_row.clock_interval_ms);
                clk.setStyle(switch (style_row.clock_visual) {
                    .hidden => .hidden,
                    .progress_bar => .progress_bar,
                    .spinner => .spinner,
                    .pulse => .pulse,
                    .countdown => .countdown,
                    .text => .text,
                });
                try clk.start();
            }
        }
    }
}

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

    var tree = try layout.allocateBoxTreeFromDOM(al, ctx.dom, ctx.root_id);
    defer tree.deinit();

    var layout_engine = layout.init(al, ctx.unicode, render_trace);
    try layout_engine.computeFlexLayout(
        &tree,
        ctx.dom,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = ctx.width, .h = ctx.height },
    );

    var paint_ctx = paint.PaintContext.init(al, ctx.unicode, render_trace);
    defer paint_ctx.deinit();

    try paint.computePaintCommands(&paint_ctx, ctx.dom, &tree, &ctx.glyphs);

    // Double-buffered raster: render into back, diff against front, then swap
    const rb = try ensureDoubleRaster(ctx);
    try tty.rasterizeDisplayList(rb.back, al, &ctx.glyphs, &paint_ctx);

    // Use diffing for better performance
    try writeRasterDiff(rb.front, rb.back, &ctx.glyphs);

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

fn updateTerminalSize() [2]usize {
    var ws: posix.winsize = .{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };

    const result = posix.system.ioctl(std.io.getStdOut().handle, posix.T.IOCGWINSZ, &ws);

    if (result >= 0) {
        if (ws.col > 0 and ws.row > 0) {
            return .{ ws.col, ws.row };
        }
    }
    if (ws.col == 80 and ws.row == 24) {
        @panic("seems unlikely");
    }
    return .{ ws.col, ws.row };
}

// const LineEditor = @import("editor.zig");

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

// test "editor basic insert/move/delete" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const al = gpa.allocator();
//     var ed = try LineEditor.init(al);
//     defer ed.deinit(al);
//
//     try ed.insertByte('h');
//     try ed.insertByte('i');
//     try std.testing.expectEqualStrings("hi", ed.buffer.items);
//     ed.moveLeft();
//     try ed.insertByte('e');
//     try std.testing.expectEqualStrings("hei", ed.buffer.items);
//     ed.moveLeft();
//     ed.deleteForward();
//     try std.testing.expectEqualStrings("hi", ed.buffer.items);
//     ed.moveHome();
//     ed.deleteForward();
//     try std.testing.expectEqualStrings("i", ed.buffer.items);
// }
