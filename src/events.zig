const std = @import("std");
const wren = @import("wren/vm.zig");
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
    tick,

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
            .tick => "tick",
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
    tick_count: ?u64 = null,
    timestamp: i64,
    propagation_stopped: bool = false,
    default_prevented: bool = false,
};

/// A handle to a Wren callback function
pub const EventHandler = struct {
    handle: *wren.c.Handle,
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
        handle: *wren.c.Handle,
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
test "event type enum converts to and from string representation correctly" {
    try std.testing.expectEqualStrings("click", EventType.click.toString());
    try std.testing.expectEqual(EventType.click, EventType.fromString("click"));
    try std.testing.expectEqual(@as(?EventType, null), EventType.fromString("invalid"));
}

test "event registry adds, queries, and removes single event listeners" {
    var registry = EventRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Mock Wren handle pointer (in real usage, this would come from Wren VM)
    const mock_handle = @as(*wren.c.Handle, @ptrFromInt(0x1234));

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

test "event registry manages multiple handlers for the same node and event type" {
    var registry = EventRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handle1 = @as(*wren.c.Handle, @ptrFromInt(0x1001));
    const handle2 = @as(*wren.c.Handle, @ptrFromInt(0x1002));
    const handle3 = @as(*wren.c.Handle, @ptrFromInt(0x1003));

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

test "event registry removes all listeners for a specific node at once" {
    var registry = EventRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handle1 = @as(*wren.c.Handle, @ptrFromInt(0x2001));
    const handle2 = @as(*wren.c.Handle, @ptrFromInt(0x2002));

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

test "dom nodes can have event listeners attached through the event registry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a DOM with event support
    var document = try dom.Dom.init(allocator);
    defer document.deinit();

    // Add some elements
    const root = try document.addElement("flex");
    const button = try document.addElement("px-4 py-2 bg-blue-500");
    document.appendChild(root, button);

    // Mock a Wren handle
    const mock_handle = @as(*wren.c.Handle, @ptrFromInt(0x1234));

    // Register an event listener
    const handler_id = try document.event_registry.addEventListener(
        button,
        .click,
        mock_handle,
    );

    // Verify it was registered
    try std.testing.expect(document.event_registry.hasListeners(button, .click));

    // Get handlers and verify
    const handlers = document.event_registry.getHandlers(button, .click);
    try std.testing.expect(handlers != null);
    try std.testing.expectEqual(@as(usize, 1), handlers.?.len);
    try std.testing.expectEqual(handler_id, handlers.?[0].id);

    // Remove the listener
    const removed = document.event_registry.removeEventListener(button, .click, handler_id);
    try std.testing.expect(removed);
    try std.testing.expect(!document.event_registry.hasListeners(button, .click));
}

test "event system handles different events on different nodes independently" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var document = try dom.Dom.init(allocator);
    defer document.deinit();

    // Create a small DOM tree
    const root = try document.addElement("flex flex-col");
    const header = try document.addElement("h-10 bg-gray-200");
    const button1 = try document.addElement("px-4 py-2 bg-blue-500");
    const button2 = try document.addElement("px-4 py-2 bg-green-500");

    document.appendChild(root, header);
    document.appendChild(root, button1);
    document.appendChild(root, button2);

    // Mock handles
    const handle1 = @as(*wren.c.Handle, @ptrFromInt(0x2001));
    const handle2 = @as(*wren.c.Handle, @ptrFromInt(0x2002));
    const handle3 = @as(*wren.c.Handle, @ptrFromInt(0x2003));

    // Register different events on different nodes
    _ = try document.event_registry.addEventListener(button1, .click, handle1);
    _ = try document.event_registry.addEventListener(button2, .click, handle2);
    _ = try document.event_registry.addEventListener(header, .mousemove, handle3);

    // Verify registrations
    try std.testing.expect(document.event_registry.hasListeners(button1, .click));
    try std.testing.expect(document.event_registry.hasListeners(button2, .click));
    try std.testing.expect(document.event_registry.hasListeners(header, .mousemove));
    try std.testing.expect(!document.event_registry.hasListeners(header, .click));

    // Remove all listeners for button1
    document.event_registry.removeAllListeners(button1);
    try std.testing.expect(!document.event_registry.hasListeners(button1, .click));

    // Others should still be registered
    try std.testing.expect(document.event_registry.hasListeners(button2, .click));
    try std.testing.expect(document.event_registry.hasListeners(header, .mousemove));
}

test "event objects store type, target, and optional keyboard and mouse data" {
    const now = std.time.timestamp();

    var event = Event{
        .type = .click,
        .target = 42,
        .timestamp = now,
    };

    try std.testing.expectEqual(EventType.click, event.type);
    try std.testing.expectEqual(@as(dom.DomNodeId, 42), event.target);
    try std.testing.expectEqual(false, event.propagation_stopped);
    try std.testing.expectEqual(false, event.default_prevented);

    // Simulate preventDefault
    event.default_prevented = true;
    try std.testing.expectEqual(true, event.default_prevented);

    // Add keyboard data
    event.key = "Enter";
    try std.testing.expectEqualStrings("Enter", event.key.?);

    // Add mouse data
    event.mouse_x = 100;
    event.mouse_y = 200;
    try std.testing.expectEqual(@as(?i32, 100), event.mouse_x);
    try std.testing.expectEqual(@as(?i32, 200), event.mouse_y);
}

test "all event type enums convert bidirectionally with their string names" {
    // Test all event types
    const test_cases = [_]struct {
        event_type: EventType,
        string: []const u8,
    }{
        .{ .event_type = .click, .string = "click" },
        .{ .event_type = .keypress, .string = "keypress" },
        .{ .event_type = .keydown, .string = "keydown" },
        .{ .event_type = .keyup, .string = "keyup" },
        .{ .event_type = .focus, .string = "focus" },
        .{ .event_type = .blur, .string = "blur" },
        .{ .event_type = .mousedown, .string = "mousedown" },
        .{ .event_type = .mouseup, .string = "mouseup" },
        .{ .event_type = .mousemove, .string = "mousemove" },
    };

    for (test_cases) |tc| {
        // Test toString
        try std.testing.expectEqualStrings(tc.string, tc.event_type.toString());

        // Test fromString
        const parsed = EventType.fromString(tc.string);
        try std.testing.expectEqual(tc.event_type, parsed.?);
    }

    // Test invalid string
    const invalid = EventType.fromString("not_an_event");
    try std.testing.expectEqual(@as(?EventType, null), invalid);
}

test "event registry properly manages memory when adding and removing many handlers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    {
        var registry = EventRegistry.init(allocator);
        defer registry.deinit();

        var handler_ids: [100]u32 = undefined;

        // Add many handlers
        for (0..100) |i| {
            const node_id: dom.DomNodeId = @intCast(i % 10); // 10 different nodes
            const event_type: EventType = if (i % 2 == 0) .click else .keypress;
            const handle = @as(*wren.c.Handle, @ptrFromInt(0x3000 + i));
            handler_ids[i] = try registry.addEventListener(node_id, event_type, handle);
        }

        // Remove half of them
        for (0..50) |i| {
            const node_id: dom.DomNodeId = @intCast(i % 10);
            const event_type: EventType = if (i % 2 == 0) .click else .keypress;
            _ = registry.removeEventListener(node_id, event_type, handler_ids[i]);
        }

        // Remove all listeners for node 0
        registry.removeAllListeners(0);

        // Verify node 0 has no listeners
        try std.testing.expect(!registry.hasListeners(0, .click));
        try std.testing.expect(!registry.hasListeners(0, .keypress));
    }

    // Check for memory leaks (gpa will detect them)
}

