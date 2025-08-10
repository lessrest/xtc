const std = @import("std");

// Import types
const Rgba8 = @import("paint.zig").Rgba8;
const rgba8 = @import("paint.zig").rgba8;
const rgba8Red = @import("paint.zig").rgba8Red;
const rgba8Green = @import("paint.zig").rgba8Green;
const rgba8Blue = @import("paint.zig").rgba8Blue;
const GlyphId = @import("tty.zig").GlyphId;

/// ANSI escape sequence writer with semantic methods
pub fn AnsiWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        writer: WriterType,

        pub fn init(writer: WriterType) Self {
            return .{ .writer = writer };
        }

        // Screen buffer management
        pub fn enterAlternateScreen(self: *Self) !void {
            try self.writer.writeAll("\x1b[?1049h");
        }

        pub fn exitAlternateScreen(self: *Self) !void {
            try self.writer.writeAll("\x1b[?1049l");
        }

        pub fn clearScreen(self: *Self) !void {
            try self.writer.writeAll("\x1b[2J");
        }

        pub fn moveCursorHome(self: *Self) !void {
            try self.writer.writeAll("\x1b[H");
        }

        // Cursor management
        pub fn hideCursor(self: *Self) !void {
            try self.writer.writeAll("\x1b[?25l");
        }

        pub fn showCursor(self: *Self) !void {
            try self.writer.writeAll("\x1b[?25h");
        }

        pub fn moveCursor(self: *Self, row: usize, col: usize) !void {
            try self.writer.print("\x1b[{d};{d}H", .{ row, col });
        }

        // Style and color management
        pub fn resetStyle(self: *Self) !void {
            try self.writer.writeAll("\x1b[0m");
        }

        pub fn setForegroundRgb(self: *Self, r: u8, g: u8, b: u8) !void {
            try self.writer.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
        }

        pub fn setBackgroundRgb(self: *Self, r: u8, g: u8, b: u8) !void {
            try self.writer.print("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
        }

        pub fn setForeground(self: *Self, color: Rgba8) !void {
            try self.setForegroundRgb(rgba8Red(color), rgba8Green(color), rgba8Blue(color));
        }

        pub fn setBackground(self: *Self, color: Rgba8) !void {
            try self.setBackgroundRgb(rgba8Red(color), rgba8Green(color), rgba8Blue(color));
        }

        pub fn resetForeground(self: *Self) !void {
            try self.writer.writeAll("\x1b[39m");
        }

        pub fn resetBackground(self: *Self) !void {
            try self.writer.writeAll("\x1b[49m");
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
            return self.writer.write(bytes);
        }

        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }

        pub fn print(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.writer.print(format, args);
        }

        // Helper to write glyph IDs using a glyph table
        pub fn writeGlyphs(self: *Self, glyphs: []const GlyphId, glyph_table: anytype) !void {
            for (glyphs) |gid| {
                if (glyph_table.getSlice(gid)) |bytes| {
                    try self.writeAll(bytes);
                } else {
                    try self.writeAll("?");
                }
            }
        }
    };
}

/// Type aliases for common use cases
pub const StdoutAnsiWriter = AnsiWriter(std.fs.File.Writer);
pub const ArrayListAnsiWriter = AnsiWriter(std.ArrayList(u8).Writer);

/// Convenience function to create an ANSI writer from stdout
pub fn stdout() StdoutAnsiWriter {
    return StdoutAnsiWriter.init(std.io.getStdOut().writer());
}

/// Convenience function to create an ANSI writer from an ArrayList
pub fn arrayListWriter(list: *std.ArrayList(u8)) ArrayListAnsiWriter {
    return ArrayListAnsiWriter.init(list.writer());
}

test "ansi writer basic operations" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = arrayListWriter(&buffer);

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

    var ansi = arrayListWriter(&buffer);

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
