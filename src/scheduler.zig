const std = @import("std");
const wren = @import("wren/vm.zig");
const CallBuilder = @import("wren/CallBuilder.zig").CallBuilder;
const events = @import("events.zig");
const dom = @import("dom.zig");
const Trace = @import("Trace.zig").Trace;

pub const FiberHandle = *wren.c.Handle;

const Timer = struct { deadline_ms: i64, fiber: FiberHandle };

fn awaitKey(node: dom.DomNodeId, et: events.EventType) u64 {
    // Pack two 32-bit values into a 64-bit key
    return (@as(u64, @intCast(node)) << 32) | @as(u64, @intCast(@intFromEnum(et)));
}

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    trace: *Trace,

    // (node,event) -> list of waiting fibers
    awaiters: std.AutoHashMap(u64, std.ArrayList(FiberHandle)),

    // Fibers to resume after next present()
    next_frame: std.ArrayList(FiberHandle),

    // Ready-to-run fibers (resume immediately)
    ready: std.ArrayList(FiberHandle),
    timers: std.ArrayList(Timer),

    pub fn init(allocator: std.mem.Allocator, trace: *Trace) Scheduler {
        return .{
            .allocator = allocator,
            .trace = trace,
            .awaiters = std.AutoHashMap(u64, std.ArrayList(FiberHandle)).init(allocator),
            .next_frame = std.ArrayList(FiberHandle).init(allocator),
            .ready = std.ArrayList(FiberHandle).init(allocator),
            .timers = std.ArrayList(Timer).init(allocator),
        };
    }

    pub fn deinit(self: *Scheduler, vm: ?*wren.c.VM) void {
        // Release all stored handles to avoid leaks
        if (vm) |v| {
            var it = self.awaiters.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.items) |h| wren.c.wrenReleaseHandle(v, h);
                entry.value_ptr.deinit();
            }
            for (self.next_frame.items) |h| wren.c.wrenReleaseHandle(v, h);
            for (self.ready.items) |h| wren.c.wrenReleaseHandle(v, h);
        } else {
            var it2 = self.awaiters.iterator();
            while (it2.next()) |entry| entry.value_ptr.deinit();
        }
        self.awaiters.deinit();
        self.next_frame.deinit();
        self.ready.deinit();
        self.timers.deinit();
        self.* = undefined;
    }

    // Foreign: register an awaiter on (node,event)
    pub fn registerWait(self: *Scheduler, node: dom.DomNodeId, et: events.EventType, fiber: FiberHandle) !void {
        const k = awaitKey(node, et);
        const g = try self.awaiters.getOrPut(k);
        if (!g.found_existing) {
            g.value_ptr.* = std.ArrayList(FiberHandle).init(self.allocator);
        }
        try g.value_ptr.append(fiber);
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

    /// Check if there are any pending fibers waiting to be processed
    pub fn hasPendingWork(self: *Scheduler) bool {
        return self.ready.items.len > 0 or
            self.next_frame.items.len > 0 or
            self.timers.items.len > 0 or
            self.awaiters.count() > 0;
    }

    // Internal: resume a fiber with a prebuilt map in slot 1
    fn resumeWithSlot1Map(vm: *wren.c.VM, fiber: FiberHandle) !void {
        var cb = CallBuilder.init(vm);
        cb.ensureSlots(2);
        try cb.callFiber(fiber, 1);
    }

    // Helper: set simple key->value string in map at slot 1
    fn mapPutStr(vm: *wren.c.VM, key: [:0]const u8, val: []const u8) void {
        wren.c.wrenSetSlotString(vm, 0, key);
        wren.c.wrenSetSlotBytes(vm, 1, val.ptr, val.len);
    }

    // Post a general event to awaiters
    pub fn postEvent(self: *Scheduler, vm: *wren.c.VM, ev: events.Event) !void {
        const k = awaitKey(ev.target, ev.type);
        const g = self.awaiters.getPtr(k) orelse return;

        // Move out the list to avoid resuming and mutating same list
        var list = std.ArrayList(FiberHandle).init(self.allocator);
        list.appendSlice(g.items) catch {};
        g.clearRetainingCapacity();

        // Build event map once per fiber (slots are reused per call)
        for (list.items) |fiber| {
            var cb = CallBuilder.init(vm);
            cb.ensureSlots(2);
            cb.beginMap(1);
            cb.mapPutStr(1, "type", ev.type.toString());
            cb.mapPutNum(1, "target", @floatFromInt(ev.target));
            if (ev.key) |kstr| cb.mapPutStr(1, "key", kstr);
            if (ev.mouse_x) |mx| cb.mapPutNum(1, "x", @floatFromInt(mx));
            if (ev.mouse_y) |my| cb.mapPutNum(1, "y", @floatFromInt(my));
            cb.mapPutNum(1, "timestamp", @floatFromInt(ev.timestamp));

            // resume
            try resumeWithSlot1Map(vm, fiber);
            // process yielded request or completion
            _ = try self.handleYieldAndSchedule(vm, fiber);
        }

        list.deinit();
    }

    pub fn animationFrame(self: *Scheduler, vm: *wren.c.VM) !usize {
        self.trace.enter();
        defer self.trace.exit();

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

        var resumed_count: usize = 0;
        for (drained.items) |fiber| {
            wren.c.wrenEnsureSlots(vm, 2);
            wren.c.wrenSetSlotNewMap(vm, 1);
            try resumeWithSlot1Map(vm, fiber);
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
                wren.c.wrenEnsureSlots(vm, 2);
                wren.c.wrenSetSlotNewMap(vm, 1);
                try resumeWithSlot1Map(vm, t.fiber);
                _ = try self.handleYieldAndSchedule(vm, t.fiber);
                resumed += 1;
                timer_resumes += 1;
                continue; // don't i+=1 because we swapped
            }
            i += 1;
        }

        // Ready queue support (if used): resume immediately
        var ready_resumes: usize = 0;
        while (resumed < max_resumes and self.ready.items.len > 0) {
            const fiber = self.ready.pop();
            self.trace.fields("ready-resume", .{
                .fiber = fiber,
                .now_ms = now_ms,
            });
            wren.c.wrenEnsureSlots(vm, 2);
            wren.c.wrenSetSlotNewMap(vm, 1);
            try resumeWithSlot1Map(vm, fiber.?);
            _ = try self.handleYieldAndSchedule(vm, fiber.?);
            resumed += 1;
            ready_resumes += 1;
        }

        return resumed;
    }

    /// Inspect the value in slot 0 after resuming a fiber and schedule based on
    /// yielded request tuples. Returns true if the fiber handle is retained for
    /// future resumption, false if released (i.e., fiber completed).
    fn handleYieldAndSchedule(self: *Scheduler, vm: *wren.c.VM, fiber: FiberHandle) !bool {
        var steps: usize = 0;
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

            wren.c.wrenEnsureSlots(vm, 4);
            // key at index 0
            wren.c.wrenGetListElement(vm, 0, 0, 1);

            const key_type = @as(wren.c.Type, @enumFromInt(wren.c.wrenGetSlotType(vm, 1)));
            if (key_type == .string) {
                var key_len: c_int = 0;
                const key_ptr = wren.c.wrenGetSlotBytes(vm, 1, &key_len);
                const key = key_ptr[0..@intCast(key_len)];
                self.trace.fields("key", .{ .key = key });

                // Scheduling requests
                if (std.mem.eql(u8, key, "wait")) {
                    // ["wait", nodeId, type]
                    wren.c.wrenGetListElement(vm, 0, 1, 2);
                    const node_d = wren.c.wrenGetSlotDouble(vm, 2);
                    wren.c.wrenGetListElement(vm, 0, 2, 2);
                    var et_len: c_int = 0;
                    const et_ptr = wren.c.wrenGetSlotBytes(vm, 2, &et_len);
                    const et_slice = et_ptr[0..@intCast(et_len)];
                    const et = events.EventType.fromString(et_slice) orelse {
                        wren.c.wrenReleaseHandle(vm, fiber);
                        return false;
                    };
                    self.registerWait(@intFromFloat(node_d), et, fiber) catch {};
                    return true;
                }
                if (std.mem.eql(u8, key, "frame")) {
                    self.registerNextFrame(fiber) catch {};
                    return true;
                }
                if (std.mem.eql(u8, key, "sleep")) {
                    wren.c.wrenGetListElement(vm, 0, 1, 2);
                    const ms = wren.c.wrenGetSlotDouble(vm, 2);
                    const now = std.time.milliTimestamp();
                    self.registerTimer(now, ms, fiber) catch {};
                    return true;
                } else {
                    self.trace.decision("Unknown syscall key");
                    self.trace.fields("unknown-syscall-key", .{
                        .key = key,
                    });
                    wren.c.wrenReleaseHandle(vm, fiber);
                    return false;
                }
            } else if (key_type == .num) {

                // Index-based ffi: key == 1 (num) -> [1, flat_function_id, ...args]
                if (wren.c.wrenGetSlotDouble(vm, 1) == 1) {
                    // Read id
                    wren.c.wrenGetListElement(vm, 0, 1, 1);
                    const fid = @as(usize, @intFromFloat(wren.c.wrenGetSlotDouble(vm, 1)));

                    // Lookup in function registry by flat index
                    const Ctx = @import("wren/runtime.zig").ScriptContext;
                    const functions = wren.ScriptEngine(Ctx).foreign_functions;
                    if (fid >= functions.len) {
                        wren.c.wrenReleaseHandle(vm, fiber);
                        return false;
                    }
                    const target_fn = functions[fid];

                    const arg_count_total: usize = @intCast(wren.c.wrenGetListCount(vm, 0));
                    if (arg_count_total < 2) {
                        wren.c.wrenReleaseHandle(vm, fiber);
                        return false;
                    }
                    const arity: usize = arg_count_total - 2;
                    if (arity != target_fn.arity) {
                        wren.c.wrenReleaseHandle(vm, fiber);
                        return false;
                    }

                    // Place args into slots
                    wren.c.wrenEnsureSlots(vm, @intCast(arity + 1));
                    var ai: usize = 0;
                    while (ai < arity) : (ai += 1) {
                        wren.c.wrenGetListElement(vm, 0, @intCast(ai + 2), @intCast(ai + 1));
                    }

                    // Call the function directly
                    self.trace.fields("ffi-function", .{
                        .function_id = fid,
                        .arity = arity,
                        .name = target_fn.name,
                    });
                    target_fn.func(vm);
                    self.trace.info("ffi-function-called");

                    // Resume fiber with return in slot 0
                    const ret_ty: wren.c.Type = @enumFromInt(wren.c.wrenGetSlotType(vm, 0));
                    wren.c.wrenEnsureSlots(vm, 3);
                    switch (ret_ty) {
                        .num => wren.c.wrenSetSlotDouble(vm, 2, wren.c.wrenGetSlotDouble(vm, 0)),
                        .bool => wren.c.wrenSetSlotBool(vm, 2, wren.c.wrenGetSlotBool(vm, 0)),
                        .string => {
                            var rlen: c_int = 0;
                            const rptr = wren.c.wrenGetSlotBytes(vm, 0, &rlen);
                            wren.c.wrenSetSlotBytes(vm, 2, rptr, @intCast(rlen));
                        },
                        .null => wren.c.wrenSetSlotNull(vm, 2),
                        else => wren.c.wrenSetSlotNull(vm, 2),
                    }
                    wren.c.wrenSetSlotHandle(vm, 0, fiber);
                    switch (ret_ty) {
                        .num => wren.c.wrenSetSlotDouble(vm, 1, wren.c.wrenGetSlotDouble(vm, 2)),
                        .bool => wren.c.wrenSetSlotBool(vm, 1, wren.c.wrenGetSlotBool(vm, 2)),
                        .string => {
                            var tlen: c_int = 0;
                            const tptr = wren.c.wrenGetSlotBytes(vm, 2, &tlen);
                            wren.c.wrenSetSlotBytes(vm, 1, tptr, @intCast(tlen));
                        },
                        .null => wren.c.wrenSetSlotNull(vm, 1),
                        else => wren.c.wrenSetSlotNull(vm, 1),
                    }

                    self.trace.decision("calling fiber again");
                    const ch = wren.c.wrenMakeCallHandle(vm, "call(_)") orelse {
                        self.trace.info("failed to make call handle");
                        wren.c.wrenReleaseHandle(vm, fiber);
                        return false;
                    };
                    defer wren.c.wrenReleaseHandle(vm, ch);
                    const result = @as(wren.c.InterpretResult, @enumFromInt(wren.c.wrenCall(vm, ch)));
                    switch (result) {
                        .success => {
                            self.trace.info("call succeeded");
                        },
                        .compile_error => {
                            std.debug.panic("compile error in fiber call", .{});
                        },
                        .runtime_error => {
                            self.trace.info("runtime error in fiber call");
                            return error.RuntimeError;
                        },
                    }
                    continue;
                }
            }

            wren.c.wrenReleaseHandle(vm, fiber);
            return false;
        }

        std.debug.panic("too many chained syscalls", .{});
    }
};
