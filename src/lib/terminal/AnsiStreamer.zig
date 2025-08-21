const std = @import("std");

/// Non-allocating ANSI escape sequence generator
/// Writes ANSI codes directly to any writer without allocation
pub const AnsiStreamer = struct {
    no_color: bool = false,

    pub fn init(no_color: bool) AnsiStreamer {
        return .{ .no_color = no_color };
    }

    // === Screen Management ===

    pub fn clearScreen(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[2J");
    }

    pub fn moveCursorHome(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[H");
    }

    pub fn moveCursor(self: AnsiStreamer, writer: anytype, row: u32, col: u32) !void {
        if (self.no_color) return;
        try writer.print("\x1b[{d};{d}H", .{ row, col });
    }

    pub fn hideCursor(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[?25l");
    }

    pub fn showCursor(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[?25h");
    }

    // === Style Management ===

    pub fn resetStyle(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[0m");
    }

    pub fn setBold(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[1m");
    }

    pub fn setDim(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[2m");
    }

    pub fn setItalic(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[3m");
    }

    pub fn setUnderline(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[4m");
    }

    pub fn resetBold(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[22m");
    }

    pub fn resetDim(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[22m");
    }

    pub fn resetItalic(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[23m");
    }

    pub fn resetUnderline(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[24m");
    }

    // === Color Management ===

    pub fn setForegroundRgb(self: AnsiStreamer, writer: anytype, r: u8, g: u8, b: u8) !void {
        if (self.no_color) return;
        try writer.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
    }

    pub fn setBackgroundRgb(self: AnsiStreamer, writer: anytype, r: u8, g: u8, b: u8) !void {
        if (self.no_color) return;
        try writer.print("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
    }

    pub fn resetForeground(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[39m");
    }

    pub fn resetBackground(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[49m");
    }

    // === Alternate Screen Buffer ===

    pub fn enterAlternateScreen(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[?1049h");
    }

    pub fn exitAlternateScreen(self: AnsiStreamer, writer: anytype) !void {
        if (self.no_color) return;
        try writer.writeAll("\x1b[?1049l");
    }

    // === Convenience Combinations ===

    pub fn initializeTerminal(self: AnsiStreamer, writer: anytype) !void {
        try self.enterAlternateScreen(writer);
        try self.hideCursor(writer);
        try self.clearScreen(writer);
        try self.moveCursorHome(writer);
    }

    pub fn restoreTerminal(self: AnsiStreamer, writer: anytype) !void {
        try self.resetStyle(writer);
        try self.showCursor(writer);
        try self.exitAlternateScreen(writer);
    }
};

// === Tests ===

test "AnsiStreamer basic operations" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const ansi = AnsiStreamer.init(false);

    try ansi.resetStyle(buffer.writer());
    try ansi.moveCursor(buffer.writer(), 10, 20);
    try ansi.setForegroundRgb(buffer.writer(), 255, 128, 64);

    const expected = "\x1b[0m\x1b[10;20H\x1b[38;2;255;128;64m";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "AnsiStreamer no color mode" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const ansi = AnsiStreamer.init(true); // no_color = true

    try ansi.resetStyle(buffer.writer());
    try ansi.setBold(buffer.writer());
    try ansi.setForegroundRgb(buffer.writer(), 255, 0, 0);

    // Should produce no output in no-color mode
    try std.testing.expectEqualStrings("", buffer.items);
}

test "AnsiStreamer terminal initialization" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    const ansi = AnsiStreamer.init(false);

    try ansi.initializeTerminal(buffer.writer());
    try ansi.restoreTerminal(buffer.writer());

    const expected = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H\x1b[0m\x1b[?25h\x1b[?1049l";
    try std.testing.expectEqualStrings(expected, buffer.items);
}