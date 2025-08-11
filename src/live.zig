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

// External dependencies
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

// Type aliases for convenience
const Raster = tty.Raster;
const Rgba8 = tty.Rgba8;
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;

pub fn run(allocator: std.mem.Allocator) !void {
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
    defer document.deinit();

    const root_id = try document.addElement(
        "flex flex-col bg-glyph-[.] items-center",
    );
    try document.setDebugId(root_id, "root");

    const container_id = try document.addElement(
        "flex flex-col grow-1 w-80 items-stretch border border-blue-200 bg-yellow-700",
    );
    try document.setDebugId(container_id, "container");

    const wren_output_id = try document.addElement(
        "px-2 grow-1 bg-green-400 text-slate-800 overflow-y-scroll",
    );
    try document.setDebugId(wren_output_id, "wren-output");

    const child_id = try document.addElement(
        "px-2 flex items-center grow-0 h-6 bg-slate-700 text-slate-200",
    );
    try document.setDebugId(child_id, "input-line");

    const text_id = try document.addText("foo");
    try document.setDebugId(text_id, "input-text");

    const output_text_id = try document.addText("wren\n");
    try document.setDebugId(output_text_id, "output-text");

    const prompt_id = try document.addText("» ");
    try document.setDebugId(prompt_id, "prompt");

    document.appendChild(child_id, prompt_id);
    document.appendChild(child_id, text_id);

    document.appendChild(wren_output_id, output_text_id);
    document.appendChild(container_id, wren_output_id);
    document.appendChild(container_id, child_id);
    document.appendChild(root_id, container_id);

    var ctx = RenderCtx{
        .allocator = allocator,
        .unicode = &unicode,
        .width = 80,
        .height = 24,
        .dom = document,
        .root_id = root_id,
        .text_id = text_id,
        .output_text_id = output_text_id,
        .raster_front = null,
        .raster_back = null,
        .log = @import("main.zig").g_log_file,
    };
    defer {
        if (ctx.raster_front) |*r| r.deinit(allocator);
        if (ctx.raster_back) |*r| r.deinit(allocator);
    }

    var editor = try LineEditor.init(allocator);
    defer editor.deinit(allocator);

    const ScriptContext = struct {
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        dom: *Dom,

        pub const Modules = struct {};

        pub fn write(self: *@This(), text: []const u8) void {
            self.out.appendSlice(text) catch @panic("appendSlice");
            self.out.append('\n') catch @panic("append");
        }

        pub fn onError(self: *@This(), error_type: wren.WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
            switch (error_type) {
                wren.WREN_ERROR_COMPILE => {
                    std.fmt.format(self.out.writer(), "[{s} line {d}] Compile error: {s}\n", .{ module, line, message }) catch @panic("appendSlice");
                },
                wren.WREN_ERROR_RUNTIME => {
                    std.fmt.format(self.out.writer(), "[{s} line {d}] Runtime error: {s}\n", .{ module, line, message }) catch @panic("appendSlice");
                },
                wren.WREN_ERROR_STACK_TRACE => {
                    std.fmt.format(self.out.writer(), "  [{s} line {d}] in {s}\n", .{ module, line, message }) catch @panic("appendSlice");
                },
                else => {},
            }
        }
    };

    // Output log buffer backing the Prolog output box
    var out_log = std.ArrayList(u8).init(allocator);
    defer out_log.deinit();

    var script_context = ScriptContext{
        .out = &out_log,
        .allocator = allocator,
        .dom = &document,
    };
    var wren_vm = try wren.create(ScriptContext, &script_context);
    defer wren_vm.deinit();

    while (true) {
        const maybe_line = try editor.prompt(&ctx, session_trace);
        if (maybe_line == null) break;
        const line = maybe_line.?;
        defer allocator.free(line);

        // Create a command trace for this iteration
        const command_trace = session_trace.enter();
        defer command_trace.exit();
        command_trace.info("Processing command");
        command_trace.data("command-input").put("command", line).end();

        // Append prompt and code
        try out_log.appendSlice("> ");
        try out_log.appendSlice(line);
        try out_log.appendSlice("\n");

        // Evaluate via Wren VM
        const vm_trace = command_trace.enter();
        defer vm_trace.exit();
        vm_trace.info("Evaluating Wren script");

        wren_vm.interpret("main", line) catch |err| {
            vm_trace.decision("Script execution failed");
            vm_trace.data("script-error").put("error", @errorName(err)).end();
            switch (err) {
                error.CompileError => try out_log.appendSlice("// Compile error\n"),
                error.RuntimeError => try out_log.appendSlice("// Runtime error\n"),
                else => try out_log.appendSlice("// Unknown error\n"),
            }
        };

        // Update output area and redraw only once
        try setDomText(&ctx.dom, ctx.output_text_id, out_log.items);
        try renderDom(&ctx, command_trace);
    }
}

