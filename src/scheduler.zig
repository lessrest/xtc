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

    // Internal: resume a fiber with a prebuilt map in slot 1
    fn resumeWithSlot1Map(vm: *wren.c.VM, fiber: FiberHandle) void {
        var cb = CallBuilder.init(vm);
        cb.ensureSlots(2);
        cb.callFiber(fiber, 1);
    }

    // Helper: set simple key->value string in map at slot 1
    fn mapPutStr(vm: *wren.c.VM, key: [:0]const u8, val: []const u8) void {
        wren.c.wrenSetSlotString(vm, 0, key);
        wren.c.wrenSetSlotBytes(vm, 1, val.ptr, val.len);
    }

    // Post a general event to awaiters
    pub fn postEvent(self: *Scheduler, vm: *wren.c.VM, ev: events.Event) void {
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
            resumeWithSlot1Map(vm, fiber);
            // release handle after resumption
            wren.c.wrenReleaseHandle(vm, fiber);
        }

        list.deinit();
    }

    pub fn animationFrame(self: *Scheduler, vm: *wren.c.VM) usize {
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
        if (drained.appendSlice(self.next_frame.items)) |_| {
            // ok
        } else |_| {
            self.trace.decision("OOM during fiber drain, skipping frame");
            drained.deinit();
            return 0;
        }
        self.next_frame.clearRetainingCapacity();

        var resumed_count: usize = 0;
        for (drained.items) |fiber| {
            wren.c.wrenEnsureSlots(vm, 2);
            wren.c.wrenSetSlotNewMap(vm, 1);
            resumeWithSlot1Map(vm, fiber);
            wren.c.wrenReleaseHandle(vm, fiber);
            resumed_count += 1;
        }
        drained.deinit();

        self.trace.fields("frame-resume-complete", .{
            .resumed_fibers = resumed_count,
        });

        return resumed_count;
    }

    /// Pump due timers and ready queue; returns number of resumed fibers
    pub fn pump(self: *Scheduler, vm: *wren.c.VM, now_ms: i64, max_resumes: usize) usize {
        self.trace.enter();
        defer self.trace.exit();

        var resumed: usize = 0;
        const initial_timers = self.timers.items.len;
        const initial_ready = self.ready.items.len;

        self.trace.fields("pump-start", .{
            .now_ms = now_ms,
            .max_resumes = max_resumes,
            .pending_timers = initial_timers,
            .ready_fibers = initial_ready,
        });

        // Resume due timers (simple linear scan; optimize to heap later)
        var timer_resumes: usize = 0;
        var i: usize = 0;
        while (i < self.timers.items.len and resumed < max_resumes) {
            const t = self.timers.items[i];
            if (t.deadline_ms <= now_ms) {
                // Remove by swap
                _ = self.timers.swapRemove(i);
                wren.c.wrenEnsureSlots(vm, 2);
                wren.c.wrenSetSlotNewMap(vm, 1);
                resumeWithSlot1Map(vm, t.fiber);
                wren.c.wrenReleaseHandle(vm, t.fiber);
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
            wren.c.wrenEnsureSlots(vm, 2);
            wren.c.wrenSetSlotNewMap(vm, 1);
            resumeWithSlot1Map(vm, fiber.?);
            wren.c.wrenReleaseHandle(vm, fiber.?);
            resumed += 1;
            ready_resumes += 1;
        }

        self.trace.fields("pump-complete", .{
            .timer_resumes = timer_resumes,
            .ready_resumes = ready_resumes,
            .total_resumed = resumed,
            .remaining_timers = self.timers.items.len,
            .remaining_ready = self.ready.items.len,
        });

        return resumed;
    }
};
