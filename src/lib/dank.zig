const std = @import("std");
const treenest = @import("treenest.zig");

const Color = treenest.Color;
const Style = treenest.Style;

pub const Icon = enum {
    check,
    cross,
    dot,
    arrow,
    warning,
    info,
    skip,
    box,
    folder,
    file,
    branch,
    hourglass,
    gear,
    lightning,
    star,

    pub fn str(self: Icon) []const u8 {
        return switch (self) {
            .check => "✓",
            .cross => "✗",
            .dot => "•",
            .arrow => "▶",
            .warning => "⚠",
            .info => "ℹ",
            .skip => "⊘",
            .box => "▒",
            .folder => "📁",
            .file => "📄",
            .branch => "⎇",
            .hourglass => "⏳",
            .gear => "⚙",
            .lightning => "⚡",
            .star => "★",
        };
    }

    pub fn style(self: Icon) Style {
        return switch (self) {
            .check => .{ .fg = Color.green },
            .cross => .{ .fg = Color.red },
            .warning => .{ .fg = Color.yellow },
            .skip => .{ .fg = Color.yellow },
            .info => .{ .fg = Color.cyan },
            .hourglass => .{ .fg = Color.gray },
            .gear => .{ .fg = Color.gray },
            .lightning => .{ .fg = Color.yellow },
            .star => .{ .fg = Color.yellow },
            else => .{ .fg = Color.gray },
        };
    }
};

