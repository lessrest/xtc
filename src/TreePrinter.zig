const std = @import("std");
const ansi = @import("ansi.zig");

pub const TreePrinter = struct {
    allocator: std.mem.Allocator,
    ansi: ansi.ArrayListAnsiWriter,
    indent_level: u32 = 0,
    level_has_more: std.ArrayList(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .ansi = undefined,
            .indent_level = 0,
            .level_has_more = std.ArrayList(bool).init(allocator),
        };
    }

    pub fn setWriter(self: *Self, writer: ansi.ArrayListAnsiWriter) void {
        self.ansi = writer;
    }

    pub fn deinit(self: *Self) void {
        self.level_has_more.deinit();
    }

    pub fn writePrefix(self: *Self, is_last: bool) !void {
        var ansi_w = self.ansi;

        // Draw vertical bars for parent levels
        if (self.level_has_more.items.len > 0) {
            for (self.level_has_more.items[0 .. self.level_has_more.items.len - 1]) |has_more| {
                if (has_more) {
                    try ansi_w.setForegroundRgb(100, 100, 100); // Dim gray
                    try ansi_w.writeAll("│  ");
                } else {
                    try ansi_w.writeAll("   ");
                }
                try ansi_w.resetStyle();
            }
        }

        // Draw the connector for the current level
        if (self.indent_level > 0) {
            try ansi_w.setForegroundRgb(100, 100, 100); // Dim gray
            if (is_last) {
                try ansi_w.writeAll("└─ ");
            } else {
                try ansi_w.writeAll("├─ ");
            }
            try ansi_w.resetStyle();
        }
    }

    pub fn writeVerticals(self: *Self) !void {
        var ansi_w = self.ansi;

        // Draw vertical bars for parent levels
        if (self.level_has_more.items.len > 0) {
            for (self.level_has_more.items[0 .. self.level_has_more.items.len - 1]) |has_more| {
                if (has_more) {
                    try ansi_w.setForegroundRgb(100, 100, 100); // Dim gray
                    try ansi_w.writeAll("│  ");
                } else {
                    try ansi_w.writeAll("   ");
                }
                try ansi_w.resetStyle();
            }
        }

        // For continuation lines, show vertical bar but no horizontal connector
        if (self.indent_level > 0) {
            const current_level_has_more = if (self.level_has_more.items.len > 0)
                self.level_has_more.items[self.level_has_more.items.len - 1]
            else
                false;
            if (current_level_has_more) {
                try ansi_w.setForegroundRgb(100, 100, 100); // Dim gray
                try ansi_w.writeAll("│  ");
            } else {
                try ansi_w.writeAll("   ");
            }
            try ansi_w.resetStyle();
        }
    }

    pub fn enter(self: *Self) !void {
        self.indent_level += 1;
        try self.level_has_more.append(true);
    }

    pub fn exit(self: *Self) void {
        self.indent_level -= 1;
        _ = self.level_has_more.pop();
    }

    pub fn setHasMore(self: *Self, has_more: bool) void {
        if (self.level_has_more.items.len > 0) {
            self.level_has_more.items[self.level_has_more.items.len - 1] = has_more;
        }
    }

    pub fn indentColumns(self: *Self) usize {
        return @as(usize, self.indent_level) * 3;
    }

    pub fn writeWrappedText(self: *Self, text: []const u8, max_width: usize) !void {
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len <= max_width) {
            try self.ansi.writeAll(trimmed);
            return;
        }

        var start: usize = 0;
        var line_len: usize = 0;
        var first_line = true;

        while (start < trimmed.len) {
            var end = start;
            var last_break = start;
            line_len = 0;

            // Find a good place to break the line
            while (end < trimmed.len and line_len < max_width) {
                const c = trimmed[end];
                if (c == ' ' or c == ',' or c == '(' or c == ')' or c == ':') {
                    last_break = end;
                }
                end += 1;
                line_len += 1;
            }

            // If we found a break point, use it; otherwise break at max_width
            if (line_len >= max_width and last_break > start) {
                end = last_break;
                if (trimmed[end] == ' ') end += 1; // Skip the space
            }

            if (!first_line) {
                try self.ansi.writeAll("\n");
                try self.writeVerticals();
                try self.ansi.writeAll("  "); // Extra indentation for continuation
            }

            try self.ansi.writeAll(trimmed[start..end]);
            start = end;
            first_line = false;
        }
    }
};
