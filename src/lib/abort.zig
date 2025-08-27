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

    var nest = tree.stderr(arena.allocator());

    //    nosuspend try ansi.dumpFuckItAllTrace(&nest, start_addr);

    var addrs = std.ArrayList(usize){};
    var context: std.debug.ThreadContext = undefined;
    const has_context = getContext(&context);
    const debug_info = try std.debug.getSelfDebugInfo();

    var it = (if (has_context) blk: {
        break :blk StackIterator.initWithContext(start_addr, debug_info, &context) catch null;
    } else null) orelse StackIterator.init(start_addr, null);
    defer it.deinit();

    while (it.next()) |return_address| {
        try addrs.append(arena.allocator(), return_address);
    }

    var stack_trace = std.builtin.StackTrace{
        .index = 0,
        .instruction_addresses = addrs.items,
    };

    std.debug.captureStackTrace(start_addr, &stack_trace);

    nosuspend try nest.newline();
    nosuspend try ansi.dumpConciseStackTrace(&nest, stack_trace);
    var err_buf: [128]u8 = undefined;
    var err_state = std.fs.File.stderr().writer(&err_buf);
    const err: *std.Io.Writer = &err_state.interface;
    nosuspend try err.writeAll("\n\n");
    nosuspend try err.flush();
}
