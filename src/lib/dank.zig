const std = @import("std");
const treenest = @import("treenest.zig");

const Color = treenest.Color;
const Style = treenest.Style;
pub const Part = treenest.Part;
pub const plain = treenest.plain;
pub const bold = treenest.bold;
pub const dim = treenest.dim;
pub const italic = treenest.italic;
pub const underline = treenest.underline;
pub const colored = treenest.colored;
pub const onColor = treenest.onColor;
pub const black = treenest.black;
pub const white = treenest.white;
pub const red = treenest.red;
pub const green = treenest.green;
pub const blue = treenest.blue;
pub const yellow = treenest.yellow;
pub const cyan = treenest.cyan;
pub const magenta = treenest.magenta;
pub const gray = treenest.gray;
pub const dimGray = treenest.dimGray;

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

        /// Fluent styled line composition, forwarded to the underlying tree
        pub fn compose(self: Self, parts: []const Part) treenest.TreeNest(Writer).LineComposer {
            return self.tree.compose(parts);
        }

        /// Convenience: compose parts separated by spaces and emit a newline
        pub fn lineParts(self: Self, parts: []const Part) !void {
            try self.tree.compose(parts).spaced();
        }

        pub fn barely(self: Self, part: Part) !void {
            try self.tree.compose(&.{part}).inlineSpaced();
        }

        pub fn integerPart(self: Self, value: anytype) Part {
            return self.formattedPart("{d}", .{value});
        }

        pub fn formattedPart(self: Self, comptime format: []const u8, args: anytype) Part {
            return .{ .text = std.fmt.allocPrint(self.allocator, format, args) catch unreachable, .style = .{} };
        }

        pub fn spaces(self: Self, count: usize) !void {
            for (0..count) |_| try self.tree.raw(" ");
        }

        inline fn iconPart(icon: Icon) Part {
            return .{ .text = icon.str(), .style = icon.style() };
        }

        // Test result formatting
        pub fn testPass(self: Self, name: []const u8, duration_ms: ?f64) !void {
            _ = duration_ms; // autofix
            try self.lineParts(&.{
                iconPart(.check),
                dim(name),
            });
        }

        pub fn testFail(self: Self, name: []const u8, err: []const u8, duration_ms: ?f64) !void {
            _ = duration_ms; // autofix
            try self.lineParts(&.{
                iconPart(.cross),
                colored(name, .rgb(200, 100, 100)),
                red(err),
            });
        }

        pub fn testSkip(self: Self, name: []const u8) !void {
            try self.lineParts(&.{ iconPart(.skip), colored(name, .rgb(100, 100, 200)), dim("[skipped]") });
        }

        pub fn testPending(self: Self, name: []const u8) !void {
            try self.lineParts(&.{ iconPart(.skip), colored(name, .rgb(100, 100, 200)), dim("[pending]") });
        }

        pub fn testCompact(self: Self, passed: bool) !void {
            if (passed) {
                try self.barely(colored(".", .rgb(100, 200, 100)));
            } else {
                try self.barely(colored("X", .rgb(200, 100, 100)));
            }
        }

        // Progress bar
        pub fn progressBar(self: Self, current: usize, total: usize, width: usize) !void {
            const filled = (current * width) / total;
            const empty = width - filled;

            try self.writer.writeAll("[");
            for (0..filled) |_| try self.tree.styled("█", .{ .fg = Color.green });
            for (0..empty) |_| try self.tree.styled("░", .{ .fg = Color.gray });
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
            try self.tree.begin();
            try self.tree.styledNode(title, .{}, false);
        }

        pub fn rootSection(self: Self, title: []const u8) !void {
            try self.tree.begin();
            try self.tree.styledNode(title, .{ .bold = true }, false);
        }

        // Status messages
        pub fn success(self: Self, msg: []const u8) !void {
            try self.lineParts(&.{
                iconPart(.check),
                treenest.colored(msg, Color.green),
            });
        }

        pub fn errorMsg(self: Self, msg: []const u8) !void {
            try self.lineParts(&.{
                iconPart(.cross),
                .{ .text = msg, .style = .{ .fg = Color.red, .bold = true } },
            });
        }

        pub fn warning(self: Self, msg: []const u8) !void {
            try self.lineParts(&.{
                iconPart(.warning),
                treenest.colored(msg, Color.yellow),
            });
        }

        pub fn info(self: Self, msg: []const u8) !void {
            try self.lineParts(&.{
                iconPart(.info),
                treenest.colored(msg, Color.cyan),
            });
        }

        // Table formatting
        pub fn table(
            self: Self,
            headers: []const []const u8,
            rows: []const []const []const u8,
            col_widths: ?[]const usize,
        ) !void {
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

            // Print headers (bold)
            var header_parts = std.ArrayList(Part).init(self.allocator);
            defer header_parts.deinit();
            for (headers, 0..) |header, i| {
                if (i > 0) try header_parts.append(plain("  "));
                const h = treenest.fixed(self.allocator, header, widths[i]);
                try header_parts.append(.{ .text = h.text, .style = .{ .bold = true } });
            }
            try self.tree.compose(header_parts.items).joined("");

            // Print separator (gray)
            var sep_parts = std.ArrayList(Part).init(self.allocator);
            defer sep_parts.deinit();
            for (widths, 0..) |width, i| {
                if (i > 0) try sep_parts.append(plain("  "));
                var line_buf = std.ArrayList(u8).init(self.allocator);
                defer line_buf.deinit();
                for (0..width) |_| {
                    try line_buf.appendSlice("─");
                }
                try sep_parts.append(gray(try line_buf.toOwnedSlice()));
            }
            try self.tree.compose(sep_parts.items).joined("");

            // Print rows
            for (rows) |row| {
                var row_parts = std.ArrayList(Part).init(self.allocator);
                defer row_parts.deinit();
                for (row, 0..) |cell, i| {
                    if (i > 0) try row_parts.append(plain("  "));
                    try row_parts.append(treenest.fixed(self.allocator, cell, widths[i]));
                }
                try self.tree.compose(row_parts.items).joined("");
            }
        }

        // Stack trace formatting
        pub fn stackFrame(self: Self, file: []const u8, line: u64, col: u64, func: []const u8) !void {
            const base = std.fs.path.basename(file);
            const dir = std.fs.path.dirname(file) orelse ".";

            try self.compose(&.{
                dim(dir),
                dim("/"),
                bold(base),
                dim(":"),
                self.integerPart(line),
                dim(":"),
                self.integerPart(col),
                dim(" "),
                underline(func),
            }).joined("");
        }

        // Source block with box drawing borders
        pub fn sourceBlock(self: Self, code: []const u8, highlight_line: ?u64, highlight_col: ?u64, context_lines: u32) !void {
            var lines = std.mem.splitScalar(u8, code, '\n');
            var line_buf = std.ArrayList([]const u8).init(self.allocator);
            defer line_buf.deinit();
            var longest_line: usize = 0;

            // Collect all lines
            while (lines.next()) |line| {
                try line_buf.append(line);
            }

            const total_lines = line_buf.items.len;
            var start_line = if (highlight_line) |hl| if (hl > context_lines) hl - context_lines - 1 else 0 else 0;
            var end_line = if (highlight_line) |hl| @min(hl + context_lines - 1, @as(u64, @intCast(total_lines))) else total_lines - 1;

            // shift start and end back one step if possible
            if (start_line > 0 and context_lines > 0) {
                start_line -= 1;
                end_line -= 1;
            }

            for (line_buf.items[start_line..@min(end_line + 1, total_lines)]) |line| {
                if (line.len > longest_line) longest_line = line.len;
            }

            try self.tree.resetStyle();
            try self.tree.beginLine();
            //            try self.spaces(5);
            //            try self.topBorderSeparator(longest_line + 2);

            var line_num = start_line;
            while (line_num <= end_line) : (line_num += 1) {
                if (line_num > total_lines) break;

                const line_idx = line_num;
                const line = line_buf.items[line_idx];
                const is_highlight = highlight_line != null and line_num + 1 == highlight_line.?;

                const after_highlight = highlight_line != null and line_num + 1 > highlight_line.?;

                try self.tree.beginLine();
                try self.tree.dk().spaces(2);

                const highlight_color = Color.rgb(228, 171, 101);

                // Line number
                const num_part = treenest.formattedStyled(
                    self.allocator,
                    "{d:>4} ",
                    .{line_num},
                    .{ .fg = if (is_highlight) highlight_color else Color.rgb(80, 80, 100) },
                );
                try self.tree.applyStyle(num_part.style);
                try self.tree.raw(num_part.text);
                try self.tree.resetStyle();

                // Border
                if (is_highlight) {
                    try self.tree.styled("│ ", .{ .fg = highlight_color });
                } else {
                    try self.tree.styled("│ ", .{ .fg = Color.rgb(60, 60, 80) });
                }

                if (line.len != 0) {
                    // Code line
                    if (is_highlight) {
                        if (highlight_col) |col1| {
                            var col2 = @min(col1, line.len - 1);
                            // find end of current word/token
                            while (col2 < line.len) : (col2 += 1) {
                                if (std.mem.indexOfScalar(u8, " .,()}]", line[col2]) != null) {
                                    col2 = @min(col2 + 1, line.len - 1);
                                    break;
                                }
                            }

                            // Print line with underline at specific column
                            if (col1 > 0 and col1 - 1 <= line.len) {
                                const before = line[0 .. col1 - 1];
                                const at = line[col1 - 1 .. col2];
                                const after = line[col2..];

                                try self.compose(&.{
                                    colored(before, .rgb(161, 163, 117)),
                                    colored(at, highlight_color),
                                    colored(after, .rgb(161, 163, 117)),
                                }).inlineJoined("");
                            } else {
                                try self.tree.styled(line, .{ .fg = Color.rgb(200, 200, 100) });
                            }
                        } else {
                            try self.tree.styled(line, .{ .fg = Color.rgb(200, 200, 100) });
                        }
                    } else {
                        try self.tree.styled(line, .{ .fg = Color.rgb(119, 119, 142) });
                    }
                }

                // if (line.len < longest_line) {
                //     try self.spaces(longest_line - line.len);
                // }

                // // Border
                // if (is_highlight) {
                //     try self.tree.styled(" │", .{ .fg = highlight_color });
                // } else {
                //     try self.tree.styled(" │", .{ .fg = Color.rgb(60, 60, 80) });
                // }

                try self.tree.newline();

                if (std.mem.startsWith(u8, line, "}") and after_highlight) {
                    break;
                }
            }

            try self.tree.resetStyle();
            //            try self.tree.beginLine();
            //            try self.spaces(5);
            //            try self.bottomBorderSeparator(longest_line + 2);
        }

        // Code snippet with line numbers
        pub fn codeSnippet(self: Self, code: []const u8) !void {
            var lines = std.mem.splitScalar(u8, code, '\n');
            var i: usize = 1;

            while (lines.next()) |line| {
                try self.tree.beginLine();
                const num_part = treenest.formattedStyled(self.allocator, "{d:>4} │", .{i}, .{ .fg = Color.rgb(60, 60, 80) });
                try self.tree.applyStyle(num_part.style);
                try self.tree.raw(num_part.text);
                try self.tree.resetStyle();
                try self.tree.raw(" ");
                try self.tree.raw(line);
                try self.tree.newline();

                i += 1;
            }
        }

        // Separator line
        pub fn separator(self: Self, width: usize) !void {
            for (0..width) |_| try self.tree.styled("─", .{ .fg = Color.gray });
            try self.tree.newline();
        }

        pub fn topBorderSeparator(self: Self, width: usize) !void {
            try self.compose(&.{
                colored("┌", .rgb(60, 60, 80)),
                colored("─", .rgb(60, 60, 80)).repeat(width),
                colored("┐", .rgb(60, 60, 80)),
            }).joined("");
        }

        pub fn bottomBorderSeparator(self: Self, width: usize) !void {
            try self.compose(&.{
                colored("└", .rgb(60, 60, 80)),
                colored("─", .rgb(60, 60, 80)).repeat(width),
                colored("┘", .rgb(60, 60, 80)),
            }).joined("");
        }

        // Timing display
        pub fn timing(self: Self, label: []const u8, duration_ns: u64) !void {
            const ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
            try self.compose(&.{
                plain(label),
                plain(": "),
                treenest.formattedStyled(self.allocator, "{d:.2}ms", .{ms}, .{ .fg = Color.gray }),
            }).joined("");
        }
    };
}
