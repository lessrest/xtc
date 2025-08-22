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

pub fn driveTimers(engine: *Engine, sc: *SyscallContext) !void {
    while (sc.sleep_timers.items.len > 0) {
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
        const now: u64 = @intCast(std.time.milliTimestamp());
        if (earliest > now) {
            std.time.sleep((earliest - now) * std.time.ns_per_ms);
        }
        const timer = sc.sleep_timers.swapRemove(index);
        var builder = engine.slots();
        try builder.set(0, timer.fiber).call("call()").checkSuccess();
        c.wrenReleaseHandle(engine.vm, timer.fiber);
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
    try driveTimers(engine, &sc);

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);
    try stderr.print("{s}", .{output});
}
