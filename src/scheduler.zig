const std = @import("std");
const wren = @import("wren/vm.zig");
const Trace = @import("Trace.zig").Trace;
const ScriptContext = @import("wren/runtime.zig").ScriptContext;
const Suspend = @import("wren/ffi.zig").Suspend;

pub const FiberHandle = *wren.c.Handle;

const Timer = struct { deadline_ms: i64, fiber: FiberHandle };

pub const Event = union(enum) {
    keypress: struct {
        key: []const u8,
    },
};

const FiberPriority = struct {
    pub fn compare(context: void, a: FiberHandle, b: FiberHandle) std.math.Order {
        _ = context; // autofix
        return std.math.order(@intFromPtr(a), @intFromPtr(b));
    }
};

pub const FiberQueue = std.PriorityQueue(FiberHandle, void, FiberPriority.compare);
pub const EventType = std.meta.Tag(Event);
pub const EventFibers = std.enums.EnumFieldStruct(EventType, FiberQueue, null);

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    trace: *Trace,

    next_frame: std.ArrayList(FiberHandle),
    ready: std.ArrayList(FiberHandle),
    timers: std.ArrayList(Timer),
    listeners: EventFibers,
    event_queue: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator, trace: *Trace) Scheduler {
        return .{
            .allocator = allocator,
            .trace = trace,
            .next_frame = std.ArrayList(FiberHandle).init(allocator),
            .ready = std.ArrayList(FiberHandle).init(allocator),
            .timers = std.ArrayList(Timer).init(allocator),
            .event_queue = std.ArrayList(Event).init(allocator),
            .listeners = .{
                .keypress = FiberQueue.init(allocator, {}),
            },
        };
    }

    pub fn deinit(self: *Scheduler, vm: ?*wren.c.VM) void {
        // Release all stored handles to avoid leaks
        if (vm) |v| {
            for (self.next_frame.items) |h| wren.c.wrenReleaseHandle(v, h);
            for (self.ready.items) |h| wren.c.wrenReleaseHandle(v, h);
        }
        inline for (std.meta.tags(EventType)) |event| {
            @field(self.listeners, @tagName(event)).deinit();
        }
        self.next_frame.deinit();
        self.ready.deinit();
        self.timers.deinit();
        self.event_queue.deinit();
        self.* = undefined;
    }

    // Foreign: register for next frame
    pub fn registerNextFrame(self: *Scheduler, fiber: FiberHandle) !void {
        self.trace.enter();
        defer self.trace.exit();

        self.trace.fields("register-next-frame", .{
            .total_next_frame_waiters = self.next_frame.items.len,
        });

        try self.next_frame.append(fiber);

        self.trace.info("Fiber registered for next frame");
    }

    /// Foreign: register a real timer (deadline = now + ms). Call pump() to resume.
    pub fn registerTimer(self: *Scheduler, now_ms: i64, ms: f64, fiber: FiberHandle) !void {
        self.trace.enter();
        defer self.trace.exit();

        const delta: i64 = @intFromFloat(ms);
        const deadline = now_ms + delta;

        self.trace.fields("register-timer", .{
            .now_ms = now_ms,
            .delay_ms = delta,
            .deadline_ms = deadline,
            .total_timers = self.timers.items.len,
        });

        try self.timers.append(.{ .deadline_ms = deadline, .fiber = fiber });

        self.trace.info("Timer registered");
    }

    /// Enqueue a fiber to be resumed as soon as possible
    pub fn enqueueReady(self: *Scheduler, fiber: FiberHandle) !void {
        try self.ready.append(fiber);
    }

    pub fn registerListener(self: *Scheduler, event: EventType, fiber: FiberHandle) !void {
        self.trace.enter();
        defer self.trace.exit();

        self.trace.fields("register-listener", .{
            .event = event,
            .total_listeners = @field(self.listeners, @tagName(event)).count(),
        });

        try @field(self.listeners, @tagName(event)).add(fiber);
    }

    /// Check if there are any pending fibers waiting to be processed
    pub fn hasPendingWork(self: *Scheduler) bool {
        return self.ready.items.len > 0 or
            self.next_frame.items.len > 0 or
            self.timers.items.len > 0;
    }

    pub fn animationFrame(self: *Scheduler, vm: *wren.c.VM) !usize {
        self.trace.enter();
        defer self.trace.exit();

        const ctxptr = wren.c.wrenGetUserData(vm);
        const ctx: *ScriptContext = @ptrCast(@alignCast(ctxptr));

        if (self.next_frame.items.len == 0) {
            self.trace.decision("No fibers waiting for next frame");
            return 0;
        }

        self.trace.fields("frame-presented", .{
            .waiting_fibers = self.next_frame.items.len,
        });

        // Swap out the list to avoid realloc/mutation during resume
        var drained = std.ArrayList(FiberHandle).init(self.allocator);
        // Move contents; if OOM, do nothing this frame
        try drained.appendSlice(self.next_frame.items);
        self.next_frame.clearRetainingCapacity();

        const now = std.time.microTimestamp();

        var resumed_count: usize = 0;
        for (drained.items) |fiber| {
            try ctx.callFiber(vm, fiber, now);
            _ = try self.handleYieldAndSchedule(vm, fiber);
            resumed_count += 1;
        }
        drained.deinit();

        self.trace.fields("frame-resume-complete", .{
            .resumed_fibers = resumed_count,
        });

        return resumed_count;
    }

    /// Pump due timers and ready queue; returns number of resumed fibers
    pub fn pump(self: *Scheduler, vm: *wren.c.VM, now_ms: i64, max_resumes: usize) !usize {
        self.trace.enter();
        defer self.trace.exit();

        const ctxptr = wren.c.wrenGetUserData(vm);
        const ctx: *ScriptContext = @ptrCast(@alignCast(ctxptr));

        var resumed: usize = 0;

        // Resume due timers (simple linear scan; optimize to heap later)
        var timer_resumes: usize = 0;
        var i: usize = 0;
        while (i < self.timers.items.len and resumed < max_resumes) {
            const t = self.timers.items[i];
            if (t.deadline_ms <= now_ms) {
                self.trace.fields("timer-resume", .{
                    .fiber = t.fiber,
                    .now_ms = now_ms,
                    .deadline_ms = t.deadline_ms,
                });
                _ = self.timers.swapRemove(i);
                try ctx.callFiber(vm, t.fiber, now_ms);
                _ = try self.handleYieldAndSchedule(vm, t.fiber);
                resumed += 1;
                timer_resumes += 1;
                continue; // don't i+=1 because we swapped
            }
            i += 1;
        }

        // Ready queue support (if used): resume immediately
        var ready_resumes: usize = 0;
        while (resumed < max_resumes) {
            if (self.ready.pop()) |fiber| {
                self.trace.fields("resuming-immediate-fiber", .{
                    .fiber = fiber,
                    .now_ms = now_ms,
                });
                try ctx.callFiber(vm, fiber, now_ms);
                self.trace.info("resumed immediate fiber");
                _ = try self.handleYieldAndSchedule(vm, fiber);
                resumed += 1;
                ready_resumes += 1;
            } else {
                break;
            }
        }

        return resumed;
    }

    pub fn enqueueEvent(self: *Scheduler, event: Event) !void {
        try self.event_queue.append(event);
    }

    pub fn pumpEvents(self: *Scheduler, vm: *wren.c.VM) !usize {
        var resumed: usize = 0;

        while (self.event_queue.pop()) |event| {
            resumed += try self.dispatchEvent(vm, event);
        }

        return resumed;
    }

    pub fn dispatchEvent(self: *Scheduler, vm: *wren.c.VM, event: Event) !usize {
        const ctxptr = wren.c.wrenGetUserData(vm);
        const ctx: *ScriptContext = @ptrCast(@alignCast(ctxptr));

        var listeners = &@field(self.listeners, @tagName(event));

        // first, move all listeners
        var drained = std.ArrayList(FiberHandle).init(self.allocator);
        try drained.appendSlice(listeners.items);
        listeners.clearRetainingCapacity();

        var resumed: usize = 0;
        for (drained.items) |fiber| {
            self.trace.fields("dispatching-event", .{
                .fiber = fiber,
                .event = event,
            });
            try ctx.callFiber(vm, fiber, event);
            _ = try self.handleYieldAndSchedule(vm, fiber);
            resumed += 1;
        }

        return resumed;
    }

    /// Inspect the value in slot 0 after resuming a fiber and schedule based on
    /// yielded request tuples. Returns true if the fiber handle is retained for
    /// future resumption, false if released (i.e., fiber completed).
    fn handleYieldAndSchedule(self: *Scheduler, vm: *wren.c.VM, fiber: FiberHandle) !bool {
        var steps: usize = 0;

        const ctxptr = wren.c.wrenGetUserData(vm);
        const ctx: *ScriptContext = @ptrCast(@alignCast(ctxptr));

        while (steps < 1024 * 256) : (steps += 1) {
            // Ensure we have at least one slot available
            wren.c.wrenEnsureSlots(vm, 1);
            self.trace.fields("handleYieldAndSchedule", .{
                .steps = steps,
            });
            // Check if slot 0 has a valid value
            if (wren.c.wrenGetSlotCount(vm) < 1) {
                self.trace.decision("No slots available -> treat as completion");
                wren.c.wrenReleaseHandle(vm, fiber);
                return false;
            }

            const ty: wren.c.Type = @enumFromInt(wren.c.wrenGetSlotType(vm, 0));

            if (ty != .list) {
                self.trace.decision("Not a request list -> treat as completion");
                // Not a request list -> treat as completion
                wren.c.wrenReleaseHandle(vm, fiber);
                return false;
            }

            wren.c.wrenEnsureSlots(vm, 3);

            const key_slot = 1;
            const arglist_slot = 2;

            wren.c.wrenGetListElement(vm, 0, 0, key_slot);
            wren.c.wrenGetListElement(vm, 0, 1, arglist_slot);

            const key_type = @as(wren.c.Type, @enumFromInt(wren.c.wrenGetSlotType(vm, key_slot)));
            const arglist_type = @as(wren.c.Type, @enumFromInt(wren.c.wrenGetSlotType(vm, arglist_slot)));

            if (key_type == .num and arglist_type == .list) {
                // [function, [arg1, arg2, ...]]
                const fid = @as(usize, @intFromFloat(wren.c.wrenGetSlotDouble(vm, key_slot)));

                const functions = wren.ScriptEngine.foreign_functions;
                const target_fn = functions[fid];

                const arg_count_total: usize = @intCast(wren.c.wrenGetListCount(vm, arglist_slot));

                const arity: usize = arg_count_total;
                if (arity != target_fn.arity) {
                    try ctx.rejectFiber(vm, fiber, "Invalid argument list");
                    return false;
                }

                // Call the function directly
                self.trace.fields("ffi-function", .{
                    .function_id = fid,
                    .arity = arity,
                    .name = target_fn.name,
                });

                target_fn.func(vm, ctx, arglist_slot) catch |err| {
                    if (err == Suspend) {
                        self.trace.info("ffi-function-suspended");
                        return true;
                    }

                    self.trace.fields("ffi-function-error", .{
                        .@"error" = @errorName(err),
                    });

                    try ctx.rejectFiber(vm, fiber, @errorName(err));
                    return false;
                };

                self.trace.info("ffi-function-called");

                // Resume fiber with return in slot 0
                self.trace.decision("calling fiber again");
                try ctx.callFiberWithReturnAlreadyInSlot1(vm, fiber);
                continue;
            }

            wren.c.wrenReleaseHandle(vm, fiber);
            return false;
        }

        std.debug.panic("too many chained syscalls", .{});
    }
};
