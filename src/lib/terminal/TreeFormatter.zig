const std = @import("std");

/// Non-allocating tree structure formatter
/// Manages tree indentation and structure without allocation
pub const TreeFormatter = struct {
    pub const MAX_DEPTH = 32;

    depth: u8 = 0,
    stack: [MAX_DEPTH]LevelState = [_]LevelState{.{}} ** MAX_DEPTH,

    pub const LevelState = struct {
        has_more: bool = true,
    };

    pub fn init() TreeFormatter {
        return .{};
    }

    /// Enter a new tree level
    pub fn enter(self: *TreeFormatter) !void {
        if (self.depth >= MAX_DEPTH - 1) {
            return error.TreeDepthExceeded;
        }
        
        // Push current state to stack and increment depth
        self.stack[self.depth] = .{ .has_more = true };
        self.depth += 1;
    }

    /// Exit current tree level
    pub fn exit(self: *TreeFormatter) void {
        if (self.depth > 0) {
            self.depth -= 1;
        }
    }

    /// Mark current level as the last item (no more siblings)
    pub fn setLast(self: *TreeFormatter) void {
        if (self.depth > 0) {
            self.stack[self.depth - 1].has_more = false;
        }
    }

    /// Write tree indentation for a new node
    pub fn writeIndent(self: *const TreeFormatter, writer: anytype, is_last: bool) !void {
        // Draw vertical lines for parent levels
        for (self.stack[0..self.depth], 0..) |level, i| {
            if (i == self.depth - 1) {
                // Current level - draw the branch
                if (is_last) {
                    try writer.writeAll("└─ ");
                } else if (i == 0) {
                    try writer.writeAll("┌─ ");
                } else {
                    try writer.writeAll("├─ ");
                }
            } else {
                // Parent levels - draw vertical lines
                if (level.has_more) {
                    try writer.writeAll("│  ");
                } else {
                    try writer.writeAll("   ");
                }
            }
        }
    }

    /// Write tree continuation for content within a node
    pub fn writeContinuation(self: *const TreeFormatter, writer: anytype) !void {
        // Draw vertical lines for continuation
        for (self.stack[0..self.depth]) |level| {
            if (level.has_more) {
                try writer.writeAll("│  ");
            } else {
                try writer.writeAll("   ");
            }
        }
    }

    /// Write a node with proper indentation
    pub fn writeNode(self: *TreeFormatter, writer: anytype, text: []const u8, is_last: bool) !void {
        if (self.depth > 0) {
            try self.writeIndent(writer, is_last);
        }
        try writer.writeAll(text);
        try writer.writeAll("\n");
        if (is_last) {
            self.setLast();
        }
    }

    /// Write content within a node (continuation lines)
    pub fn writeLine(self: *const TreeFormatter, writer: anytype, text: []const u8) !void {
        if (self.depth > 0) {
            try self.writeContinuation(writer);
        }
        try writer.writeAll(text);
        try writer.writeAll("\n");
    }

    /// Get current depth for debugging
    pub fn getCurrentDepth(self: *const TreeFormatter) u8 {
        return self.depth;
    }

    /// Reset formatter to initial state
    pub fn reset(self: *TreeFormatter) void {
        self.depth = 0;
        self.stack = [_]LevelState{.{}} ** MAX_DEPTH;
    }
};

// === Tests ===

test "TreeFormatter basic tree structure" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    
    var tree = TreeFormatter.init();

    // Root level
    try tree.writeNode(buffer.writer(), "Root", false);
    
    // First child
    try tree.enter();
    try tree.writeNode(buffer.writer(), "Child 1", false);
    
    // Grandchild
    try tree.enter();
    try tree.writeNode(buffer.writer(), "Grandchild 1", true);
    tree.exit();
    
    // Second child (last)
    try tree.writeNode(buffer.writer(), "Child 2", true);
    tree.exit();

    const expected = 
        \\Root
        \\┌─ Child 1
        \\│  └─ Grandchild 1
        \\└─ Child 2
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "TreeFormatter continuation lines" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    
    var tree = TreeFormatter.init();

    try tree.enter();
    try tree.writeNode(buffer.writer(), "Node", false);
    try tree.writeLine(buffer.writer(), "Line 1");
    try tree.writeLine(buffer.writer(), "Line 2");
    tree.exit();

    const expected = 
        \\┌─ Node
        \\│  Line 1
        \\│  Line 2
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "TreeFormatter depth tracking" {
    var tree = TreeFormatter.init();

    try std.testing.expectEqual(@as(u8, 0), tree.getCurrentDepth());

    try tree.enter();
    try std.testing.expectEqual(@as(u8, 1), tree.getCurrentDepth());

    try tree.enter();
    try std.testing.expectEqual(@as(u8, 2), tree.getCurrentDepth());

    tree.exit();
    try std.testing.expectEqual(@as(u8, 1), tree.getCurrentDepth());

    tree.exit();
    try std.testing.expectEqual(@as(u8, 0), tree.getCurrentDepth());
}

test "TreeFormatter max depth protection" {
    var tree = TreeFormatter.init();

    // Fill up to max depth
    var i: u8 = 0;
    while (i < TreeFormatter.MAX_DEPTH - 1) : (i += 1) {
        try tree.enter();
    }

    // This should fail
    const result = tree.enter();
    try std.testing.expectError(error.TreeDepthExceeded, result);
}

test "TreeFormatter reset" {
    var tree = TreeFormatter.init();
    
    try tree.enter();
    try tree.enter();
    try std.testing.expectEqual(@as(u8, 2), tree.getCurrentDepth());
    
    tree.reset();
    try std.testing.expectEqual(@as(u8, 0), tree.getCurrentDepth());
}