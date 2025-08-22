const std = @import("std");
const vm = @import("../fiberscript/vm.zig");
const dom = @import("../dom.zig");
const c = @import("../fiberscript/wren.zig");

const Engine = vm.Engine(.{});
const SyscallContext = vm.SyscallContext;

test "sleep syscall schedules timer" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext.init(allocator, document);

    var engine = try Engine.init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    const before = std.time.milliTimestamp();
    try engine.runTopLevel("test",
        \\import "xtc" for Core
        \\var f = Fiber.new {
        \\  Core.sleep(0.1)
        \\}
        \\f.call()
    );

    try std.testing.expectEqual(@as(usize, 1), sc.sleep_timers.items.len);
    const timer = sc.sleep_timers.items[0];
    const expected: u64 = @intCast(before + 100);
    try std.testing.expect(timer.deadline_ms >= expected);

    c.wrenReleaseHandle(engine.vm, timer.fiber);
}

test "sleep resumes fiber" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext.init(allocator, document);

    var engine = try Engine.init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    try engine.runTopLevel("test",
        \\import "xtc" for Core
        \\var f = Fiber.new {
        \\  Core.sleep(0)
        \\  Core.call("print", { "message": "done\\n" })
        \\}
        \\f.call()
    );

    try @import("../main.zig").driveTimers(engine, &sc);

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("done\n", output);
}