pub fn Dank(comptime Writer: type) type {
    return struct {
        writer: Writer,
        allocator: std.mem.Allocator,
        tree: *treenest.TreeNest(Writer),

        const Self = @This();

        pub fn withTree(allocator: std.mem.Allocator, tree: *treenest.TreeNest(Writer)) Self {
            return .{
                .writer = tree.writer,
                .allocator = allocator,
                .tree = tree,
            };
        }

        // Test result formatting
        pub fn testPass(self: Self, name: []const u8, duration_ms: ?f64) !void {
            var buf: [512]u8 = undefined;
            const text = if (duration_ms) |ms|
                try std.fmt.bufPrint(&buf, "{s} {s} ({d:.2}ms)", .{ Icon.check.str(), name, ms })
            else
                try std.fmt.bufPrint(&buf, "{s} {s}", .{ Icon.check.str(), name });

            try self.tree.styledLine(text, .{ .fg = Color.green });
        }

        pub fn testFail(self: Self, name: []const u8, err: []const u8, duration_ms: ?f64) !void {
            var buf: [512]u8 = undefined;
            const text = if (duration_ms) |ms|
                try std.fmt.bufPrint(&buf, "{s} {s} ({d:.2}ms) - {s}", .{ Icon.cross.str(), name, ms, err })
            else
                try std.fmt.bufPrint(&buf, "{s} {s} - {s}", .{ Icon.cross.str(), name, err });

            try self.tree.styledLine(text, .{ .fg = Color.red });
        }

        pub fn testSkip(self: Self, name: []const u8) !void {
            var buf: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s} {s} [skipped]", .{ Icon.skip.str(), name });

            try self.tree.styledLine(text, .{ .fg = Color.yellow });
        }

        pub fn testCompact(self: Self, passed: bool) !void {
            if (passed) {
                try self.writer.print("\x1b[32m▒\x1b[0m", .{});
            } else {
                try self.writer.print("\x1b[31m█\x1b[0m", .{});
            }
        }

        // Progress bar
        pub fn progressBar(self: Self, current: usize, total: usize, width: usize) !void {
            const filled = (current * width) / total;
            const empty = width - filled;

            try self.writer.writeAll("[");
            try self.writer.writeAll("\x1b[32m");
            for (0..filled) |_| {
                try self.writer.writeAll("█");
            }
            try self.writer.writeAll("\x1b[90m");
            for (0..empty) |_| {
                try self.writer.writeAll("░");
            }
            try self.writer.writeAll("\x1b[0m");
            try self.writer.print("] {d}/{d}", .{ current, total });
        }

        // Subprocess output formatting
        pub fn subprocessOutput(self: Self, text: []const u8, is_stderr: bool) !void {
            const style: Style = if (is_stderr)
                .{ .fg = Color.rgb(240, 150, 150) }
            else
                .{ .fg = Color.dimGray };

            try self.tree.styledLine(text, style);
        }

        // Header/section formatting
        pub fn section(self: Self, title: []const u8) !void {
            try self.tree.styledNode(title, .{ .fg = Color.rgb(150, 150, 255), .bold = true }, false);
        }

        // Status messages
        pub fn success(self: Self, msg: []const u8) !void {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s} {s}", .{ Icon.check.str(), msg });

            try self.tree.styledLine(text, .{ .fg = Color.green });
        }

        pub fn errorMsg(self: Self, msg: []const u8) !void {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s} {s}", .{ Icon.cross.str(), msg });

            try self.tree.styledLine(text, .{ .fg = Color.red, .bold = true });
        }

        pub fn warning(self: Self, msg: []const u8) !void {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s} {s}", .{ Icon.warning.str(), msg });

            try self.tree.styledLine(text, .{ .fg = Color.yellow });
        }

        pub fn info(self: Self, msg: []const u8) !void {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s} {s}", .{ Icon.info.str(), msg });

            try self.tree.styledLine(text, .{ .fg = Color.cyan });
        }

        // Table formatting
        pub fn table(self: Self, headers: []const []const u8, rows: []const []const []const u8, col_widths: ?[]const usize) !void {
            // Calculate column widths if not provided
            var widths_buf: [32]usize = undefined;
            const widths = if (col_widths) |w| w else blk: {
                for (headers, 0..) |h, i| {
                    widths_buf[i] = h.len;
                }
                for (rows) |row| {
                    for (row, 0..) |cell, i| {
                        if (cell.len > widths_buf[i]) {
                            widths_buf[i] = cell.len;
                        }
                    }
                }
                break :blk widths_buf[0..headers.len];
            };

            // Print headers
            try self.writer.writeAll("\x1b[1m");
            for (headers, 0..) |header, i| {
                if (i > 0) try self.writer.writeAll("  ");
                try self.writer.print("{s:<[width]}", .{ header, widths[i] });
            }
            try self.writer.writeAll("\x1b[0m\n");

            // Print separator
            try self.writer.writeAll("\x1b[90m");
            for (widths, 0..) |width, i| {
                if (i > 0) try self.writer.writeAll("  ");
                for (0..width) |_| {
                    try self.writer.writeAll("─");
                }
            }
            try self.writer.writeAll("\x1b[0m\n");

            // Print rows
            for (rows) |row| {
                for (row, 0..) |cell, i| {
                    if (i > 0) try self.writer.writeAll("  ");
                    try self.writer.print("{s:<[width]}", .{ cell, widths[i] });
                }
                try self.writer.writeAll("\n");
            }
        }

        // Stack trace formatting
        pub fn stackFrame(self: Self, file: []const u8, line: u64, col: u64, func: []const u8) !void {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s}:{d}:{d}: {s}", .{ file, line, col, func });
            try self.tree.styledLine(text, .{ .fg = Color.gray });
        }

        // Source block with box drawing borders
        pub fn sourceBlock(self: Self, code: []const u8, highlight_line: u64, highlight_col: ?u64, context_lines: u32) !void {
            var lines = std.mem.splitScalar(u8, code, '\n');
            var line_buf = std.ArrayList([]const u8).init(self.allocator);
            defer line_buf.deinit();

            // Collect all lines
            while (lines.next()) |line| {
                try line_buf.append(line);
            }

            const total_lines = line_buf.items.len;
            const start_line = if (highlight_line > context_lines) highlight_line - context_lines else 0;
            const end_line = @min(highlight_line + context_lines, @as(u64, @intCast(total_lines)));

            var line_num = start_line;
            while (line_num <= end_line) : (line_num += 1) {
                if (line_num > total_lines) break;
                const line_idx = line_num - 1;
                const line = line_buf.items[line_idx];
                const is_highlight = line_num == highlight_line;

                const after_highlight = line_num > highlight_line;

                try self.tree.beginLine();

                // Line number
                try self.writer.print("\x1b[38;2;80;80;100m{d:>4} \x1b[0m", .{line_num});

                // Border
                if (is_highlight) {
                    try self.writer.writeAll("\x1b[38;2;200;200;100m│\x1b[0m ");
                } else {
                    try self.writer.writeAll("\x1b[38;2;60;60;80m│\x1b[0m ");
                }

                // Code line
                if (is_highlight) {
                    if (highlight_col) |col| {
                        // Print line with underline at specific column
                        if (col > 0 and col <= line.len) {
                            const before = line[0 .. col - 1];
                            const at = if (col <= line.len) line[col - 1 .. @min(col, line.len)] else "";
                            const after = if (col < line.len) line[col..] else "";

                            try self.writer.print("\x1b[38;2;200;200;100m{s}", .{before});
                            try self.writer.print("\x1b[4m{s}\x1b[24m", .{at});
                            try self.writer.print("{s}\x1b[0m\n", .{after});
                        } else {
                            try self.writer.print("\x1b[38;2;200;200;100m{s}\x1b[0m\n", .{line});
                        }
                    } else {
                        try self.writer.print("\x1b[38;2;200;200;100m{s}\x1b[0m\n", .{line});
                    }
                } else {
                    try self.writer.print("\x1b[38;2;150;150;170m{s}\x1b[0m\n", .{line});
                }

                if (std.mem.startsWith(u8, line, "}") and after_highlight) {
                    break;
                }
            }
        }

        // Code snippet with line numbers
        pub fn codeSnippet(self: Self, code: []const u8, start_line: u32, highlight_line: ?u32) !void {
            var lines = std.mem.splitScalar(u8, code, '\n');
            var line_num = start_line;

            while (lines.next()) |line| {
                const is_highlight = if (highlight_line) |hl| line_num == hl else false;

                if (is_highlight) {
                    try self.writer.print("\x1b[1m\x1b[33m{d:>4} │ {s}\x1b[0m\n", .{ line_num, line });
                } else {
                    try self.writer.print("\x1b[90m{d:>4} │\x1b[0m {s}\n", .{ line_num, line });
                }

                line_num += 1;
            }
        }

        // Separator line
        pub fn separator(self: Self, width: usize) !void {
            try self.writer.writeAll("\x1b[90m");
            for (0..width) |_| {
                try self.writer.writeAll("─");
            }
            try self.writer.writeAll("\x1b[0m\n");
        }

        // Timing display
        pub fn timing(self: Self, label: []const u8, duration_ns: u64) !void {
            const ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

            var buf: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{s}: {d:.2}ms", .{ label, ms });
            try self.tree.styledLine(text, .{ .fg = Color.gray });
        }
    };
}
