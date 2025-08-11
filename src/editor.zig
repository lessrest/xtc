const std = @import("std");
const posix = @import("posix.zig");
const dom = @import("dom.zig");

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

    fn renderForInputEvent(self: *LineEditor, ctx: *dom.RenderCtx, parent_trace: dom.Trace, event_name: []const u8) !void {
        const input_trace = parent_trace.enter();
        defer input_trace.exit();
        input_trace.info("Input event triggered render");
        input_trace.data("input-event").put("event", event_name).end();

        try dom.setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
        dom.updateTerminalSize(ctx);
        try dom.renderDom(ctx, input_trace);
    }

    pub fn prompt(self: *LineEditor, ctx: *dom.RenderCtx, session_trace: dom.Trace) !?[]u8 {
        // Initial render when entering prompt
        const prompt_trace = session_trace.enter();
        defer prompt_trace.exit();
        prompt_trace.info("Interactive prompt ready");

        try dom.setDomText(&ctx.dom, ctx.text_id, self.buffer.items);
        dom.updateTerminalSize(ctx);
        try dom.renderDom(ctx, prompt_trace);

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
