const std = @import("std");
const ansi = @import("ansi");

const vm = @import("fiberscript/vm.zig");
const dom = @import("dom.zig");
const c = @import("fiberscript/wren.zig");

const Engine = vm.Engine(.{});
const SyscallContext = vm.SyscallContext;

pub const version = "0.5.0";

pub const panic = ansi.panic;

comptime {
    _ = @import("test/flex.test.zig");
    _ = @import("test/element_print.test.zig");
    _ = @import("test/fs.test.zig");
    _ = @import("fiberscript/vm.zig");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var err_buf: [512]u8 = undefined;
    var err_state = std.fs.File.stderr().writer(&err_buf);
    const stderr: *std.Io.Writer = &err_state.interface;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const program = try allocator.dupe(u8, args.next() orelse "xtc");
    defer allocator.free(program);

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stderr.print("{s} v{s}\n", .{ program, version });
            try stderr.flush();
            return;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.print("Usage: {s} <file>\n", .{program});
            try stderr.flush();
            return;
        }

        if (std.mem.endsWith(u8, arg, ".wren")) {
            return run_script(allocator, arg);
        }
    }

    try stderr.print("Usage: {s} <file>\n", .{program});
    try stderr.flush();
    return error.Usage;
}

pub fn eventLoop(engine: *Engine, sc: *SyscallContext) !void {
    var args = EventLoopator{
        .engine = engine,
        .sc = sc,
    };
    _ = try args.eventLoop();
}

