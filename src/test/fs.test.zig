const std = @import("std");
const vm = @import("../fiberscript/vm.zig");
const dom = @import("../dom.zig");

const Engine = vm.Engine(.{});
const SyscallContext = vm.SyscallContext;

test "fs exists and remove" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext.init(allocator, document);

    var engine = try Engine.init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    try engine.runTopLevel("test",
        \\import "fs" for Path
        \\import "xtc" for Core
        \\import "syscall" for Print
        \\var tmp = Path.cwd().join("tmp.txt")
        \\tmp.write("hi")
        \\var ex1 = tmp.exists()
        \\tmp.remove()
        \\var ex2 = tmp.exists()
        \\Core.call(Print.new("%(ex1) %(ex2)\n"))
    );

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("true false\n", output);
}
