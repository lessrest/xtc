/// Wren-specific event handling extensions
const std = @import("std");
const wren = @import("wren.zig");
const DomNodeId = @import("dom.zig").DomNodeId;
const Dom = @import("dom.zig").Dom;
const events = @import("events.zig");

/// Extended ScriptContext for event handling
/// This will be mixed into the main ScriptContext
pub const EventMethods = struct {
    /// Register an event listener from Wren
    /// Called as: DOM.addEventListener(nodeId, "click", handler)
    /// The handler should be in slot 3
    pub fn addEventListener(vm_ptr: *wren.c.WrenVM, ctx_ptr: *anyopaque) !u32 {
        const ctx: *ScriptContextWithEvents = @ptrCast(@alignCast(ctx_ptr));

        // Get arguments from Wren slots
        const node_id = @as(DomNodeId, @intFromFloat(wren.c.wrenGetSlotDouble(vm_ptr, 1)));

        var len: c_int = 0;
        const event_type_ptr = wren.c.wrenGetSlotBytes(vm_ptr, 2, &len);
        const event_type_str = event_type_ptr[0..@intCast(len)];

        const event_type = events.EventType.fromString(event_type_str) orelse {
            // Set error and abort
            wren.c.wrenSetSlotString(vm_ptr, 0, "Unknown event type");
            wren.c.wrenAbortFiber(vm_ptr, 0);
            return error.UnknownEventType;
        };

        // Get the callback handle from slot 3
        const handle = wren.c.wrenGetSlotHandle(vm_ptr, 3) orelse {
            wren.c.wrenSetSlotString(vm_ptr, 0, "Invalid callback function");
            wren.c.wrenAbortFiber(vm_ptr, 0);
            return error.InvalidCallback;
        };

        // Register with the DOM's event registry
        const handler_id = try ctx.document.event_registry.addEventListener(
            node_id,
            event_type,
            handle,
        );

        // Store handle to prevent GC
        try ctx.event_handles.append(handle);

        return handler_id;
    }

    /// Remove an event listener
    pub fn removeEventListener(vm_ptr: *wren.c.WrenVM, ctx_ptr: *anyopaque) bool {
        const ctx: *ScriptContextWithEvents = @ptrCast(@alignCast(ctx_ptr));

        const node_id = @as(DomNodeId, @intFromFloat(wren.c.wrenGetSlotDouble(vm_ptr, 1)));

        var len: c_int = 0;
        const event_type_ptr = wren.c.wrenGetSlotBytes(vm_ptr, 2, &len);
        const event_type_str = event_type_ptr[0..@intCast(len)];

        const event_type = events.EventType.fromString(event_type_str) orelse return false;
        const handler_id = @as(u32, @intFromFloat(wren.c.wrenGetSlotDouble(vm_ptr, 3)));

        return ctx.document.event_registry.removeEventListener(node_id, event_type, handler_id);
    }
};

/// Context that includes event handling capabilities
pub const ScriptContextWithEvents = struct {
    allocator: std.mem.Allocator,
    document: *Dom,
    output: *std.ArrayList(u8),
    vm_ptr: *wren.c.WrenVM,
    event_handles: *std.ArrayList(*wren.c.WrenHandle),

    // Include the regular DOM methods
    pub const Modules = struct {
        pub const dom = struct {
            pub const DOM = struct {
                pub fn root(_: *ScriptContextWithEvents) DomNodeId {
                    return 0;
                }

                pub fn createElement(ctx: *ScriptContextWithEvents, style: []const u8) DomNodeId {
                    return ctx.document.addElement(style) catch @panic("createElement");
                }

                pub fn createText(ctx: *ScriptContextWithEvents, text: []const u8) DomNodeId {
                    return ctx.document.addText(text) catch @panic("createText");
                }

                pub fn appendChild(ctx: *ScriptContextWithEvents, parent: DomNodeId, child: DomNodeId) void {
                    ctx.document.appendChild(parent, child);
                }

                pub fn setDebugId(ctx: *ScriptContextWithEvents, id: DomNodeId, label: []const u8) void {
                    ctx.document.setDebugId(id, label) catch @panic("setDebugId");
                }

                // Event methods - these need special handling due to callbacks
                // We'll register these manually in the binding function
            };
        };
    };

    pub fn write(self: *@This(), text: []const u8) void {
        self.output.appendSlice(text) catch {};
    }

    pub fn onError(self: *@This(), error_type: wren.c.ErrorType, module: []const u8, line: c_int, message: []const u8) void {
        switch (error_type) {
            .compile => {
                std.fmt.format(self.output.writer(), "[{s} line {d}] Compile error: {s}\n", .{ module, line, message }) catch {};
            },
            .runtime => {
                std.fmt.format(self.output.writer(), "[{s} line {d}] Runtime error: {s}\n", .{ module, line, message }) catch {};
            },
            .stack_trace => {
                std.fmt.format(self.output.writer(), "  [{s} line {d}] in {s}\n", .{ module, line, message }) catch {};
            },
        }
    }
};

/// Dispatch an event to all registered handlers
pub fn dispatchEvent(
    vm: *wren.c.WrenVM,
    registry: *events.EventRegistry,
    event: events.Event,
) !void {
    // Get handlers for this event
    const handlers = registry.getHandlers(event.target, event.type) orelse return;

    // For each handler, call the Wren function
    for (handlers) |handler| {
        // Ensure we have enough slots
        wren.c.wrenEnsureSlots(vm, 2);

        // Set up the call
        wren.c.wrenSetSlotHandle(vm, 0, handler.handle);

        // Create event object in slot 1
        // For now, just pass the event type as a string
        wren.c.wrenSetSlotString(vm, 1, event.type.toString());

        // Call the handler
        const result = wren.c.wrenCall(vm, handler.handle);
        if (result != @intFromEnum(wren.c.InterpretResult.success)) {
            // Handler failed, but continue with other handlers
            std.log.warn("Event handler failed for {s}", .{event.type.toString()});
        }

        // Check if propagation was stopped
        if (event.propagation_stopped) break;
    }
}

// Tests for the event dispatch mechanism
test "Event registration through Wren interface" {
    // This test would require a full Wren VM setup, so we'll keep it simple
    // and just test the type conversions

    const test_str = "click";
    const event_type = events.EventType.fromString(test_str);
    try std.testing.expectEqual(events.EventType.click, event_type.?);
}
