const std = @import("std");

const Rgba8 = u32;

pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Rgba8 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

pub fn rgba8Red(color: Rgba8) u8 {
    return @truncate(color);
}

pub fn rgba8Green(color: Rgba8) u8 {
    return @truncate(color >> 8);
}

pub fn rgba8Blue(color: Rgba8) u8 {
    return @truncate(color >> 16);
}

const GlyphId = u32;

pub fn ansiWriter(writer: anytype) AnsiWriter(@TypeOf(writer)) {
    return AnsiWriter(@TypeOf(writer)).init(writer);
}

/// ANSI escape sequence writer with semantic methods
pub fn AnsiWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        writer: WriterType,
        no_color: bool = false,

        inline fn writeAllGeneric(self: *Self, bytes: []const u8) !void {
            if (comptime @hasField(WriterType, "interface")) {
                try (&self.writer.interface).writeAll(bytes);
            } else {
                try self.writer.writeAll(bytes);
            }
        }

        inline fn printGeneric(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            if (comptime @hasField(WriterType, "interface")) {
                try (&self.writer.interface).print(fmt, args);
            } else {
                try self.writer.print(fmt, args);
            }
        }

        pub fn init(writer: WriterType) Self {
            return .{ .writer = writer, .no_color = false };
        }

        pub fn initNoColor(writer: WriterType) Self {
            return .{ .writer = writer, .no_color = true };
        }

        pub fn setNoColor(self: *Self, no_color: bool) void {
            self.no_color = no_color;
        }

        // Screen buffer management
        pub fn enterAlternateScreen(self: *Self) !void {
            try self.writeAllGeneric("\x1b[?1049h");
        }

        pub fn exitAlternateScreen(self: *Self) !void {
            try self.writeAllGeneric("\x1b[?1049l");
        }

        pub fn clearScreen(self: *Self) !void {
            try self.writeAllGeneric("\x1b[2J");
        }

        pub fn moveCursorHome(self: *Self) !void {
            try self.writeAllGeneric("\x1b[H");
        }

        // Cursor management
        pub fn hideCursor(self: *Self) !void {
            try self.writeAllGeneric("\x1b[?25l");
        }

        pub fn showCursor(self: *Self) !void {
            try self.writeAllGeneric("\x1b[?25h");
        }

        pub fn moveCursor(self: *Self, row: usize, col: usize) !void {
            try self.printGeneric("\x1b[{d};{d}H", .{ row, col });
        }

        // Style and color management
        pub fn resetStyle(self: *Self) !void {
            if (!self.no_color) {
                try self.writeAllGeneric("\x1b[0m");
            }
        }

        pub fn setBold(self: *Self) !void {
            if (!self.no_color) {
                try self.writeAllGeneric("\x1b[1m");
            }
        }

        pub fn resetBold(self: *Self) !void {
            if (!self.no_color) {
                try self.writeAllGeneric("\x1b[22m");
            }
        }

        pub fn setForegroundRgb(self: *Self, r: u8, g: u8, b: u8) !void {
            if (!self.no_color) {
                try self.printGeneric("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
            }
        }

        pub fn setBackgroundRgb(self: *Self, r: u8, g: u8, b: u8) !void {
            if (!self.no_color) {
                try self.printGeneric("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
            }
        }

        pub fn setForeground(self: *Self, color: Rgba8) !void {
            try self.setForegroundRgb(rgba8Red(color), rgba8Green(color), rgba8Blue(color));
        }

        pub fn setBackground(self: *Self, color: Rgba8) !void {
            try self.setBackgroundRgb(rgba8Red(color), rgba8Green(color), rgba8Blue(color));
        }

        pub fn resetForeground(self: *Self) !void {
            if (!self.no_color) {
                try self.writeAllGeneric("\x1b[39m");
            }
        }

        pub fn resetBackground(self: *Self) !void {
            if (!self.no_color) {
                try self.writeAllGeneric("\x1b[49m");
            }
        }

        // Convenience methods for common operations
        pub fn initializeTerminal(self: *Self) !void {
            try self.enterAlternateScreen();
            try self.hideCursor();
            try self.clearScreen();
            try self.moveCursorHome();
        }

        pub fn restoreTerminal(self: *Self) !void {
            try self.resetStyle();
            try self.showCursor();
            try self.exitAlternateScreen();
        }

        // Direct writer access for other content
        pub fn write(self: *Self, bytes: []const u8) !usize {
            if (comptime @hasField(WriterType, "interface")) {
                return (&self.writer.interface).write(bytes);
            } else {
                return self.writer.write(bytes);
            }
        }

        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            try self.writeAllGeneric(bytes);
        }

        pub fn print(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.printGeneric(format, args);
        }

        // Helper to write glyph IDs using a glyph table
        pub fn writeGlyphs(self: *Self, glyphs: []const GlyphId, glyph_table: anytype) !void {
            for (glyphs) |gid| {
                if (glyph_table.getSlice(gid)) |bytes| {
                    try self.writeAllGeneric(bytes);
                } else {
                    try self.writeAllGeneric("?");
                }
            }
        }

        // Convenience methods for styled text writing
        pub fn writeBold(self: *Self, text: []const u8) !void {
            try self.setBold();
            try self.writeAllGeneric(text);
            try self.resetStyle();
        }

        pub fn writeColoredText(self: *Self, text: []const u8, r: u8, g: u8, b: u8) !void {
            try self.setForegroundRgb(r, g, b);
            try self.writeAllGeneric(text);
            try self.resetStyle();
        }

        pub fn writeBoldColored(self: *Self, text: []const u8, r: u8, g: u8, b: u8) !void {
            try self.setBold();
            try self.setForegroundRgb(r, g, b);
            try self.writeAllGeneric(text);
            try self.resetStyle();
        }
    };
}

