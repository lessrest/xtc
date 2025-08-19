const std = @import("std");
const ansi = @import("./libansi.zig");
const tree = ansi.nest;
const getContext = std.debug.getContext;
const StackIterator = std.debug.StackIterator;

pub export fn zig_abort() noreturn {
    do_abort(@returnAddress()) catch std.debug.panic("Failed to dump stack trace", .{});
    std.posix.exit(1);
}

pub fn do_abort(start_addr: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var nest = tree.treeNest(arena.allocator(), std.io.getStdErr().writer());

    //    nosuspend try ansi.dumpFuckItAllTrace(&nest, start_addr);

    var addrs = std.ArrayList(usize).init(arena.allocator());
    var context: std.debug.ThreadContext = undefined;
    const has_context = getContext(&context);
    const debug_info = try std.debug.getSelfDebugInfo();

    var it = (if (has_context) blk: {
        break :blk StackIterator.initWithContext(start_addr, debug_info, &context) catch null;
    } else null) orelse StackIterator.init(start_addr, null);
    defer it.deinit();

    while (it.next()) |return_address| {
        try addrs.append(return_address);
    }

    var stack_trace = std.builtin.StackTrace{
        .index = 0,
        .instruction_addresses = addrs.items,
    };

    std.debug.captureStackTrace(start_addr, &stack_trace);

    nosuspend try ansi.dumpConciseStackTrace(&nest, stack_trace);
    nosuspend try std.io.getStdErr().writeAll("\n\n");
}
