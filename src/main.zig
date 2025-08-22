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
    _ = @import("fiberscript/vm.zig");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var stderr = std.io.getStdErr().writer();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const program = try allocator.dupe(u8, args.next() orelse "xtc");
    defer allocator.free(program);

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stderr.print("{s} v{s}\n", .{ program, version });
            return;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.print("Usage: {s} <file>\n", .{program});
            return;
        }

        if (std.mem.endsWith(u8, arg, ".wren")) {
            return run_script(allocator, arg);
        }
    }

    try stderr.print("Usage: {s} <file>\n", .{program});
    return error.Usage;
}

pub fn eventLoop(engine: *Engine, sc: *SyscallContext) !void {
    const frame_ns: u64 = std.time.ns_per_s / 60;
    var next_frame = std.time.nanoTimestamp();

    const stdin_file = std.io.getStdIn();
    const handle = stdin_file.handle;

    while (true) {
        const now = std.time.nanoTimestamp();

        if (sc.sleep_timers.items.len > 0) {
            var index: usize = 0;
            var earliest = sc.sleep_timers.items[0].deadline_ms;
            var i: usize = 1;
            while (i < sc.sleep_timers.items.len) : (i += 1) {
                const t = sc.sleep_timers.items[i];
                if (t.deadline_ms < earliest) {
                    earliest = t.deadline_ms;
                    index = i;
                }
            }
            const now_ms: u64 = @intCast(@divTrunc(now, std.time.ns_per_ms));
            if (earliest <= now_ms) {
                const timer = sc.sleep_timers.swapRemove(index);
                var builder = engine.slots();
                try builder.set(0, timer.fiber).call("call()").checkSuccess();
                c.wrenReleaseHandle(engine.vm, timer.fiber);
                continue;
            }
        }

        var buf: [1]u8 = undefined;
        var pfd = [1]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const poll_res = std.posix.poll(pfd[0..], 0) catch 0;
        if (poll_res > 0 and (pfd[0].revents & std.posix.POLL.IN) != 0) {
            const readn = std.posix.read(handle, buf[0..]) catch 0;
            if (readn == 1) {
                if (sc.key_waiters.items.len > 0) {
                    const fiber = sc.key_waiters.swapRemove(sc.key_waiters.items.len - 1);
                    var builder = engine.slots();
                    _ = builder.set(0, fiber);
                    c.wrenEnsureSlots(engine.vm, 2);
                    c.wrenSetSlotNewMap(engine.vm, 1);
                    try builder.mapSet(1, "type", "keypress");
                    try builder.mapSet(1, "key", buf[0..1]);
                    try builder.call("call(_)").checkSuccess();
                    c.wrenReleaseHandle(engine.vm, fiber);
                } else {
                    try sc.key_events.append(sc.allocator, buf[0]);
                }
            }
        } else if (sc.key_events.items.len > 0 and sc.key_waiters.items.len > 0) {
            const key = sc.key_events.swapRemove(sc.key_events.items.len - 1);
            const fiber = sc.key_waiters.swapRemove(sc.key_waiters.items.len - 1);
            var builder = engine.slots();
            _ = builder.set(0, fiber);
            c.wrenEnsureSlots(engine.vm, 2);
            c.wrenSetSlotNewMap(engine.vm, 1);
            var k: [1]u8 = .{key};
            try builder.mapSet(1, "type", "keypress");
            try builder.mapSet(1, "key", k[0..1]);
            try builder.call("call(_)").checkSuccess();
            c.wrenReleaseHandle(engine.vm, fiber);
        }

        if (now >= next_frame) {
            if (sc.frame_fibers.items.len > 0) {
                var i: usize = sc.frame_fibers.items.len;
                while (i > 0) : (i -= 1) {
                    const fiber = sc.frame_fibers.swapRemove(i - 1);
                    var builder = engine.slots();
                    try builder.set(0, fiber).call("call()").checkSuccess();
                    c.wrenReleaseHandle(engine.vm, fiber);
                }
            }
            if (sc.window) |w| {
                const stdout_writer = std.io.getStdOut().writer();
                try w.renderAndPresent(sc.document, 0, stdout_writer);
            }
            next_frame += frame_ns;
        }

        if (sc.window == null and sc.sleep_timers.items.len == 0 and sc.frame_fibers.items.len == 0 and sc.key_waiters.items.len == 0 and sc.key_events.items.len == 0) {
            break;
        }

        std.time.sleep(std.time.ns_per_ms);
    }
}

fn run_script(allocator: std.mem.Allocator, name: []const u8) !void {
    var stderr = std.io.getStdErr().writer();

    const file = try std.fs.cwd().openFile(name, .{});
    defer file.close();

    const script = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(script);

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    const engine = try Engine.init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    defer engine.croak() catch {};
    try engine.runTopLevel(name, script);
    try eventLoop(engine, &sc);

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);
    try stderr.print("{s}", .{output});
}
