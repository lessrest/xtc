const std = @import("std");
const vm = @import("../fiberscript/vm.zig");
const dom = @import("../dom.zig");

const Engine = vm.Engine(.{});
const SyscallContext = vm.SyscallContext;

test "fs read write and list" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine.init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "sample.txt" });
    defer allocator.free(file_path);

    const script = try std.fmt.allocPrint(
        allocator,
        \\import "fs" for FS
        \\var p = "{s}"
        \\FS.write(p, "hi")
        \\System.print(FS.read(p))
        \\System.print(FS.list("{s}").contains("sample.txt"))
    ,
        .{ file_path, dir_path },
    );
    defer allocator.free(script);

    try engine.runTopLevel("test", script);

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("hi\ntrue\n", output);
}
