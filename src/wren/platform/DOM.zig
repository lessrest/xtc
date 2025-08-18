const wren = @import("../vm.zig");
const VM = wren.c.VM;
const Ctx = @import("../runtime.zig").ScriptContext;
const DomNodeId = @import("../../dom.zig").DomNodeId;
const EventType = @import("../../events.zig").EventType;
const FiberHandle = @import("../../scheduler.zig").FiberHandle;
const std = @import("std");
const Suspend = @import("../ffi_simple.zig").Suspend;

pub fn requestAnimationFrame(ctx: *Ctx, fiber: FiberHandle) !void {
    if (ctx.scheduler) |scheduler| {
        try scheduler.registerNextFrame(fiber);
        return Suspend;
    } else {
        return error.NoScheduler;
    }
}

pub fn root() DomNodeId {
    return 0;
}

pub fn viewportWidth(
    ctx: *Ctx,
) u32 {
    return @intCast(ctx.viewport_width);
}

pub fn viewportHeight(
    ctx: *Ctx,
) u32 {
    return @intCast(ctx.viewport_height);
}

pub fn createElement(
    ctx: *Ctx,
    style: []const u8,
) DomNodeId {
    return ctx.document.addElement(style) catch @panic("createElement");
}

pub fn createText(
    ctx: *Ctx,
    text: []const u8,
) DomNodeId {
    return ctx.document.addText(text) catch @panic("createText");
}

pub fn appendChild(
    ctx: *Ctx,
    parent: DomNodeId,
    child: DomNodeId,
) void {
    ctx.document.appendChild(parent, child);
}

pub fn setDebugId(
    ctx: *Ctx,
    id: DomNodeId,
    label: []const u8,
) void {
    ctx.document.setDebugId(id, label) catch @panic("setDebugId");
}

pub fn updateText(
    ctx: *Ctx,
    id: DomNodeId,
    text: []const u8,
) void {
    ctx.document.updateText(id, text) catch @panic("updateText");
}

pub fn updateClass(
    ctx: *Ctx,
    id: DomNodeId,
    class: []const u8,
) void {
    ctx.document.updateClass(id, class) catch @panic("updateClass");
}

pub fn getElementById(
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
    ctx: *Ctx,
    parent: DomNodeId,
    child: DomNodeId,
) void {
    ctx.document.removeChild(parent, child);
}

pub fn getChildCount(
    ctx: *Ctx,
    id: DomNodeId,
) u32 {
    const items = ctx.document.headers.slice();
    const content = items.items(.content)[@intCast(id)];
    return switch (content) {
        .element => |ch| ch.child_count,
        else => 0,
    };
}

pub fn getFirstChild(
    ctx: *Ctx,
    id: DomNodeId,
) DomNodeId {
    const items = ctx.document.headers.slice();
    return switch (items.items(.content)[@intCast(id)]) {
        .element => |ch| ch.first_child,
        else => std.math.maxInt(DomNodeId),
    };
}
