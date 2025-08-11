const std = @import("std");
const StyleRow = @import("style.zig").StyleRow;
const StyleTable = @import("style.zig").StyleTable;
const parseUtilityClassList = @import("tailwind.zig").parseUtilityClassList;
const defaultStyleRow = @import("style.zig").defaultStyleRow;
const Rect = @import("layout.zig").Rect;
const EventRegistry = @import("events.zig").EventRegistry;

pub const DomNodeId = u32;
pub const DomNodeKind = enum { element, text };

pub const DomNodeHeader = struct {
    kind: DomNodeKind,
    parent: DomNodeId,
    prev_sibling: DomNodeId,
    next_sibling: DomNodeId,
    first_child: DomNodeId,
    child_count: u32,
    style_id: u32,
};

pub const Dom = struct {
    pub const NullId: DomNodeId = std.math.maxInt(DomNodeId);

    alloc: std.mem.Allocator,
    headers: std.MultiArrayList(DomNodeHeader) = .{},
    styles: StyleTable,
    text_arena: std.ArrayList(u8),
    debug_ids: std.AutoHashMap(DomNodeId, []const u8),
    event_registry: EventRegistry,

    pub fn init(alloc: std.mem.Allocator) Dom {
        return .{
            .alloc = alloc,
            .headers = .{},
            .styles = StyleTable.init(alloc),
            .text_arena = std.ArrayList(u8).init(alloc),
            .debug_ids = std.AutoHashMap(DomNodeId, []const u8).init(alloc),
            .event_registry = EventRegistry.init(alloc),
        };
    }

    pub fn deinit(self: *Dom) void {
        self.headers.deinit(self.alloc);
        self.styles.deinit();
        self.text_arena.deinit();
        var it = self.debug_ids.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.value_ptr.*);
        }
        self.debug_ids.deinit();
        self.event_registry.deinit();
        self.* = undefined;
    }

    pub fn addElement(self: *Dom, style_bytes: []const u8) !DomNodeId {
        // Parse utility-class list (Tailwind-like) into a StyleRow
        const style_row = parseUtilityClassList(style_bytes);
        const style_id = try self.styles.intern(self.alloc, style_row);
        const idx = try self.headers.addOne(self.alloc);
        self.headers.set(idx, .{
            .kind = .element,
            .parent = NullId,
            .prev_sibling = NullId,
            .next_sibling = NullId,
            .first_child = NullId,
            .child_count = 0,
            .style_id = style_id,
        });
        return @as(DomNodeId, @intCast(idx));
    }

    /// Set a node's style by interning the provided `StyleRow` and storing its id.
    pub fn setStyle(self: *Dom, id: DomNodeId, row: StyleRow) !void {
        const sid = try self.styles.intern(self.alloc, row);
        const items = self.headers.slice();
        items.items(.style_id)[@as(usize, @intCast(id))] = sid;
    }

    pub fn addText(self: *Dom, utf8: []const u8) !DomNodeId {
        const style_id = try self.styles.intern(self.alloc, defaultStyleRow());
        const off: u32 = @intCast(self.text_arena.items.len);
        try self.text_arena.appendSlice(utf8);
        const len: u32 = @intCast(utf8.len);
        const idx = try self.headers.addOne(self.alloc);
        self.headers.set(idx, .{
            .kind = .text,
            .parent = NullId,
            .prev_sibling = NullId,
            .next_sibling = NullId,
            .first_child = @as(DomNodeId, off), // overloaded for text offset
            .child_count = len, // overloaded for text length
            .style_id = style_id,
        });
        return @as(DomNodeId, @intCast(idx));
    }

    pub fn getTextSlice(self: *const Dom, id: DomNodeId) []const u8 {
        const items = self.headers.slice();
        const off: usize = @intCast(items.items(.first_child)[@intCast(id)]);
        const len: usize = @intCast(items.items(.child_count)[@intCast(id)]);
        return self.text_arena.items[off .. off + len];
    }
    
    pub fn updateText(self: *Dom, id: DomNodeId, new_text: []const u8) !void {
        const idx: usize = @intCast(id);
        var items = self.headers.slice();
        
        // Only works on text nodes
        if (items.items(.kind)[idx] != .text) return;
        
        // Append new text to arena
        const off = self.text_arena.items.len;
        try self.text_arena.appendSlice(new_text);
        const len = new_text.len;
        
        // Update the text node's offset and length
        items.items(.first_child)[idx] = @intCast(off);
        items.items(.child_count)[idx] = @intCast(len);
    }
    
    pub fn updateClass(self: *Dom, id: DomNodeId, new_class: []const u8) !void {
        const idx: usize = @intCast(id);
        var items = self.headers.slice();
        
        // Only works on element nodes  
        if (items.items(.kind)[idx] != .element) return;
        
        // Parse utility-class list and intern the new style
        const style_row = parseUtilityClassList(new_class);
        const new_style_id = try self.styles.intern(self.alloc, style_row);
        items.items(.style_id)[idx] = new_style_id;
    }

    pub fn appendChild(self: *Dom, parent_id: DomNodeId, child_id: DomNodeId) void {
        const p: usize = @intCast(parent_id);
        const c: usize = @intCast(child_id);
        var items = self.headers.slice();
        const p_first = &items.items(.first_child)[p];
        const p_count = &items.items(.child_count)[p];
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
    }

    pub fn removeChild(self: *Dom, parent_id: DomNodeId, child_id: DomNodeId) void {
        const p: usize = @intCast(parent_id);
        const c: usize = @intCast(child_id);
        var items = self.headers.slice();
        
        // Check if child is actually a child of parent
        if (items.items(.parent)[c] != parent_id) return;
        
        const p_first = &items.items(.first_child)[p];
        const p_count = &items.items(.child_count)[p];
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
    }

    /// Set a debug ID for a node - string is copied to DOM's allocator
    pub fn setDebugId(self: *Dom, id: DomNodeId, debug_id: []const u8) !void {
        const owned_id = try self.alloc.dupe(u8, debug_id);
        try self.debug_ids.put(id, owned_id);
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
        return items.items(.kind)[@as(usize, @intCast(id))];
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
    var cur_child = items.items(.first_child)[@as(usize, @intCast(root))];
    var prev_ptr: ?*BoxNode = null;
    while (cur_child != Dom.NullId) {
        const child_ptr = try buildBoxTree(arena, dom, cur_child);
        if (prev_ptr) |prev| prev.next_sibling = child_ptr else node.first_child = child_ptr;
        prev_ptr = child_ptr;
        cur_child = items.items(.next_sibling)[@as(usize, @intCast(cur_child))];
    }
    return node;
}