const RenderCtx = struct {
    allocator: std.mem.Allocator,
    unicode: *paint.UnicodeData,
    width: usize = 80,
    height: usize = 24,
    dom: Dom,
    root_id: DomNodeId,
    text_id: DomNodeId,
    output_text_id: DomNodeId,
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

    // Paint commands are now logged via the tracing system

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
    try out_ansi.resetStyle();
    try out_ansi.moveCursor(1, 1); // Move to top-left

    for (0..raster.height) |y| {
        if (y > 0) {
            try out_ansi.moveCursor(@intCast(y + 1), 1);
        }

        var current_bg: ?Rgba8 = null;
        var current_fg: ?Rgba8 = null;

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

    if (posix.system.ioctl(std.io.getStdOut().handle, posix.T.IOCGWINSZ, &ws) >= 0) {
        std.log.info("terminal size: {d}x{d}", .{ ws.col, ws.row });
        if (ws.col > 0 and ws.row > 0) {
            ctx.width = ws.col;
            ctx.height = ws.row;
        }
    }
}

pub const LineEditor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor_index: usize,
    history: std.ArrayList([]u8),
    history_index: ?usize, // index into history during navigation; null when not navigating

    pub fn init(allocator: std.mem.Allocator) !LineEditor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .cursor_index = 0,
            .history = std.ArrayList([]u8).init(allocator),
            .history_index = null,
        };
    }

    pub fn deinit(self: *LineEditor, allocator: std.mem.Allocator) void {
        // Free history entries
        for (self.history.items) |entry| allocator.free(entry);
        self.history.deinit();
        self.buffer.deinit();
    }

    fn clearBuffer(self: *LineEditor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_index = 0;
        self.history_index = null;
    }

    fn setBuffer(self: *LineEditor, content: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(content);
        self.cursor_index = self.buffer.items.len;
    }

    fn pushHistory(self: *LineEditor, line: []const u8) !void {
        if (line.len == 0) return; // skip empty
        const copy = try self.allocator.dupe(u8, line);
        try self.history.append(copy);
        self.history_index = null;
    }

    fn replaceWithHistory(self: *LineEditor, idx: usize) !void {
        if (idx >= self.history.items.len) return; // ignore
        try self.setBuffer(self.history.items[idx]);
        self.history_index = idx;
    }

    fn moveHistoryPrev(self: *LineEditor) !void {
        if (self.history.items.len == 0) return;
        const idx = self.history_index orelse self.history.items.len; // one past last means move to last
        if (idx == 0) return; // already at first
        try self.replaceWithHistory(idx - 1);
    }

    fn moveHistoryNext(self: *LineEditor) !void {
        if (self.history.items.len == 0) return;
        const idx = self.history_index orelse self.history.items.len; // one past last
        if (idx + 1 >= self.history.items.len) {
            // past the newest -> clear to editing a fresh line
            self.history_index = null;
            self.clearBuffer();
            return;
        }
        try self.replaceWithHistory(idx + 1);
    }

    fn writeAll(out: anytype, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const wrote = try out.write(remaining);
            remaining = remaining[wrote..];
        }
    }

    fn refreshLine(self: *LineEditor, _: anytype, _: []const u8) !void {
        // No-op: rendering is handled by DOM redraws
        _ = self;
    }

    fn insertByte(self: *LineEditor, b: u8) !void {
        if (self.cursor_index == self.buffer.items.len) {
            try self.buffer.append(b);
        } else {
            try self.buffer.insert(self.cursor_index, b);
        }
        self.cursor_index += 1;
    }

    fn deleteBack(self: *LineEditor) void {
        if (self.cursor_index == 0) return;
        _ = self.buffer.orderedRemove(self.cursor_index - 1);
        self.cursor_index -= 1;
    }

    fn deleteForward(self: *LineEditor) void {
        if (self.cursor_index >= self.buffer.items.len) return;
        _ = self.buffer.orderedRemove(self.cursor_index);
    }

    fn killToEnd(self: *LineEditor) void {
        if (self.cursor_index < self.buffer.items.len) {
            self.buffer.shrinkRetainingCapacity(self.cursor_index);
        }
    }

    fn moveLeft(self: *LineEditor) void {
        if (self.cursor_index > 0) self.cursor_index -= 1;
    }

    fn moveRight(self: *LineEditor) void {
        if (self.cursor_index < self.buffer.items.len) self.cursor_index += 1;
    }

    fn moveHome(self: *LineEditor) void {
        self.cursor_index = 0;
    }

    fn moveEnd(self: *LineEditor) void {
        self.cursor_index = self.buffer.items.len;
    }

    fn handleEscapeSequence(self: *LineEditor, seq: []const u8) !void {
        // Basic CSI parser for arrows/home/end/delete
        if (seq.len == 0) return;
        if (seq[0] == '[') {
            if (seq.len >= 2) {
                const final = seq[1];
                switch (final) {
                    'A' => try self.moveHistoryPrev(),
                    'B' => try self.moveHistoryNext(),
                    'C' => self.moveRight(),
                    'D' => self.moveLeft(),
                    'H' => self.moveHome(),
                    'F' => self.moveEnd(),
                    else => {
                        // Extended sequences like 3~ for Delete
                        if (final == '3' and seq.len >= 3 and seq[2] == '~') {
                            self.deleteForward();
                        }
                    },
                }
            }
        }
    }

    fn renderForInputEvent(self: *LineEditor, ctx: *RenderCtx, parent_trace: Trace, event_name: []const u8) !void {
        const input_trace = parent_trace.enter();
        defer input_trace.exit();
        input_trace.info("Input event triggered render");
        input_trace.data("input-event").put("event", event_name).end();

        try setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
        updateTerminalSize(ctx);
        try renderDom(ctx, input_trace);
    }

    pub fn prompt(self: *LineEditor, ctx: *RenderCtx, session_trace: Trace) !?[]u8 {
        // Initial render when entering prompt
        const prompt_trace = session_trace.enter();
        defer prompt_trace.exit();
        prompt_trace.info("Interactive prompt ready");

        try setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
        updateTerminalSize(ctx);
        try renderDom(ctx, prompt_trace);

        var in_buf: [64]u8 = undefined;
        while (true) {
            const nread = posix.read(posix.STDIN_FILENO, &in_buf) catch |e| switch (e) {
                error.InputOutput => continue,
                else => return e,
            };
            if (nread == 0) continue;

            var i: usize = 0;
            while (i < nread) : (i += 1) {
                const b = in_buf[i];
                switch (b) {
                    // Enter
                    '\n', '\r' => {
                        const line = try self.allocator.dupe(u8, self.buffer.items);
                        try self.pushHistory(line);
                        self.clearBuffer();
                        try self.renderForInputEvent(ctx, prompt_trace, "submit");
                        return line;
                    },
                    // Ctrl-D: EOF (only if line empty)
                    0x04 => {
                        if (self.buffer.items.len == 0) return null;
                        // else treat as delete-forward
                        self.deleteForward();
                    },
                    // Ctrl-A: beginning of line
                    0x01 => self.moveHome(),
                    // Ctrl-E: end of line
                    0x05 => self.moveEnd(),
                    // Ctrl-B: backward char
                    0x02 => self.moveLeft(),
                    // Ctrl-F: forward char
                    0x06 => self.moveRight(),
                    // Ctrl-K: kill to end of line
                    0x0B => self.killToEnd(),
                    // Ctrl-C: cancel line
                    0x03 => {
                        self.clearBuffer();
                        try self.renderForInputEvent(ctx, prompt_trace, "cancel");
                        break; // continue outer read loop
                    },
                    // Backspace or Ctrl-H
                    0x7f, 0x08 => self.deleteBack(),
                    // Escape sequences
                    0x1b => {
                        // Try to read remaining bytes available for this key sequence
                        // We expect ESC [ X or ESC [ num ~
                        if (i + 1 < nread and in_buf[i + 1] == '[') {
                            // Try to gather up to 3 more bytes (safe bound)
                            var tmp: [3]u8 = undefined;
                            var tlen: usize = 0;
                            var j: usize = i + 2;
                            while (j < nread and tlen < tmp.len) : (j += 1) {
                                tmp[tlen] = in_buf[j];
                                tlen += 1;
                                // Stop early for single-letter finals
                                if (tmp[tlen - 1] >= 'A' and tmp[tlen - 1] <= 'Z') break;
                                if (tmp[tlen - 1] == '~') break;
                            }
                            try self.handleEscapeSequence(in_buf[i + 1 .. i + 2 + tlen]);
                            i = i + 1 + tlen; // i will be incremented by loop
                        } else {
                            // Bare ESC: ignore
                        }
                    },
                    else => {
                        // Printable bytes (we keep it simple: byte-wise insert)
                        if (b >= 0x20 and b != 0x7f) {
                            try self.insertByte(b);
                        }
                    },
                }
            }
            try self.renderForInputEvent(ctx, prompt_trace, "key input");
        }
    }
};

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