test "dom nodes with event listeners clean up properly during lifecycle operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var document = try dom.Dom.init(allocator);
    defer document.deinit();

    // Simulate creating elements with event listeners
    const container = try document.addElement("flex");

    // Create buttons in a loop
    var buttons: [5]dom.DomNodeId = undefined;

    for (0..5) |i| {
        buttons[i] = try document.addElement("px-2 py-1");
        document.appendChild(container, buttons[i]);

        // Add click handler to each button
        const handle = @as(*wren.c.Handle, @ptrFromInt(0x4000 + i));
        _ = try document.event_registry.addEventListener(
            buttons[i],
            .click,
            handle,
        );
    }

    // Verify all buttons have click handlers
    for (buttons) |button| {
        try std.testing.expect(document.event_registry.hasListeners(button, .click));
    }

    // Simulate removing a button (would happen in real DOM manipulation)
    // In a real system, we'd call removeAllListeners when a node is destroyed
    document.event_registry.removeAllListeners(buttons[2]);

    // Verify button 2 has no listeners
    try std.testing.expect(!document.event_registry.hasListeners(buttons[2], .click));

    // Others should still have listeners
    try std.testing.expect(document.event_registry.hasListeners(buttons[0], .click));
    try std.testing.expect(document.event_registry.hasListeners(buttons[1], .click));
    try std.testing.expect(document.event_registry.hasListeners(buttons[3], .click));
    try std.testing.expect(document.event_registry.hasListeners(buttons[4], .click));
}
