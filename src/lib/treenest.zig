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

        fn applyStyle(self: *Self, style: Style) !void {
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

        fn resetStyle(self: *Self) !void {
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
                        try self.writer.writeAll("│  ");
                    } else {
                        try self.writer.writeAll("   ");
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
                    try self.writer.writeAll("│  ");
                } else {
                    try self.writer.writeAll("   ");
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

        pub fn newline(self: *Self) !void {
            try self.writer.writeAll("\n");
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            try self.writer.print(fmt, args);
        }
    };
}

pub fn treeNest(allocator: std.mem.Allocator, writer: anytype) TreeNest(@TypeOf(writer)) {
    return TreeNest(@TypeOf(writer)).init(allocator, writer);
}
