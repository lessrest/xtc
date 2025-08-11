const std = @import("std");
const dom = @import("dom.zig");
const events = @import("events.zig");
const wren = @import("wren/vm.zig");

test "DOM with event registry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create a DOM with event support
    var document = dom.Dom.init(allocator);
    defer document.deinit();
    
    // Add some elements
    const root = try document.addElement("flex");
    const button = try document.addElement("px-4 py-2 bg-blue-500");
    document.appendChild(root, button);
    
    // Mock a Wren handle
    const mock_handle = @as(*wren.c.WrenHandle, @ptrFromInt(0x1234));
    
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

test "Event system with multiple nodes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var document = dom.Dom.init(allocator);
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
    const handle1 = @as(*wren.c.WrenHandle, @ptrFromInt(0x2001));
    const handle2 = @as(*wren.c.WrenHandle, @ptrFromInt(0x2002));
    const handle3 = @as(*wren.c.WrenHandle, @ptrFromInt(0x2003));
    
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

test "Event creation and modification" {
    const now = std.time.timestamp();
    
    var event = events.Event{
        .type = .click,
        .target = 42,
        .timestamp = now,
    };
    
    try std.testing.expectEqual(events.EventType.click, event.type);
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

test "Event type string conversions" {
    // Test all event types
    const test_cases = [_]struct {
        event_type: events.EventType,
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
        const parsed = events.EventType.fromString(tc.string);
        try std.testing.expectEqual(tc.event_type, parsed.?);
    }
    
    // Test invalid string
    const invalid = events.EventType.fromString("not_an_event");
    try std.testing.expectEqual(@as(?events.EventType, null), invalid);
}

test "Event registry memory management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    {
        var registry = events.EventRegistry.init(allocator);
        defer registry.deinit();
        
        var handler_ids: [100]u32 = undefined;
        
        // Add many handlers
        for (0..100) |i| {
            const node_id: dom.DomNodeId = @intCast(i % 10); // 10 different nodes
            const event_type: events.EventType = if (i % 2 == 0) .click else .keypress;
            const handle = @as(*wren.c.WrenHandle, @ptrFromInt(0x3000 + i));
            handler_ids[i] = try registry.addEventListener(node_id, event_type, handle);
        }
        
        // Remove half of them
        for (0..50) |i| {
            const node_id: dom.DomNodeId = @intCast(i % 10);
            const event_type: events.EventType = if (i % 2 == 0) .click else .keypress;
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

test "Integration: DOM node lifecycle with events" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var document = dom.Dom.init(allocator);
    defer document.deinit();
    
    // Simulate creating elements with event listeners
    const container = try document.addElement("flex");
    
    // Create buttons in a loop
    var buttons: [5]dom.DomNodeId = undefined;
    
    for (0..5) |i| {
        buttons[i] = try document.addElement("px-2 py-1");
        document.appendChild(container, buttons[i]);
        
        // Add click handler to each button
        const handle = @as(*wren.c.WrenHandle, @ptrFromInt(0x4000 + i));
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