const EventLoopator = struct {
    engine: *Engine,
    sc: *SyscallContext,

    pub fn eventLoop(this: *@This()) !void {
        const frame_ns: u64 = std.time.ns_per_s / 60;
        var next_frame = std.time.nanoTimestamp();
        const start_ts = next_frame;

        // Optional watchdog controlled by env var XTC_WATCHDOG_SECS
        var watchdog_ns: ?u64 = null;
        if (std.process.getEnvVarOwned(this.engine.allocator, "XTC_WATCHDOG_SECS")) |val| {
            defer this.engine.allocator.free(val);
            const secs = std.fmt.parseInt(u64, val, 10) catch 0;
            if (secs > 0) watchdog_ns = secs * std.time.ns_per_s;
        } else |_| {}

        const stdin_file = std.fs.File.stdin();
        const handle = stdin_file.handle;

        const ActivityState = struct {
            const Self = @This();
            window: bool,
            sleep_timers: bool,
            frame_fibers: bool,
            key_waiters: bool,
            key_events: bool,
            http_waiters: bool,
            http_requests: bool,

            fn capture(sctx: *SyscallContext) Self {
                return .{
                    .window = sctx.window != null,
                    .sleep_timers = sctx.sleep_timers.items.len > 0,
                    .frame_fibers = sctx.frame_fibers.items.len > 0,
                    .key_waiters = sctx.key_waiters.items.len > 0,
                    .key_events = sctx.key_events.items.len > 0,
                    .http_waiters = sctx.http.hasWaiters(),
                    .http_requests = sctx.http.hasRequests(),
                };
            }

            fn equals(a: Self, b: Self) bool {
                return a.window == b.window and
                    a.sleep_timers == b.sleep_timers and
                    a.frame_fibers == b.frame_fibers and
                    a.key_waiters == b.key_waiters and
                    a.key_events == b.key_events and
                    a.http_waiters == b.http_waiters and
                    a.http_requests == b.http_requests;
            }

            fn anyActive(self: Self) bool {
                return self.window or self.sleep_timers or self.frame_fibers or self.key_waiters or self.key_events or self.http_waiters or self.http_requests;
            }

            fn debugPrint(self: Self) void {
                var buf: [2048]u8 = undefined;
                var out_state = std.fs.File.stdout().writer(&buf);
                const out: *std.Io.Writer = &out_state.interface;
                _ = out.print("EventLoop activity:", .{}) catch {};
                var any = false;
                if (self.window) {
                    _ = out.print(" window", .{}) catch {};
                    any = true;
                }
                if (self.sleep_timers) {
                    _ = out.print(" sleep_timers", .{}) catch {};
                    any = true;
                }
                if (self.frame_fibers) {
                    _ = out.print(" frame_fibers", .{}) catch {};
                    any = true;
                }
                if (self.key_waiters) {
                    _ = out.print(" key_waiters", .{}) catch {};
                    any = true;
                }
                if (self.key_events) {
                    _ = out.print(" key_events", .{}) catch {};
                    any = true;
                }
                if (self.http_waiters) {
                    _ = out.print(" http_waiters", .{}) catch {};
                    any = true;
                }
                if (self.http_requests) {
                    _ = out.print(" http_requests", .{}) catch {};
                    any = true;
                }
                if (!any) _ = out.print(" idle", .{}) catch {};
                _ = out.print("\n", .{}) catch {};
                out.flush() catch {};
            }
        };

        var prev_activity: ?ActivityState = null;

        while (true) {
            const now = std.time.nanoTimestamp();

            if (watchdog_ns) |limit| {
                if (now - start_ts >= limit) {
                    var b: [128]u8 = undefined;
                    var w = std.fs.File.stdout().writer(&b);
                    const out: *std.Io.Writer = &w.interface;
                    _ = out.print("EventLoop: watchdog timeout after {}s\n", .{limit / std.time.ns_per_s}) catch {};
                    out.flush() catch {};
                    break;
                }
            }

            if (this.sc.sleep_timers.items.len > 0) {
                var index: usize = 0;
                var earliest = this.sc.sleep_timers.items[0].deadline_ms;
                var i: usize = 1;
                while (i < this.sc.sleep_timers.items.len) : (i += 1) {
                    const t = this.sc.sleep_timers.items[i];
                    if (t.deadline_ms < earliest) {
                        earliest = t.deadline_ms;
                        index = i;
                    }
                }
                const now_ms: u64 = @intCast(@divTrunc(now, std.time.ns_per_ms));
                if (earliest <= now_ms) {
                    const timer = this.sc.sleep_timers.swapRemove(index);
                    var builder = this.engine.slots();
                    try builder.set(0, timer.fiber).call("call()").checkSuccess();
                    c.wrenReleaseHandle(this.engine.vm, timer.fiber);
                    continue;
                }
            }

            var buf: [1]u8 = undefined;
            var pfd = [1]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const poll_res = std.posix.poll(pfd[0..], 0) catch 0;
            if (poll_res > 0 and (pfd[0].revents & std.posix.POLL.IN) != 0) {
                const readn = std.posix.read(handle, buf[0..]) catch 0;
                if (readn == 1) {
                    if (this.sc.key_waiters.items.len > 0) {
                        const fiber = this.sc.key_waiters.swapRemove(this.sc.key_waiters.items.len - 1);
                        var builder = this.engine.slots();
                        _ = builder.set(0, fiber);
                        c.wrenEnsureSlots(this.engine.vm, 2);
                        c.wrenSetSlotNewMap(this.engine.vm, 1);
                        try builder.mapSet(1, "type", "keypress");
                        try builder.mapSet(1, "key", buf[0..1]);
                        try builder.call("call(_)").checkSuccess();
                        c.wrenReleaseHandle(this.engine.vm, fiber);
                    } else {
                        try this.sc.key_events.append(this.sc.allocator, buf[0]);
                    }
                }
            } else if (this.sc.key_events.items.len > 0 and this.sc.key_waiters.items.len > 0) {
                const key = this.sc.key_events.swapRemove(this.sc.key_events.items.len - 1);
                const fiber = this.sc.key_waiters.swapRemove(this.sc.key_waiters.items.len - 1);
                var builder = this.engine.slots();
                _ = builder.set(0, fiber);
                c.wrenEnsureSlots(this.engine.vm, 2);
                c.wrenSetSlotNewMap(this.engine.vm, 1);
                var k: [1]u8 = .{key};
                try builder.mapSet(1, "type", "keypress");
                try builder.mapSet(1, "key", k[0..1]);
                try builder.call("call(_)").checkSuccess();
                c.wrenReleaseHandle(this.engine.vm, fiber);
            }

            // Process HTTP timeouts then events
            {
                // Fire timeouts for head waiters
                const now_ms: u64 = @intCast(@divTrunc(now, std.time.ns_per_ms));
                var hit_timeout = true;
                while (hit_timeout) {
                    hit_timeout = false;
                    var it0 = this.sc.http.base.waiters.iterator();
                    while (it0.next()) |e0| {
                        const id0 = e0.key_ptr.*;
                        const w0 = e0.value_ptr.*;
                        if (w0.timeout_deadline_ms <= now_ms) {
                            // Remove and cancel the request, then resume fiber with error
                            if (this.sc.http.base.waiters.fetchRemove(id0)) |rem| {
                                this.sc.http.cancel(id0);
                                const fiber = rem.value.fiber;
                                var builder = this.engine.slots();
                                _ = builder.set(0, fiber);
                                c.wrenEnsureSlots(this.engine.vm, 2);
                                c.wrenSetSlotNewMap(this.engine.vm, 1);
                                try builder.mapSet(1, "type", "error");
                                try builder.mapSet(1, "id", id0);
                                try builder.mapSet(1, "message", "timeout");
                                try builder.call("call(_)").checkSuccess();
                                c.wrenReleaseHandle(this.engine.vm, fiber);
                                hit_timeout = true;
                                break;
                            }
                        }
                    }
                }

                // Fire timeouts for read waiters (treat as end-of-stream)
                var hit_timeout2 = true;
                while (hit_timeout2) {
                    hit_timeout2 = false;
                    var it1 = this.sc.http.base.waiters.iterator();
                    while (it1.next()) |e1| {
                        const id1 = e1.key_ptr.*;
                        const w1 = e1.value_ptr.*;
                        if (w1.timeout_deadline_ms <= now_ms) {
                            if (this.sc.http.base.waiters.fetchRemove(id1)) |rem| {
                                const fiber = rem.value.fiber;
                                var builder = this.engine.slots();
                                _ = builder.set(0, fiber);
                                _ = builder.set(1, "");
                                try builder.call("transfer(_)").checkSuccess();
                                c.wrenReleaseHandle(this.engine.vm, fiber);
                                hit_timeout2 = true;
                                break;
                            }
                        }
                    }
                }

                const events = this.sc.http.processEvents();

                // Process deliveries
                for (events.deliveries) |delivery| {
                    if (this.sc.http.removeWaiter(delivery.request_id)) |fiber| {
                        var builder = this.engine.slots();
                        _ = builder.set(0, fiber);

                        switch (delivery.payload) {
                            .head => |h| {
                                std.debug.print("HTTP head id={} status={}\n", .{ delivery.request_id, h.status });
                                c.wrenEnsureSlots(this.engine.vm, 2);
                                c.wrenSetSlotNewMap(this.engine.vm, 1);
                                try builder.mapSet(1, "type", "head");
                                try builder.mapSet(1, "id", delivery.request_id);
                                try builder.mapSet(1, "status", h.status);
                            },
                            .data => |chunk| {
                                std.debug.print("HTTP data id={} size={}\n", .{ delivery.request_id, chunk.len });
                                _ = builder.set(1, chunk);
                                defer this.sc.allocator.free(chunk);
                            },
                            .end => {
                                std.debug.print("HTTP end id={}\n", .{delivery.request_id});
                                _ = builder.set(1, "");
                            },
                            .@"error" => |msg| {
                                std.debug.print("HTTP error id={} msg={s}\n", .{ delivery.request_id, msg });
                                c.wrenEnsureSlots(this.engine.vm, 2);
                                c.wrenSetSlotNewMap(this.engine.vm, 1);
                                try builder.mapSet(1, "type", "error");
                                try builder.mapSet(1, "message", msg);
                                defer this.sc.allocator.free(msg);
                            },
                        }

                        try builder.call("transfer(_)").checkSuccess();
                        c.wrenReleaseHandle(this.engine.vm, fiber);
                    } else {
                        // No waiter - clean up any allocated payload
                        switch (delivery.payload) {
                            .data => |chunk| this.sc.allocator.free(chunk),
                            .@"error" => |msg| this.sc.allocator.free(msg),
                            else => {},
                        }
                    }
                }

                // Process HTTP request completions
                for (events.completions) |completion| {
                    std.debug.print("HTTP completion id={} success={}\n", .{ completion.request_id, completion.success });
                    // Remove the completed request from active requests
                    _ = this.sc.http.base.requests.remove(completion.request_id);
                }
            }

            // Check for HTTP timeouts
            {
                const timed_out_fibers = try this.sc.http.checkTimeouts(this.sc.allocator);
                defer this.sc.allocator.free(timed_out_fibers);

                for (timed_out_fibers) |fiber| {
                    var builder = this.engine.slots();
                    _ = builder.set(0, fiber);
                    _ = builder.set(1, ""); // Empty response for timeout
                    try builder.call("transfer(_)").checkSuccess();
                    c.wrenReleaseHandle(this.engine.vm, fiber);
                }
            }

            if (now >= next_frame) {
                if (this.sc.frame_fibers.items.len > 0) {
                    var i: usize = this.sc.frame_fibers.items.len;
                    while (i > 0) : (i -= 1) {
                        const fiber = this.sc.frame_fibers.swapRemove(i - 1);
                        var builder = this.engine.slots();
                        try builder.set(0, fiber).call("call()").checkSuccess();
                        c.wrenReleaseHandle(this.engine.vm, fiber);
                    }
                }
                if (this.sc.window) |w| {
                    var out_buf: [2048]u8 = undefined;
                    var out_state = std.fs.File.stdout().writer(&out_buf);
                    const out: *std.Io.Writer = &out_state.interface;
                    try w.renderAndPresent(this.sc.document, 0, out);
                    try out.flush();
                }
                next_frame += frame_ns;
            }

            // Compute activity state and log changes
            const activity = ActivityState.capture(this.sc);
            if (prev_activity) |prev| {
                if (!ActivityState.equals(prev, activity)) activity.debugPrint();
            } else {
                activity.debugPrint();
            }
            prev_activity = activity;

            if (!activity.anyActive()) break;

            std.Thread.sleep(std.time.ns_per_ms);
        }
    }
};

fn run_script(allocator: std.mem.Allocator, name: []const u8) !void {
    var err_buf2: [512]u8 = undefined;
    var err_state2 = std.fs.File.stderr().writer(&err_buf2);
    const stderr: *std.Io.Writer = &err_state2.interface;

    const file = try std.fs.cwd().openFile(name, .{});
    defer file.close();

    const script = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(script);

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext.init(allocator, document);

    const engine = try Engine.init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    defer engine.croak() catch {};
    try engine.runTopLevel(name, script);
    try eventLoop(engine, &sc);

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);
    try stderr.print("{s}", .{output});
    try stderr.flush();
}
