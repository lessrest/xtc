const std = @import("std");
const dank = @import("dank.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const red = Color{ .r = 255, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 200, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 255 };
    pub const yellow = Color{ .r = 200, .g = 200, .b = 0 };
    pub const cyan = Color{ .r = 0, .g = 200, .b = 200 };
    pub const magenta = Color{ .r = 200, .g = 0, .b = 200 };
    pub const gray = Color{ .r = 150, .g = 150, .b = 150 };
    pub const dimGray = Color{ .r = 100, .g = 100, .b = 100 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return Color{ .r = r, .g = g, .b = b };
    }
};

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
};

/// A piece of text with an associated `Style`.
pub const Part = struct {
    text: []const u8,
    style: Style = .{},
    count: usize = 1,

    pub fn repeat(self: Part, count: usize) Part {
        return .{ .text = self.text, .style = self.style, .count = count };
    }

    pub fn underlined(self: Part) Part {
        var part = self;
        part.style.underline = true;
        return part;
    }
};

/// Convenience constructors for common styled parts
pub fn plain(text: []const u8) Part {
    return .{ .text = text };
}

pub fn bold(text: []const u8) Part {
    return .{ .text = text, .style = .{ .bold = true } };
}

pub fn dim(text: []const u8) Part {
    return .{ .text = text, .style = .{ .dim = true } };
}

pub fn italic(text: []const u8) Part {
    return .{ .text = text, .style = .{ .italic = true } };
}

pub fn underline(text: []const u8) Part {
    return .{ .text = text, .style = .{ .underline = true } };
}

pub fn colored(text: []const u8, color: Color) Part {
    return .{ .text = text, .style = .{ .fg = color } };
}

pub fn onColor(text: []const u8, color: Color) Part {
    return .{ .text = text, .style = .{ .bg = color } };
}

pub fn black(text: []const u8) Part {
    return colored(text, Color.black);
}
pub fn white(text: []const u8) Part {
    return colored(text, Color.white);
}
pub fn red(text: []const u8) Part {
    return colored(text, Color.red);
}
pub fn green(text: []const u8) Part {
    return colored(text, Color.green);
}
pub fn blue(text: []const u8) Part {
    return colored(text, Color.blue);
}
pub fn yellow(text: []const u8) Part {
    return colored(text, Color.yellow);
}
pub fn cyan(text: []const u8) Part {
    return colored(text, Color.cyan);
}
pub fn magenta(text: []const u8) Part {
    return colored(text, Color.magenta);
}
pub fn gray(text: []const u8) Part {
    return colored(text, Color.gray);
}
pub fn dimGray(text: []const u8) Part {
    return colored(text, Color.dimGray);
}

