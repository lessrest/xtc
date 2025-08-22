const std = @import("std");
const vm = @import("../fiberscript/vm.zig");
const dom = @import("../dom.zig");

const SyscallContext = vm.SyscallContext;
const Engine = vm.Engine(.{});

test "Element#print prints the element's region" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine.init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    const script =
        \\import "dom" for Document, Element
        \\var a = Element.create("w-4 h-3 bg-glyph-[a]")
        \\var b = Element.create("w-4 h-3 bg-glyph-[b]")
        \\Document.root.classes = "flex flex-row items-start"
        \\Document.root.append(a)
        \\Document.root.append(b)
        \\b.print()
    ;

    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);

    const stdout_backup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_backup);

    try std.posix.dup2(pipes[1], std.posix.STDOUT_FILENO);
    std.posix.close(pipes[1]);

    try engine.runTopLevel("main", script);

    try std.posix.dup2(stdout_backup, std.posix.STDOUT_FILENO);

    var buf: [1024]u8 = undefined;
    const n = try std.posix.read(pipes[0], &buf);
    const output = buf[0..n];

    try std.testing.expectEqualStrings("bbbb\nbbbb\nbbbb\n", output);
}
