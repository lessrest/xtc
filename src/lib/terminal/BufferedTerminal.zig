const std = @import("std");
const AnsiStreamer = @import("AnsiStreamer.zig").AnsiStreamer;
const TreeFormatter = @import("TreeFormatter.zig").TreeFormatter;
const StyleApplier = @import("StyleApplier.zig");

pub const Style = StyleApplier.Style;

/// Buffered terminal that coordinates ANSI output, tree formatting, and styling
pub fn BufferedTerminal(comptime Writer: type, comptime buffer_size: usize) type {
    return struct {
        const Self = @This();

        writer: Writer,
        buffer: [buffer_size]u8,
        pos: usize = 0,
        
        ansi: AnsiStreamer,
        tree: TreeFormatter,
        style: StyleApplier.StyleApplier,

        pub fn init(writer: Writer, no_color: bool) Self {
            return .{
                .writer = writer,
                .buffer = [_]u8{0} ** buffer_size,
                .ansi = AnsiStreamer.init(no_color),
                .tree = TreeFormatter.init(),
                .style = StyleApplier.StyleApplier.init(),
            };
        }

        /// Flush buffered content to the underlying writer
        pub fn flush(self: *Self) !void {
            if (self.pos > 0) {
                try self.writer.writeAll(self.buffer[0..self.pos]);
                self.pos = 0;
            }
        }

        /// Get a writer that writes to the internal buffer
        fn bufferWriter(self: *Self) BufferWriter {
            return BufferWriter{ .terminal = self };
        }

        /// Internal writer that automatically flushes when buffer is full
        const BufferWriter = struct {
            terminal: *Self,

            const WriteError = error{BufferFull} || @TypeOf(@as(Writer, undefined)).Error;

            pub fn writeAll(self: BufferWriter, bytes: []const u8) WriteError!void {
                // If data is too large for buffer, flush and write directly
                if (bytes.len > buffer_size) {
                    try self.terminal.flush();
                    return self.terminal.writer.writeAll(bytes);
                }

                // If buffer would overflow, flush first
                if (self.terminal.pos + bytes.len > buffer_size) {
                    try self.terminal.flush();
                }

                // Copy to buffer
                @memcpy(self.terminal.buffer[self.terminal.pos..self.terminal.pos + bytes.len], bytes);
                self.terminal.pos += bytes.len;
            }

            pub fn print(self: BufferWriter, comptime fmt: []const u8, args: anytype) WriteError!void {
                // Estimate size needed - use a reasonable stack buffer
                var temp_buffer: [512]u8 = undefined;
                const formatted = std.fmt.bufPrint(&temp_buffer, fmt, args) catch {
                    // If too large for stack buffer, flush and write directly
                    try self.terminal.flush();
                    return self.terminal.writer.print(fmt, args);
                };
                try self.writeAll(formatted);
            }
        };

        // === Basic Output ===

        pub fn writeText(self: *Self, text: []const u8) !void {
            try self.bufferWriter().writeAll(text);
        }

        pub fn writeStyledText(self: *Self, text: []const u8, style: Style) !void {
            const writer = self.bufferWriter();
            try self.style.apply(writer, &self.ansi, style);
            try writer.writeAll(text);
        }

        pub fn writeLine(self: *Self, text: []const u8) !void {
            const writer = self.bufferWriter();
            try writer.writeAll(text);
            try writer.writeAll("\n");
        }

        pub fn writeStyledLine(self: *Self, text: []const u8, style: Style) !void {
            const writer = self.bufferWriter();
            try self.style.apply(writer, &self.ansi, style);
            try writer.writeAll(text);
            try writer.writeAll("\n");
        }

        // === Tree Output ===

        pub fn enterTree(self: *Self) !void {
            try self.tree.enter();
        }

        pub fn exitTree(self: *Self) void {
            self.tree.exit();
        }

        pub fn writeTreeNode(self: *Self, text: []const u8, style: Style, is_last: bool) !void {
            const writer = self.bufferWriter();
            
            // Apply tree indentation
            if (self.tree.getCurrentDepth() > 0) {
                try self.tree.writeIndent(writer, is_last);
            }
            
            // Apply style and write text
            try self.style.apply(writer, &self.ansi, style);
            try writer.writeAll(text);
            try writer.writeAll("\n");
            
            // Update tree state
            if (is_last) {
                self.tree.setLast();
            }
        }

        pub fn writeTreeLine(self: *Self, text: []const u8, style: Style) !void {
            const writer = self.bufferWriter();
            
            // Apply tree continuation
            if (self.tree.getCurrentDepth() > 0) {
                try self.tree.writeContinuation(writer);
            }
            
            // Apply style and write text
            try self.style.apply(writer, &self.ansi, style);
            try writer.writeAll(text);
            try writer.writeAll("\n");
        }

        // === Style Management ===

        pub fn resetStyle(self: *Self) !void {
            try self.style.reset(self.bufferWriter(), &self.ansi);
        }

        // === Terminal Control ===

        pub fn clearScreen(self: *Self) !void {
            try self.ansi.clearScreen(self.bufferWriter());
        }

        pub fn moveCursor(self: *Self, row: u32, col: u32) !void {
            try self.ansi.moveCursor(self.bufferWriter(), row, col);
        }

        pub fn initializeTerminal(self: *Self) !void {
            try self.ansi.initializeTerminal(self.bufferWriter());
        }

        pub fn restoreTerminal(self: *Self) !void {
            try self.ansi.restoreTerminal(self.bufferWriter());
        }

        // === Utility ===

        pub fn reset(self: *Self) void {
            self.pos = 0;
            self.tree.reset();
            self.style = StyleApplier.StyleApplier.init();
        }

        pub fn getCurrentDepth(self: *const Self) u8 {
            return self.tree.getCurrentDepth();
        }
    };
}

