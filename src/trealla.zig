const std = @import("std");

pub const c = extern struct {
    pub const prolog = opaque {};
    pub const pl_sub_query = opaque {};

    extern fn pl_create() ?*prolog;
    extern fn pl_destroy(*prolog) void;
    extern fn pl_eval(*prolog, expr: [*:0]const u8, interactive: bool) bool;
};

pub fn withEngine(run: fn (*c.prolog) anyerror!void) !void {
    const pl = c.pl_create() orelse return error.CreateFailed;
    defer c.pl_destroy(pl);
    try run(pl);
}

test "trealla basic eval" {
    try withEngine(struct {
        fn go(pl: *c.prolog) !void {
            const ok = c.pl_eval(pl, "write(hello),nl.", false);
            std.testing.expect(ok) catch return error.EvalFailed;
        }
    }.go);
}