pub fn formatted(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Part {
    const text = std.fmt.allocPrint(allocator, fmt, args) catch return plain("");
    return plain(text);
}

pub fn formattedStyled(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype, style: Style) Part {
    const text = std.fmt.allocPrint(allocator, fmt, args) catch return plain("");
    return .{ .text = text, .style = style };
}

pub fn padLeft(allocator: std.mem.Allocator, text: []const u8, width: usize, pad_char: u8) Part {
    if (text.len >= width) return plain(text);
    const padding_len = width - text.len;
    const padded = allocator.alloc(u8, width) catch return plain(text);
    @memset(padded[0..padding_len], pad_char);
    @memcpy(padded[padding_len..], text);
    return plain(padded);
}

pub fn padRight(allocator: std.mem.Allocator, text: []const u8, width: usize, pad_char: u8) Part {
    if (text.len >= width) return plain(text);
    const padded = allocator.alloc(u8, width) catch return plain(text);
    @memcpy(padded[0..text.len], text);
    @memset(padded[text.len..], pad_char);
    return plain(padded);
}

pub fn fixed(allocator: std.mem.Allocator, text: []const u8, width: usize) Part {
    if (text.len == width) return plain(text);
    if (text.len > width) {
        return plain(text[0..width]);
    }
    return padRight(allocator, text, width, ' ');
}

pub fn TreeNest(comptime Writer: type) type {
    return struct {
        writer: Writer,
        depth: usize = 0,
        stack: std.ArrayList(Level),
        allocator: std.mem.Allocator,
        no_color: bool = false,

        const Self = @This();

        const Level = struct {
            has_more: bool,
        };

        pub fn init(allocator: std.mem.Allocator, writer: Writer) Self {
            return .{
                .writer = writer,
                .allocator = allocator,
                .stack = std.ArrayList(Level).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit();
        }

        pub fn dk(self: *Self) dank.Dank(Writer) {
            return dank.Dank(Writer).withTree(self.allocator, self);
        }

        pub fn setNoColor(self: *Self, no_color: bool) void {
            self.no_color = no_color;
        }

        pub fn applyStyle(self: *Self, style: Style) !void {
            if (self.no_color) return;

            if (style.bold) {
                try self.writer.writeAll("\x1b[1m");
            }
            if (style.dim) {
                try self.writer.writeAll("\x1b[2m");
            }
            if (style.italic) {
                try self.writer.writeAll("\x1b[3m");
            }
            if (style.underline) {
                try self.writer.writeAll("\x1b[4m");
            }
            if (style.fg) |fg| {
                try self.writer.print("\x1b[38;2;{d};{d};{d}m", .{ fg.r, fg.g, fg.b });
            }
            if (style.bg) |bg| {
                try self.writer.print("\x1b[48;2;{d};{d};{d}m", .{ bg.r, bg.g, bg.b });
            }
        }

        pub fn resetStyle(self: *Self) !void {
            if (!self.no_color) {
                try self.writer.writeAll("\x1b[0m");
            }
        }

        fn writeIndent(self: *Self, is_last: bool) !void {
            // Draw vertical lines for parent levels
            for (self.stack.items[0..self.stack.items.len], 0..) |level, i| {
                if (i == self.stack.items.len - 1) {
                    // Current level - draw the branch
                    if (!self.no_color) {
                        try self.writer.writeAll("\x1b[38;2;100;100;100m");
                    }
                    if (is_last) {
                        try self.writer.writeAll("└─ ");
                    } else if (i == 0) {
                        try self.writer.writeAll("┌─ ");
                    } else {
                        try self.writer.writeAll("├─ ");
                    }
                    if (!self.no_color) {
                        try self.writer.writeAll("\x1b[0m");
                    }
                } else {
                    // Parent levels - draw vertical lines
                    if (!self.no_color) {
                        try self.writer.writeAll("\x1b[38;2;100;100;100m");
                    }
                    if (level.has_more) {
                        try self.writer.writeAll("│ ");
                    } else {
                        try self.writer.writeAll("  ");
                    }
                    if (!self.no_color) {
                        try self.writer.writeAll("\x1b[0m");
                    }
                }
            }
        }

        fn writeContinuation(self: *Self) !void {
            // Draw vertical lines for continuation
            for (self.stack.items) |level| {
                if (!self.no_color) {
                    try self.writer.writeAll("\x1b[38;2;100;100;100m");
                }
                if (level.has_more) {
                    try self.writer.writeAll("│ ");
                } else {
                    try self.writer.writeAll("  ");
                }
                if (!self.no_color) {
                    try self.writer.writeAll("\x1b[0m");
                }
            }
        }

        pub fn begin(self: *Self) !void {
            try self.stack.append(.{ .has_more = true });
            self.depth += 1;
        }

        pub fn end(self: *Self) void {
            if (self.stack.items.len > 0) {
                _ = self.stack.pop();
                self.depth -= 1;
            }
        }

        pub fn setLast(self: *Self) void {
            if (self.stack.items.len > 0) {
                self.stack.items[self.stack.items.len - 1].has_more = false;
            }
        }

        pub fn node(self: *Self, text: []const u8, is_last: bool) !void {
            if (self.depth > 0) {
                try self.writeIndent(is_last);
            }
            try self.writer.writeAll(text);
            try self.writer.writeAll("\n");
            if (is_last) {
                self.setLast();
            }
        }

        pub fn styledNode(self: *Self, text: []const u8, style: Style, is_last: bool) !void {
            if (self.depth > 0) {
                try self.writeIndent(is_last);
            }
            try self.applyStyle(style);
            try self.writer.writeAll(text);
            try self.resetStyle();
            try self.writer.writeAll("\n");
            if (is_last) {
                self.setLast();
            }
        }

        pub fn line(self: *Self, text: []const u8) !void {
            if (self.depth > 0) {
                try self.writeContinuation();
            }
            try self.writer.writeAll(text);
            try self.writer.writeAll("\n");
        }

        pub fn beginLine(self: *Self) !void {
            if (self.depth > 0) {
                try self.writeContinuation();
            }
        }

        pub fn styledLine(self: *Self, text: []const u8, style: Style) !void {
            if (self.depth > 0) {
                try self.writeContinuation();
            }
            try self.applyStyle(style);
            try self.writer.writeAll(text);
            try self.resetStyle();
            try self.writer.writeAll("\n");
        }

        pub fn raw(self: *Self, text: []const u8) !void {
            try self.writer.writeAll(text);
        }

        pub fn styled(self: *Self, text: []const u8, style: Style) !void {
            try self.applyStyle(style);
            try self.writer.writeAll(text);
            try self.resetStyle();
        }

        /// Print a formatted string with the given style applied.
        pub fn styledPrint(self: *Self, comptime fmt: []const u8, args: anytype, style: Style) !void {
            try self.applyStyle(style);
            try self.writer.print(fmt, args);
            try self.resetStyle();
        }

        pub fn newline(self: *Self) !void {
            try self.writer.writeAll("\n");
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            try self.writer.print(fmt, args);
        }

        /// Begin composing a line from `Part`s using a fluent API.
        /// Example:
        ///   try tree.compose(&.{ bold(name), dim(status), green("online") }).spaced();
        pub fn compose(self: *Self, parts: []const Part) LineComposer {
            return .{ .tree = self, .parts = parts };
        }

        pub const LineComposer = struct {
            tree: *Self,
            parts: []const Part,

            /// Join parts with a custom separator and emit a newline.
            pub fn joined(self: *const @This(), separator: []const u8) !void {
                if (self.tree.depth > 0) {
                    try self.tree.writeContinuation();
                }
                for (self.parts, 0..) |p, i| {
                    if (i > 0) try self.tree.writer.writeAll(separator);
                    try self.tree.applyStyle(p.style);
                    for (0..p.count) |_| try self.tree.writer.writeAll(p.text);
                    try self.tree.resetStyle();
                }
                try self.tree.writer.writeAll("\n");
            }

            /// Join parts with a single space and emit a newline.
            pub fn spaced(self: *const @This()) !void {
                try self.joined(" ");
            }

            /// Join parts with a custom separator without a trailing newline.
            pub fn inlineJoined(self: *const @This(), separator: []const u8) !void {
                if (self.tree.depth > 0) {
                    try self.tree.writeContinuation();
                }
                for (self.parts, 0..) |p, i| {
                    if (i > 0) try self.tree.writer.writeAll(separator);
                    try self.tree.applyStyle(p.style);
                    for (0..p.count) |_| try self.tree.writer.writeAll(p.text);
                    try self.tree.resetStyle();
                }
            }

            /// Join parts with a single space without a trailing newline.
            pub fn inlineSpaced(self: *const @This()) !void {
                try self.inlineJoined(" ");
            }
        };
    };
}

pub fn treeNest(allocator: std.mem.Allocator, writer: anytype) TreeNest(@TypeOf(writer)) {
    return TreeNest(@TypeOf(writer)).init(allocator, writer);
}

pub fn testNest(allocator: std.mem.Allocator) TreeNest(std.fs.File.Writer) {
    return treeNest(allocator, std.io.getStdOut().writer());
}
