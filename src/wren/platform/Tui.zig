const std = @import("std");
const wren = @import("../vm.zig");
const Ctx = @import("../runtime.zig").ScriptContext;
const scheduler_mod = @import("../../scheduler.zig");
const events = @import("../../events.zig");
const dom = @import("../../dom.zig");

pub fn registerWait(
    vm: *wren.c.VM,
    ctx: *Ctx,
    node: dom.DomNodeId,
    event_type_str: []const u8,
    fiber: *wren.c.Handle,
) void {
    _ = vm;
    const event_type = events.EventType.fromString(event_type_str) orelse return;
    if (ctx.*.scheduler) |sch| {
        sch.registerWait(node, event_type, fiber) catch {};
    }
}

pub fn registerNextFrame(vm: *wren.c.VM, ctx: *Ctx, fiber: *wren.c.Handle) void {
    _ = vm;
    if (ctx.*.scheduler) |sch| {
        sch.registerNextFrame(fiber) catch {};
    }
}

pub fn registerTimer(_: *wren.c.VM, ctx: *Ctx, ms: f64, fiber: *wren.c.Handle) void {
    if (ctx.*.scheduler) |sch| {
        const now = std.time.milliTimestamp();
        sch.registerTimer(now, ms, fiber) catch {};
    }
}

pub fn enqueue(_: *wren.c.VM, ctx: *Ctx, fiber: *wren.c.Handle) void {
    if (ctx.*.scheduler) |sch| {
        sch.enqueueReady(fiber) catch {};
    }
}