/// Convenience type for stdout with 4KB buffer
pub const StdoutTerminal = BufferedTerminal(std.fs.File.Writer, 4096);

/// Create a terminal that writes to stdout
pub fn stdout(no_color: bool) StdoutTerminal {
    return StdoutTerminal.init(std.io.getStdOut().writer(), no_color);
}

/// Convenience type for testing with ArrayList
pub const TestTerminal = BufferedTerminal(std.ArrayList(u8).Writer, 1024);

/// Create a terminal that writes to an ArrayList (for testing)
pub fn arrayListTerminal(list: *std.ArrayList(u8), no_color: bool) TestTerminal {
    return TestTerminal.init(list.writer(), no_color);
}

// === Tests ===

test "BufferedTerminal basic output" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, false);

    try terminal.writeLine("Hello, World!");
    try terminal.flush();

    try std.testing.expectEqualStrings("Hello, World!\n", buffer.items);
}

test "BufferedTerminal styled output" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, false);

    const red_style = Style.withForeground(255, 0, 0);
    try terminal.writeStyledLine("Error!", red_style);
    try terminal.flush();

    try std.testing.expectEqualStrings("\x1b[38;2;255;0;0mError!\n", buffer.items);
}

test "BufferedTerminal tree output" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, true); // no_color for simpler testing

    try terminal.writeLine("Root");
    try terminal.enterTree();
    try terminal.writeTreeNode("Child 1", Style.init(), false);
    try terminal.writeTreeLine("Details for child 1", Style.init());
    try terminal.writeTreeNode("Child 2", Style.init(), true);
    terminal.exitTree();
    try terminal.flush();

    const expected = 
        \\Root
        \\┌─ Child 1
        \\│  Details for child 1
        \\└─ Child 2
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "BufferedTerminal no color mode" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, true); // no_color = true

    const red_style = Style.withForeground(255, 0, 0);
    try terminal.writeStyledLine("No color", red_style);
    try terminal.flush();

    // Should produce no ANSI codes in no-color mode
    try std.testing.expectEqualStrings("No color\n", buffer.items);
}

test "BufferedTerminal automatic flushing" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    // Create terminal with small buffer to test auto-flush
    var terminal = BufferedTerminal(std.ArrayList(u8).Writer, 10).init(buffer.writer(), true);

    // Write more than buffer size
    try terminal.writeText("This is a long string that exceeds the buffer size");
    try terminal.flush();

    try std.testing.expectEqualStrings("This is a long string that exceeds the buffer size", buffer.items);
}