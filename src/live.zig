const std = @import("std");
const posix = std.posix;
const lib = @import("lib.zig");
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

pub fn run(allocator: std.mem.Allocator, log_path: ?[]const u8) !void {
    _ = log_path; // autofix
    var raw = try RawMode.enable(posix.STDIN_FILENO);
    defer raw.disable() catch {};

    // Enter alternate screen buffer and hide cursor; restore on exit
    var w = std.io.getStdOut().writer();
    _ = try w.write("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
    defer {
        var w2 = std.io.getStdOut().writer();
        _ = w2.write("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
    }

    var provider = lib.StyleProvider{ .graphemes = try Graphemes.init(allocator), .display_width = try DisplayWidth.init(allocator) };
    defer provider.graphemes.deinit(allocator);
    defer provider.display_width.deinit(allocator);

    var dom = lib.Dom.init(allocator);
    defer dom.deinit();

    const root_id = try dom.addElement(
        "flex flex-col",
    );
    const prolog_output_id = try dom.addElement(
        "w-76 grow-1 border-2 border-gray-200 text-slate-800 bg-blue-100",
    );
    const child_id = try dom.addElement(
        "px-4 flex py-1 w-76 h-3 flex-0 border-2 border-gray-200 text-blue-200 bg-blue-700",
    );

    const text_id = try dom.addText("foo");
    dom.appendChild(child_id, try dom.addText("» "));
    dom.appendChild(child_id, text_id);
    dom.appendChild(root_id, prolog_output_id);
    dom.appendChild(root_id, child_id);

    var ctx = RenderCtx{ .allocator = allocator, .provider = &provider, .width = 80, .height = 24, .dom = dom, .root_id = root_id, .text_id = text_id, .raster_front = null, .raster_back = null, .log = null };

    var editor = try LineEditor.init(allocator);
    defer editor.deinit(allocator);

    while (true) {
        const maybe_line = try editor.prompt(&ctx);
        if (maybe_line == null) break;
        const line = maybe_line.?;
        defer allocator.free(line);
        // For now, we don't echo separately; DOM already reflects cleared line.
    }
}

const RenderCtx = struct {
    allocator: std.mem.Allocator,
    provider: *lib.StyleProvider,
    width: usize = 80,
    height: usize = 24,
    dom: lib.Dom,
    root_id: lib.DomNodeId,
    text_id: lib.DomNodeId,
    resized: bool = false,
    raster_front: ?lib.Raster = null,
    raster_back: ?lib.Raster = null,
    log: ?std.fs.File = null,
};

fn setDomText(dom: *lib.Dom, text_id: lib.DomNodeId, text: []const u8) !void {
    const off: u32 = @intCast(dom.text_arena.items.len);
    try dom.text_arena.appendSlice(text);
    const len: u32 = @intCast(text.len);
    var items = dom.headers.slice();
    const idx: usize = @intCast(text_id);
    items.items(.first_child)[idx] = @as(lib.DomNodeId, off);
    items.items(.child_count)[idx] = len;
}

fn ensureDoubleRaster(ctx: *RenderCtx) !struct { front: *lib.Raster, back: *lib.Raster } {
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
        const r = try lib.Raster.init(al, ctx.width, ctx.height);
        ctx.raster_front = r;
    }
    if (ctx.raster_back == null) {
        const r = try lib.Raster.init(al, ctx.width, ctx.height);
        ctx.raster_back = r;
    }
    return .{ .front = &ctx.raster_front.?, .back = &ctx.raster_back.? };
}

const pretty = @import("pretty");

fn renderDom(ctx: *RenderCtx) !void {
    const al = ctx.allocator;

    var tree = try lib.buildBoxTreeFromDomAlloc(al, &ctx.dom, ctx.root_id);
    defer tree.deinit();

    try lib.layoutBoxesInPlace(al, &tree, &ctx.dom, tree.root_index, .{ .x = 0, .y = 0, .w = ctx.width, .h = ctx.height }, ctx.provider.*);
    //    std.debug.print("layout: {}\n", .{try lib.dumpBoxTreeNodeXml(al, std.io.getStdErr().writer(), &tree, &ctx.dom, tree.root_index, 0)});
    var dl = lib.PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try lib.GlyphTable.init(al);
    defer glyphs.deinit();

    try lib.computePaintCommands(&dl, &ctx.dom, &tree, &glyphs);
    // Double-buffered raster: render into back, diff against front, then swap
    var rb = try ensureDoubleRaster(ctx);
    rb.back.clear();
    try lib.rasterizeDisplayListAscii(rb.back, al, &glyphs, &dl);

    // Emit diffs from front -> back
    var out = std.ArrayList(u8).init(al);
    defer out.deinit();
    try out.appendSlice("\x1b[0m"); // reset styles; no clear, we'll position per change
    var cur_fg: ?lib.Rgba8 = null;
    var cur_bg: ?lib.Rgba8 = null;
    var y: usize = 0;
    while (y < rb.back.height) : (y += 1) {
        var x: usize = 0;
        while (x < rb.back.width) : (x += 1) {
            const idx = y * rb.back.width + x;
            const g0 = rb.front.cells[idx];
            const g1 = rb.back.cells[idx];
            const fg0 = rb.front.fg_set[idx];
            const fg1 = rb.back.fg_set[idx];
            const bg0 = rb.front.bg_set[idx];
            const bg1 = rb.back.bg_set[idx];
            const fg_eq = if (fg0 == fg1 and (!fg1 or std.meta.eql(rb.front.fg[idx], rb.back.fg[idx]))) true else false;
            const bg_eq = if (bg0 == bg1 and (!bg1 or std.meta.eql(rb.front.bg[idx], rb.back.bg[idx]))) true else false;
            if (g0 == g1 and fg_eq and bg_eq) continue;
            // Move cursor to 1-based row/col
            try out.writer().print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
            // Set/clear bg
            if (rb.back.bg_set[idx]) {
                const b = rb.back.bg[idx];
                if (cur_bg == null or !std.meta.eql(cur_bg.?, b)) {
                    try out.writer().print("\x1b[48;2;{d};{d};{d}m", .{ b.r, b.g, b.b });
                    cur_bg = b;
                }
            } else if (cur_bg != null) {
                try out.appendSlice("\x1b[49m");
                cur_bg = null;
            }
            // Set/clear fg
            if (rb.back.fg_set[idx]) {
                const f = rb.back.fg[idx];
                if (cur_fg == null or !std.meta.eql(cur_fg.?, f)) {
                    try out.writer().print("\x1b[38;2;{d};{d};{d}m", .{ f.r, f.g, f.b });
                    cur_fg = f;
                }
            } else if (cur_fg != null) {
                try out.appendSlice("\x1b[39m");
                cur_fg = null;
            }
            // Emit glyph from back
            if (g1 <= 255) {
                try out.append(@as(u8, @intCast(g1)));
            } else if (glyphs.getSlice(g1)) |bytes| {
                try out.appendSlice(bytes);
            } else {
                try out.append('?');
            }
        }
    }
    // Optional: reset at end
    try out.appendSlice("\x1b[0m");

    var w = std.io.getStdOut().writer();
    _ = try w.write(out.items);

    // Swap front/back for next frame
    const tmp = ctx.raster_front.?;
    ctx.raster_front = ctx.raster_back.?;
    ctx.raster_back = tmp;
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

    pub fn prompt(self: *LineEditor, ctx: *RenderCtx) !?[]u8 {
        try setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
        updateTerminalSize(ctx);
        try renderDom(ctx);

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
                        try setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
                        try renderDom(ctx);
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
                        try setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
                        updateTerminalSize(ctx);
                        try renderDom(ctx);
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
            try setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
            updateTerminalSize(ctx);
            try renderDom(ctx);
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
