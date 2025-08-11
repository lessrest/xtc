const std = @import("std");
const wren = @import("wren.zig");
const dom = @import("dom.zig");

pub const EventType = enum {
    click,
    keypress,
    keydown,
    keyup,
    focus,
    blur,
    mousedown,
    mouseup,
    mousemove,

    pub fn toString(self: EventType) [:0]const u8 {
        return switch (self) {
            .click => "click",
            .keypress => "keypress",
            .keydown => "keydown",
            .keyup => "keyup",
            .focus => "focus",
            .blur => "blur",
            .mousedown => "mousedown",
            .mouseup => "mouseup",
            .mousemove => "mousemove",
        };
    }

    pub fn fromString(str: []const u8) ?EventType {
        inline for (@typeInfo(EventType).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, str)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const Event = struct {
    type: EventType,
    target: dom.DomNodeId,
    // Event data
    key: ?[]const u8 = null,
    mouse_x: ?i32 = null,
    mouse_y: ?i32 = null,
    timestamp: i64,
    propagation_stopped: bool = false,
    default_prevented: bool = false,
};

/// A handle to a Wren callback function
pub const EventHandler = struct {
    handle: *wren.c.WrenHandle,
    id: u32, // Unique ID for this handler
};

/// Event listener registration for a single event type on a node
pub const EventListeners = struct {
    handlers: std.ArrayList(EventHandler),
    
    pub fn init(allocator: std.mem.Allocator) EventListeners {
        return .{
            .handlers = std.ArrayList(EventHandler).init(allocator),
        };
    }
    
    pub fn deinit(self: *EventListeners) void {
        self.handlers.deinit();
    }
    
    pub fn addHandler(self: *EventListeners, handler: EventHandler) !void {
        try self.handlers.append(handler);
    }
    
    pub fn removeHandler(self: *EventListeners, handler_id: u32) bool {
        for (self.handlers.items, 0..) |h, i| {
            if (h.id == handler_id) {
                _ = self.handlers.swapRemove(i);
                return true;
            }
        }
        return false;
    }
};

/// Event registry that tracks all event listeners for the DOM
pub const EventRegistry = struct {
    allocator: std.mem.Allocator,
    // Map from node ID to a map of event types to listeners
    node_listeners: std.AutoHashMap(dom.DomNodeId, *NodeEventMap),
    // Counter for generating unique handler IDs
    next_handler_id: u32,
    // Store handles to prevent GC (Wren needs us to hold references)
    handle_registry: std.ArrayList(EventHandler),
    
    const NodeEventMap = std.AutoHashMap(EventType, EventListeners);
    
    pub fn init(allocator: std.mem.Allocator) EventRegistry {
        return .{
            .allocator = allocator,
            .node_listeners = std.AutoHashMap(dom.DomNodeId, *NodeEventMap).init(allocator),
            .next_handler_id = 1,
            .handle_registry = std.ArrayList(EventHandler).init(allocator),
        };
    }
    
    pub fn deinit(self: *EventRegistry) void {
        // Clean up all node event maps
        var node_iter = self.node_listeners.iterator();
        while (node_iter.next()) |entry| {
            var event_iter = entry.value_ptr.*.iterator();
            while (event_iter.next()) |event_entry| {
                event_entry.value_ptr.deinit();
            }
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.node_listeners.deinit();
        self.handle_registry.deinit();
    }
    
    /// Add an event listener to a node
    pub fn addEventListener(
        self: *EventRegistry,
        node_id: dom.DomNodeId,
        event_type: EventType,
        handle: *wren.c.WrenHandle,
    ) !u32 {
        // Get or create the event map for this node
        const gop = try self.node_listeners.getOrPut(node_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = try self.allocator.create(NodeEventMap);
            gop.value_ptr.*.* = NodeEventMap.init(self.allocator);
        }
        
        // Get or create the listener list for this event type
        const event_map = gop.value_ptr.*;
        const event_gop = try event_map.getOrPut(event_type);
        if (!event_gop.found_existing) {
            event_gop.value_ptr.* = EventListeners.init(self.allocator);
        }
        
        // Create handler and add it
        const handler_id = self.next_handler_id;
        self.next_handler_id += 1;
        
        const handler = EventHandler{
            .handle = handle,
            .id = handler_id,
        };
        
        try event_gop.value_ptr.addHandler(handler);
        try self.handle_registry.append(handler);
        
        return handler_id;
    }
    
    /// Remove an event listener by its handler ID
    pub fn removeEventListener(
        self: *EventRegistry,
        node_id: dom.DomNodeId,
        event_type: EventType,
        handler_id: u32,
    ) bool {
        const node_map = self.node_listeners.get(node_id) orelse return false;
        var listeners = node_map.getPtr(event_type) orelse return false;
        
        const removed = listeners.removeHandler(handler_id);
        
        // Clean up empty structures
        if (listeners.handlers.items.len == 0) {
            listeners.deinit();
            _ = node_map.remove(event_type);
            
            if (node_map.count() == 0) {
                node_map.deinit();
                self.allocator.destroy(node_map);
                _ = self.node_listeners.remove(node_id);
            }
        }
        
        // Remove from handle registry
        if (removed) {
            for (self.handle_registry.items, 0..) |h, i| {
                if (h.id == handler_id) {
                    _ = self.handle_registry.swapRemove(i);
                    break;
                }
            }
        }
        
        return removed;
    }
    
    /// Remove all event listeners for a node (useful when node is destroyed)
    pub fn removeAllListeners(self: *EventRegistry, node_id: dom.DomNodeId) void {
        const node_map = self.node_listeners.get(node_id) orelse return;
        
        var event_iter = node_map.iterator();
        while (event_iter.next()) |entry| {
            // Remove all handlers from handle registry
            for (entry.value_ptr.handlers.items) |handler| {
                for (self.handle_registry.items, 0..) |h, i| {
                    if (h.id == handler.id) {
                        _ = self.handle_registry.swapRemove(i);
                        break;
                    }
                }
            }
            entry.value_ptr.deinit();
        }
        
        node_map.deinit();
        self.allocator.destroy(node_map);
        _ = self.node_listeners.remove(node_id);
    }
    
    /// Get all handlers for a specific event on a node
    pub fn getHandlers(
        self: *EventRegistry,
        node_id: dom.DomNodeId,
        event_type: EventType,
    ) ?[]const EventHandler {
        const node_map = self.node_listeners.get(node_id) orelse return null;
        const listeners = node_map.get(event_type) orelse return null;
        return listeners.handlers.items;
    }
    
    /// Check if a node has any listeners for a specific event type
    pub fn hasListeners(
        self: *EventRegistry,
        node_id: dom.DomNodeId,
        event_type: EventType,
    ) bool {
        const handlers = self.getHandlers(node_id, event_type) orelse return false;
        return handlers.len > 0;
    }
};

// Tests
test "EventType string conversion" {
    try std.testing.expectEqualStrings("click", EventType.click.toString());
    try std.testing.expectEqual(EventType.click, EventType.fromString("click"));
    try std.testing.expectEqual(@as(?EventType, null), EventType.fromString("invalid"));
}

test "EventRegistry basic operations" {
    var registry = EventRegistry.init(std.testing.allocator);
    defer registry.deinit();
    
    // Mock Wren handle pointer (in real usage, this would come from Wren VM)
    const mock_handle = @as(*wren.c.WrenHandle, @ptrFromInt(0x1234));
    
    // Add a listener
    const handler_id = try registry.addEventListener(1, .click, mock_handle);
    try std.testing.expect(handler_id > 0);
    
    // Check it exists
    try std.testing.expect(registry.hasListeners(1, .click));
    try std.testing.expect(!registry.hasListeners(1, .keypress));
    try std.testing.expect(!registry.hasListeners(2, .click));
    
    // Get handlers
    const handlers = registry.getHandlers(1, .click);
    try std.testing.expect(handlers != null);
    try std.testing.expectEqual(@as(usize, 1), handlers.?.len);
    
    // Remove the listener
    try std.testing.expect(registry.removeEventListener(1, .click, handler_id));
    try std.testing.expect(!registry.hasListeners(1, .click));
    
    // Try to remove again (should fail)
    try std.testing.expect(!registry.removeEventListener(1, .click, handler_id));
}

test "EventRegistry multiple handlers" {
    var registry = EventRegistry.init(std.testing.allocator);
    defer registry.deinit();
    
    const handle1 = @as(*wren.c.WrenHandle, @ptrFromInt(0x1001));
    const handle2 = @as(*wren.c.WrenHandle, @ptrFromInt(0x1002));
    const handle3 = @as(*wren.c.WrenHandle, @ptrFromInt(0x1003));
    
    // Add multiple handlers for same event
    const id1 = try registry.addEventListener(1, .click, handle1);
    const id2 = try registry.addEventListener(1, .click, handle2);
    
    // Add handler for different event
    _ = try registry.addEventListener(1, .keypress, handle3);
    
    // Check counts
    const click_handlers = registry.getHandlers(1, .click);
    try std.testing.expectEqual(@as(usize, 2), click_handlers.?.len);
    
    const key_handlers = registry.getHandlers(1, .keypress);
    try std.testing.expectEqual(@as(usize, 1), key_handlers.?.len);
    
    // Remove middle handler
    try std.testing.expect(registry.removeEventListener(1, .click, id2));
    const remaining = registry.getHandlers(1, .click);
    try std.testing.expectEqual(@as(usize, 1), remaining.?.len);
    try std.testing.expectEqual(id1, remaining.?[0].id);
}

test "EventRegistry removeAllListeners" {
    var registry = EventRegistry.init(std.testing.allocator);
    defer registry.deinit();
    
    const handle1 = @as(*wren.c.WrenHandle, @ptrFromInt(0x2001));
    const handle2 = @as(*wren.c.WrenHandle, @ptrFromInt(0x2002));
    
    // Add handlers to multiple nodes
    _ = try registry.addEventListener(1, .click, handle1);
    _ = try registry.addEventListener(1, .keypress, handle2);
    _ = try registry.addEventListener(2, .click, handle1);
    
    // Remove all for node 1
    registry.removeAllListeners(1);
    
    // Check node 1 has no listeners
    try std.testing.expect(!registry.hasListeners(1, .click));
    try std.testing.expect(!registry.hasListeners(1, .keypress));
    
    // Check node 2 still has listeners
    try std.testing.expect(registry.hasListeners(2, .click));
}