/// Type aliases for common use cases
pub const StdoutAnsiWriter = AnsiWriter(std.fs.File.Writer);
pub const ArrayListAnsiWriter = AnsiWriter(std.ArrayList(u8).Writer);

// Global stdout writer state for 0.15. Avoids stack-buffer lifetime bugs.
var g_stdout_buf: [4096]u8 = undefined;
var g_stdout_state: std.fs.File.Writer = undefined;
var g_stdout_inited: bool = false;

fn ensureStdout() void {
    if (!g_stdout_inited) {
        g_stdout_state = std.fs.File.stdout().writer(&g_stdout_buf);
        g_stdout_inited = true;
    }
}

/// Convenience function to create an ANSI writer from stdout
pub fn stdout() StdoutAnsiWriter {
    ensureStdout();
    return StdoutAnsiWriter.init(g_stdout_state);
}

/// Convenience function to create an ANSI writer from an ArrayList
pub fn arrayListWriter(list: *std.ArrayList(u8), allocator: std.mem.Allocator) ArrayListAnsiWriter {
    return ArrayListAnsiWriter.init(list.writer(allocator));
}

/// Convenience function to create a no-color ANSI writer from an ArrayList
pub fn arrayListWriterNoColor(list: *std.ArrayList(u8), allocator: std.mem.Allocator) ArrayListAnsiWriter {
    return ArrayListAnsiWriter.initNoColor(list.writer(allocator));
}

test "ansi writer basic operations" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = arrayListWriter(&buffer, std.testing.allocator);

    try ansi.resetStyle();
    try ansi.moveCursor(10, 20);
    try ansi.setForegroundRgb(255, 128, 64);
    try ansi.writeAll("Hello, World!");

    const expected = "\x1b[0m\x1b[10;20H\x1b[38;2;255;128;64mHello, World!";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "ansi writer terminal setup and teardown" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = arrayListWriter(&buffer, std.testing.allocator);

    try ansi.initializeTerminal();
    try ansi.writeAll("Content");
    try ansi.restoreTerminal();

    const expected = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[HContent\x1b[0m\x1b[?25h\x1b[?1049l";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "ansi writer rgba8 colors" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = arrayListWriter(&buffer);

    const red = rgba8(255, 0, 0, 255);
    const blue = rgba8(0, 0, 255, 255);

    try ansi.setForeground(red);
    try ansi.setBackground(blue);
    try ansi.writeAll("Hello");
    try ansi.resetForeground();
    try ansi.resetBackground();

    const expected = "\x1b[38;2;255;0;0m\x1b[48;2;0;0;255mHello\x1b[39m\x1b[49m";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "ansi writer bold styling" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = arrayListWriter(&buffer);

    try ansi.setBold();
    try ansi.writeAll("Bold Text");
    try ansi.resetBold();
    try ansi.writeAll(" Normal Text");

    const expected = "\x1b[1mBold Text\x1b[22m Normal Text";
    try std.testing.expectEqualStrings(expected, buffer.items);
}
