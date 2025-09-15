const std = @import("std");
const StyleRow = @import("style.zig").StyleRow;
const StyleTable = @import("style.zig").StyleTable;
const parseUtilityClassList = @import("tailwind.zig").parseUtilityClassList;
const defaultStyleRow = @import("style.zig").defaultStyleRow;
const Rect = @import("layout.zig").Rect;

pub const DomNodeId = u32;
pub const DomNodeKind = enum { element, text };

pub const DomNodeHeader = struct {
    parent: DomNodeId,
    prev_sibling: DomNodeId,
    next_sibling: DomNodeId,
    content: union(DomNodeKind) {
        element: struct {
            first_child: DomNodeId,
            child_count: u32,
        },
        text: struct {
            text_off: u32,
            text_len: u32,
        },
    },
    style_id: u32,
};

pub const Dom = struct {
    pub const NullId: DomNodeId = std.math.maxInt(DomNodeId);

    alloc: std.mem.Allocator,
    headers: std.MultiArrayList(DomNodeHeader) = .{},
    styles: StyleTable,
    text_arena: std.ArrayList(u8),
    debug_ids: std.AutoHashMap(DomNodeId, []const u8),
    dirty: bool = false,

    pub fn init(alloc: std.mem.Allocator) !*Dom {
        var dom = try alloc.create(Dom);
        errdefer alloc.destroy(dom);

        dom.* = .{
            .alloc = alloc,
            .headers = .{},
            .styles = StyleTable.init(alloc),
            .text_arena = std.ArrayList(u8){},
            .debug_ids = std.AutoHashMap(DomNodeId, []const u8).init(alloc),
            .dirty = false,
        };

        // Create the implicit document root node at index 0
        // This node should always exist and serves as the container for all content
        const root_idx = dom.headers.addOne(alloc) catch unreachable;
        std.debug.assert(root_idx == 0); // Document root must be at index 0
        dom.headers.set(0, .{
            .parent = NullId,
            .prev_sibling = NullId,
            .next_sibling = NullId,
            .content = .{ .element = .{ .first_child = NullId, .child_count = 0 } },
            .style_id = 0, // No style for document root
        });

        return dom;
    }

    pub fn deinit(self: *Dom) void {
        self.headers.deinit(self.alloc);
        self.styles.deinit();
        self.text_arena.deinit(self.alloc);
        var it = self.debug_ids.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.value_ptr.*);
        }
        self.debug_ids.deinit();
        self.alloc.destroy(self);
    }

    pub fn addElement(self: *Dom, style_bytes: []const u8) !DomNodeId {
        // Parse utility-class list (Tailwind-like) into a StyleRow
        const style_row = parseUtilityClassList(style_bytes);
        const style_id = try self.styles.intern(self.alloc, style_row);
        const idx = try self.headers.addOne(self.alloc);
        self.headers.set(idx, .{
            .parent = NullId,
            .prev_sibling = NullId,
            .next_sibling = NullId,
            .content = .{ .element = .{ .first_child = NullId, .child_count = 0 } },
            .style_id = style_id,
        });
        return @as(DomNodeId, @intCast(idx));
    }

    /// Set a node's style by interning the provided `StyleRow` and storing its id.
    pub fn setStyle(self: *Dom, id: DomNodeId, row: StyleRow) !void {
        const sid = try self.styles.intern(self.alloc, row);
        const items = self.headers.slice();
        items.items(.style_id)[@as(usize, @intCast(id))] = sid;
        self.dirty = true;
    }

    pub fn addText(self: *Dom, utf8: []const u8) !DomNodeId {
        const style_id = try self.styles.intern(self.alloc, defaultStyleRow());
        const off: u32 = @intCast(self.text_arena.items.len);
        try self.text_arena.appendSlice(self.alloc, utf8);
        const len: u32 = @intCast(utf8.len);
        const idx = try self.headers.addOne(self.alloc);
        self.headers.set(idx, .{
            .parent = NullId,
            .prev_sibling = NullId,
            .next_sibling = NullId,
            .content = .{ .text = .{ .text_off = off, .text_len = len } },
            .style_id = style_id,
        });
        self.dirty = true;
        return @as(DomNodeId, @intCast(idx));
    }

    pub fn getTextSlice(self: *const Dom, id: DomNodeId) []const u8 {
        const items = self.headers.slice();
        const idx: usize = @intCast(id);
        const content = items.items(.content)[idx];
        return switch (content) {
            .text => |t| self.text_arena.items[@intCast(t.text_off)..@intCast(t.text_off + t.text_len)],
            else => &[_]u8{},
        };
    }

    pub fn updateText(self: *Dom, id: DomNodeId, new_text: []const u8) !void {
        const idx: usize = @intCast(id);
        var items = self.headers.slice();

        // Only works on text nodes
        switch (items.items(.content)[idx]) {
            .text => {},
            else => return,
        }

        // Append new text to arena
        const off = self.text_arena.items.len;
        try self.text_arena.appendSlice(self.alloc, new_text);
        const len = new_text.len;

        // Update the text node's offset and length
        items.items(.content)[idx] = .{ .text = .{ .text_off = @intCast(off), .text_len = @intCast(len) } };
        self.dirty = true;
    }

    pub fn updateClass(self: *Dom, id: DomNodeId, new_class: []const u8) !void {
        const idx: usize = @intCast(id);
        var items = self.headers.slice();

        // Only works on element nodes
        switch (items.items(.content)[idx]) {
            .element => {},
            else => return,
        }

        // Parse utility-class list and intern the new style
        const style_row = parseUtilityClassList(new_class);
        const new_style_id = try self.styles.intern(self.alloc, style_row);
        items.items(.style_id)[idx] = new_style_id;
        self.dirty = true;
    }

    pub fn appendChild(self: *Dom, parent_id: DomNodeId, child_id: DomNodeId) !void {
        const p: usize = @intCast(parent_id);
        const c: usize = @intCast(child_id);
        var items = self.headers.slice();
        // Only element nodes can have children
        switch (items.items(.content)[p]) {
            .element => {},
            else => return error.InvalidNodeKind,
        }
        // Access parent's children payload
        const content_ptr = &items.items(.content)[p];
        var p_first: *DomNodeId = undefined;
        var p_count: *u32 = undefined;
        switch (content_ptr.*) {
            .element => |*ch| {
                p_first = &ch.first_child;
                p_count = &ch.child_count;
            },
            else => return error.InvalidNodeKind,
        }
        items.items(.parent)[c] = parent_id;
        if (p_first.* == NullId) {
            p_first.* = child_id;
        } else {
            // find last sibling
            var last_id = p_first.*;
            while (items.items(.next_sibling)[@as(usize, @intCast(last_id))] != NullId) {
                last_id = items.items(.next_sibling)[@as(usize, @intCast(last_id))];
            }
            const last_idx: usize = @intCast(last_id);
            items.items(.next_sibling)[last_idx] = child_id;
            items.items(.prev_sibling)[c] = last_id;
        }
        p_count.* += 1;
        self.dirty = true;
    }

    pub fn removeChild(self: *Dom, parent_id: DomNodeId, child_id: DomNodeId) !void {
        const p: usize = @intCast(parent_id);
        const c: usize = @intCast(child_id);
        var items = self.headers.slice();

        // Check if child is actually a child of parent
        if (items.items(.parent)[c] != parent_id) return;

        // Only element nodes can have children
        switch (items.items(.content)[p]) {
            .element => {},
            else => return error.InvalidNodeKind,
        }
        // Access parent's children payload
        const content_ptr = &items.items(.content)[p];
        var p_first: *DomNodeId = undefined;
        var p_count: *u32 = undefined;
        switch (content_ptr.*) {
            .element => |*ch| {
                p_first = &ch.first_child;
                p_count = &ch.child_count;
            },
            else => return error.InvalidNodeKind,
        }
        const c_prev = items.items(.prev_sibling)[c];
        const c_next = items.items(.next_sibling)[c];

        // Update parent's first_child if needed
        if (p_first.* == child_id) {
            p_first.* = c_next;
        }

        // Update sibling links
        if (c_prev != NullId) {
            items.items(.next_sibling)[@intCast(c_prev)] = c_next;
        }
        if (c_next != NullId) {
            items.items(.prev_sibling)[@intCast(c_next)] = c_prev;
        }

        // Clear child's parent and sibling links
        items.items(.parent)[c] = NullId;
        items.items(.prev_sibling)[c] = NullId;
        items.items(.next_sibling)[c] = NullId;

        // Decrement parent's child count
        if (p_count.* > 0) {
            p_count.* -= 1;
        }
        self.dirty = true;
    }

    /// Set a debug ID for a node - string is copied to DOM's allocator
    pub fn setDebugId(self: *Dom, id: DomNodeId, debug_id: []const u8) !void {
        const owned_id = try self.alloc.dupe(u8, debug_id);
        try self.debug_ids.put(id, owned_id);
        self.dirty = true;
    }

    /// Get debug ID for a node, or null if not set
    pub fn getDebugId(self: *const Dom, id: DomNodeId) ?[]const u8 {
        return self.debug_ids.get(id);
    }

    /// Get debug ID for a node, or return default string with numeric ID
    pub fn getDebugIdOrDefault(self: *const Dom, id: DomNodeId, buf: []u8) []const u8 {
        if (self.debug_ids.get(id)) |debug_id| {
            return debug_id;
        } else {
            return std.fmt.bufPrint(buf, "#{d}", .{id}) catch "?";
        }
    }

    /// Get the style row for a node
    pub fn getNodeStyle(self: *const Dom, id: DomNodeId) StyleRow {
        const items = self.headers.slice();
        const style_id = items.items(.style_id)[@as(usize, @intCast(id))];
        return self.styles.cols.items[@intCast(style_id)];
    }

    /// Get the kind (element or text) for a node
    pub fn getNodeKind(self: *const Dom, id: DomNodeId) DomNodeKind {
        const items = self.headers.slice();
        return switch (items.items(.content)[@as(usize, @intCast(id))]) {
            .element => .element,
            .text => .text,
        };
    }

    /// Returns number of children if node is an element, otherwise 0
    pub fn getChildCount(self: *const Dom, parent_id: DomNodeId) usize {
        const items = self.headers.slice();
        const idx: usize = @intCast(parent_id);
        return switch (items.items(.content)[idx]) {
            .element => |ch| @intCast(ch.child_count),
            else => 0,
        };
    }

    /// Returns the nth child id if available, otherwise `NullId`. Only valid for element nodes.
    pub fn getChild(self: *const Dom, parent_id: DomNodeId, index: usize) DomNodeId {
        const items = self.headers.slice();
        const idx: usize = @intCast(parent_id);
        return switch (items.items(.content)[idx]) {
            .element => |ch| blk: {
                var i: usize = 0;
                var c = ch.first_child;
                while (i < index and c != NullId) : (i += 1) {
                    c = items.items(.next_sibling)[@as(usize, @intCast(c))];
                }
                break :blk c;
            },
            else => NullId,
        };
    }

    /// Get the first child of an element node, or NullId if not an element or has no children
    pub fn getFirstChild(self: *const Dom, parent_id: DomNodeId) DomNodeId {
        const items = self.headers.slice();
        const idx: usize = @intCast(parent_id);
        return switch (items.items(.content)[idx]) {
            .element => |ch| ch.first_child,
            else => NullId,
        };
    }

    /// Get the next sibling of a node
    pub fn getNextSibling(self: *const Dom, node_id: DomNodeId) DomNodeId {
        const items = self.headers.slice();
        return items.items(.next_sibling)[@intCast(node_id)];
    }

    /// Get the content union for a node
    pub fn getNodeContent(self: *const Dom, node_id: DomNodeId) @TypeOf(self.headers.slice().items(.content)[0]) {
        const items = self.headers.slice();
        return items.items(.content)[@intCast(node_id)];
    }
};

pub const BoxNode = struct {
    id: DomNodeId,
    rect: Rect,
    first_child: ?*BoxNode,
    next_sibling: ?*BoxNode,
};

pub fn buildBoxTree(arena: *std.heap.ArenaAllocator, dom: *const Dom, root: DomNodeId) !*BoxNode {
    const alloc = arena.allocator();
    const node = try alloc.create(BoxNode);
    node.* = .{ .id = root, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .first_child = null, .next_sibling = null };
    // Build children linearly
    const items = dom.headers.slice();
    var cur_child: DomNodeId = Dom.NullId;
    switch (items.items(.content)[@as(usize, @intCast(root))]) {
        .element => |ch| cur_child = ch.first_child,
        else => cur_child = Dom.NullId,
    }
    var prev_ptr: ?*BoxNode = null;
    while (cur_child != Dom.NullId) {
        const child_ptr = try buildBoxTree(arena, dom, cur_child);
        if (prev_ptr) |prev| prev.next_sibling = child_ptr else node.first_child = child_ptr;
        prev_ptr = child_ptr;
        cur_child = items.items(.next_sibling)[@as(usize, @intCast(cur_child))];
    }
    return node;
}
