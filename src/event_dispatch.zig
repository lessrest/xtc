const std = @import("std");
const wren = @import("wren/vm.zig");
const events = @import("events.zig");
const dom = @import("dom.zig");

/// Dispatch an event to all registered handlers in the DOM
pub fn dispatchEvent(
    vm: *wren.c.VM,
    document: *dom.Dom,
    event: events.Event,
) !void {
    // Get handlers for this event
    const handlers = document.event_registry.getHandlers(event.target, event.type) orelse return;

    // For each handler, call the Wren function
    for (handlers) |handler| {
        // We need at least 2 slots: one for the receiver (the function) and one for the event data
        wren.c.wrenEnsureSlots(vm, 4);

        // Put the handler function in slot 0 (receiver)
        wren.c.wrenSetSlotHandle(vm, 0, handler.handle);

        // Create an event object map in slot 1
        wren.c.wrenSetSlotNewMap(vm, 1);

        // Add event type
        wren.c.wrenSetSlotString(vm, 2, "type");
        wren.c.wrenSetSlotString(vm, 3, event.type.toString());
        wren.c.wrenSetMapValue(vm, 1, 2, 3);

        // Add target node ID
        wren.c.wrenSetSlotString(vm, 2, "target");
        wren.c.wrenSetSlotDouble(vm, 3, @floatFromInt(event.target));
        wren.c.wrenSetMapValue(vm, 1, 2, 3);

        // Add key if present
        if (event.key) |key| {
            wren.c.wrenSetSlotString(vm, 2, "key");
            wren.c.wrenSetSlotBytes(vm, 3, key.ptr, key.len);
            wren.c.wrenSetMapValue(vm, 1, 2, 3);
        }

        // Add mouse coordinates if present
        if (event.mouse_x) |x| {
            wren.c.wrenSetSlotString(vm, 2, "x");
            wren.c.wrenSetSlotDouble(vm, 3, @floatFromInt(x));
            wren.c.wrenSetMapValue(vm, 1, 2, 3);
        }

        if (event.mouse_y) |y| {
            wren.c.wrenSetSlotString(vm, 2, "y");
            wren.c.wrenSetSlotDouble(vm, 3, @floatFromInt(y));
            wren.c.wrenSetMapValue(vm, 1, 2, 3);
        }


        // Add timestamp
        wren.c.wrenSetSlotString(vm, 2, "timestamp");
        wren.c.wrenSetSlotDouble(vm, 3, @floatFromInt(event.timestamp));
        wren.c.wrenSetMapValue(vm, 1, 2, 3);

        // Create a call handle for calling with 1 argument
        const signature = "call(_)";
        const call_handle = wren.c.wrenMakeCallHandle(vm, signature) orelse {
            std.log.warn("Failed to create call handle for event dispatch", .{});
            continue;
        };
        defer wren.c.wrenReleaseHandle(vm, call_handle);

        // Call the handler with the event map as argument
        const result = wren.c.wrenCall(vm, call_handle);
        if (result != @intFromEnum(wren.c.InterpretResult.success)) {
            std.log.warn("Event handler failed for {s}", .{event.type.toString()});
        }

        // Check if propagation was stopped (would need to be set by the handler)
        if (event.propagation_stopped) break;
    }
}


/// Helper to dispatch a keypress event to the global document (node 0)
pub fn dispatchKeypress(
    vm: *wren.c.VM,
    document: *dom.Dom,
    key: []const u8,
) !void {
    const event = events.Event{
        .type = .keypress,
        .target = 0, // Global/document node
        .key = key,
        .timestamp = std.time.timestamp(),
    };

    try dispatchEvent(vm, document, event);
}

/// Helper to dispatch other keyboard events
pub fn dispatchKeyEvent(
    vm: *wren.c.VM,
    document: *dom.Dom,
    event_type: events.EventType,
    key: []const u8,
) !void {
    const event = events.Event{
        .type = event_type,
        .target = 0, // Global/document node
        .key = key,
        .timestamp = std.time.timestamp(),
    };

    try dispatchEvent(vm, document, event);
}
