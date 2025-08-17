const wren = @import("../vm.zig");
const VM = wren.c.VM;
const Ctx = @import("../runtime.zig").ScriptContext;
const DomNodeId = @import("../../dom.zig").DomNodeId;
const EventType = @import("../../events.zig").EventType;
const std = @import("std");

pub fn root(_: *VM, _: *Ctx) DomNodeId {
    return 0;
}

pub fn viewportWidth(_: *VM, ctx: *Ctx) u32 {
    return @intCast(ctx.viewport_width);
}

pub fn viewportHeight(_: *VM, ctx: *Ctx) u32 {
    return @intCast(ctx.viewport_height);
}

pub fn createElement(_: *VM, ctx: *Ctx, style: []const u8) DomNodeId {
    return ctx.document.addElement(style) catch @panic("createElement");
}

pub fn createText(_: *VM, ctx: *Ctx, text: []const u8) DomNodeId {
    return ctx.document.addText(text) catch @panic("createText");
}

pub fn createClock(_: *VM, ctx: *Ctx, style: []const u8) DomNodeId {
    const node_id = ctx.document.addClock(style) catch @panic("createClock");
    return node_id;
}

pub fn appendChild(
    _: *VM,
    ctx: *Ctx,
    parent: DomNodeId,
    child: DomNodeId,
) void {
    ctx.document.appendChild(parent, child);
}

pub fn setDebugId(
    _: *VM,
    ctx: *Ctx,
    id: DomNodeId,
    label: []const u8,
) void {
    ctx.document.setDebugId(id, label) catch @panic("setDebugId");
}

pub fn updateText(
    _: *VM,
    ctx: *Ctx,
    id: DomNodeId,
    text: []const u8,
) void {
    ctx.document.updateText(id, text) catch @panic("updateText");
}

pub fn updateClass(
    _: *VM,
    ctx: *Ctx,
    id: DomNodeId,
    class: []const u8,
) void {
    ctx.document.updateClass(id, class) catch @panic("updateClass");
}

pub fn getElementById(
    _: *VM,
    ctx: *Ctx,
    idStr: []const u8,
) DomNodeId {
    // Search through debug_ids HashMap to find matching ID
    var it = ctx.document.debug_ids.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, idStr)) {
            return entry.key_ptr.*;
        }
    }
    return std.math.maxInt(DomNodeId); // Return invalid ID if not found
}

pub fn removeChild(
    _: *VM,
    ctx: *Ctx,
    parent: DomNodeId,
    child: DomNodeId,
) void {
    ctx.document.removeChild(parent, child);
}

pub fn getChildCount(_: *VM, ctx: *Ctx, id: DomNodeId) u32 {
    const items = ctx.document.headers.slice();
    const content = items.items(.content)[@intCast(id)];
    return switch (content) {
        .element => |ch| ch.child_count,
        else => 0,
    };
}

pub fn getFirstChild(_: *VM, ctx: *Ctx, id: DomNodeId) DomNodeId {
    const items = ctx.document.headers.slice();
    return switch (items.items(.content)[@intCast(id)]) {
        .element => |ch| ch.first_child,
        else => std.math.maxInt(DomNodeId),
    };
}

pub fn addEventListener(
    vm: *VM,
    ctx: *Ctx,
    node_id: DomNodeId,
    event_type_str: []const u8,
    handler: *wren.c.Handle,
) u32 {
    const event_type = EventType.fromString(event_type_str) orelse {
        wren.c.wrenSetSlotString(vm, 0, "Unknown event type");
        wren.c.wrenAbortFiber(vm, 0);
        return 0;
    };

    const handler_id = ctx.document.event_registry.addEventListener(
        node_id,
        event_type,
        handler,
    ) catch {
        wren.c.wrenSetSlotString(vm, 0, "Failed to add event listener");
        wren.c.wrenAbortFiber(vm, 0);
        return 0;
    };

    ctx.event_handles.append(handler) catch {
        wren.c.wrenSetSlotString(vm, 0, "Failed to store event handle");
        wren.c.wrenAbortFiber(vm, 0);
        return 0;
    };

    return handler_id;
}

pub fn removeEventListener(
    _: *VM,
    ctx: *Ctx,
    node_id: DomNodeId,
    event_type_str: []const u8,
    handler_id: u32,
) bool {
    const event_type = EventType.fromString(event_type_str) orelse return false;
    return ctx.document.event_registry.removeEventListener(node_id, event_type, handler_id);
}
