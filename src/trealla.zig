const std = @import("std");
const posix = std.posix;

pub const c = extern struct {
    pub const prolog = opaque {};
    pub const pl_sub_query = opaque {};

    pub extern fn pl_create() ?*prolog;
    pub extern fn pl_destroy(*prolog) void;
    pub extern fn pl_eval(*prolog, expr: [*:0]const u8, interactive: bool) bool;

    pub extern fn get_error(*prolog) bool;
    pub extern fn get_status(*prolog) bool;
    pub extern fn get_redo(*prolog) bool;
    pub extern fn did_dump_vars(*prolog) bool;
};

pub fn withEngine(run: fn (*c.prolog) anyerror!void) !void {
    const pl = c.pl_create() orelse return error.CreateFailed;
    defer c.pl_destroy(pl);
    try run(pl);
}

const ReaderCtx = struct {
    fd: posix.fd_t,
    out: *std.ArrayList(u8),
};

fn readerThread(ctx: *ReaderCtx) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(ctx.fd, buf[0..]) catch break;
        if (n == 0) break;
        ctx.out.appendSlice(buf[0..n]) catch break;
    }
    posix.close(ctx.fd);
}

pub fn evalToString(allocator: std.mem.Allocator, pl: *c.prolog, expr: []const u8) ![]u8 {
    const c_expr = try allocator.dupeZ(u8, expr);
    defer allocator.free(c_expr);

    const saved_out = try posix.dup(std.posix.STDOUT_FILENO);
    errdefer posix.close(saved_out);
    const saved_err = try posix.dup(std.posix.STDERR_FILENO);
    errdefer posix.close(saved_err);

    const pipe_out = try posix.pipe();
    errdefer {
        posix.close(pipe_out[0]);
        posix.close(pipe_out[1]);
    }
    const pipe_err = try posix.pipe();
    errdefer {
        posix.close(pipe_err[0]);
        posix.close(pipe_err[1]);
    }

    try posix.dup2(pipe_out[1], std.posix.STDOUT_FILENO);
    try posix.dup2(pipe_err[1], std.posix.STDERR_FILENO);
    posix.close(pipe_out[1]);
    posix.close(pipe_err[1]);

    var out_buf = std.ArrayList(u8).init(allocator);
    errdefer out_buf.deinit();
    var err_buf = std.ArrayList(u8).init(allocator);
    errdefer err_buf.deinit();
    var ctx_out = ReaderCtx{ .fd = pipe_out[0], .out = &out_buf };
    var ctx_err = ReaderCtx{ .fd = pipe_err[0], .out = &err_buf };
    const th_out = try std.Thread.spawn(.{}, readerThread, .{&ctx_out});
    const th_err = try std.Thread.spawn(.{}, readerThread, .{&ctx_err});

    _ = c.pl_eval(pl, c_expr.ptr, true);

    try posix.dup2(saved_out, std.posix.STDOUT_FILENO);
    try posix.dup2(saved_err, std.posix.STDERR_FILENO);
    posix.close(saved_out);
    posix.close(saved_err);

    th_out.join();
    th_err.join();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    if (out_buf.items.len > 0) try out.appendSlice(out_buf.items);
    if (err_buf.items.len > 0) try out.appendSlice(err_buf.items);

    const show_status = !c.did_dump_vars(pl) and !c.get_error(pl);
    if (show_status) {
        if (c.get_redo(pl)) {
            try out.appendSlice(" ");
        } else {
            try out.appendSlice("   ");
        }
        if (c.get_status(pl)) {
            try out.appendSlice("true.\n");
        } else {
            try out.appendSlice("false.\n");
        }
    }

    out_buf.deinit();
    err_buf.deinit();
    return out.toOwnedSlice();
}

test "trealla basic eval" {
    try withEngine(struct {
        fn go(pl: *c.prolog) !void {
            const res = try evalToString(std.testing.allocator, pl, "write(hello),nl.");
            defer std.testing.allocator.free(res);
            try std.testing.expect(std.mem.indexOf(u8, res, "hello\n") != null);
        }
    }.go);
}
