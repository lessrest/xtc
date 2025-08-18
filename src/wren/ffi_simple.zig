const std = @import("std");
const c = @import("c.zig");
const ScriptContext = @import("runtime.zig").ScriptContext;

pub const Suspend = error.Suspend;

/// Function registry entry with comptime-generated wrapper
pub const FfiFunction = struct {
    name: [*:0]const u8,
    func: *const fn (*c.VM, *ScriptContext, c_int) anyerror!void,
    arity: usize,

    pub fn writeParamList(self: FfiFunction, w: anytype) !void {
        const metavars: []const u8 = "abcdefghijklmnopqrstuvwxyz";
        for (0..self.arity) |i| {
            try w.print("{s}", .{metavars[i .. i + 1]});
            if (i < self.arity - 1) {
                try w.print(", ", .{});
            }
        }
    }

    pub fn writeYieldingMethod(self: FfiFunction, id: usize, w: anytype) !void {
        try w.print("  static {s}(", .{self.name});
        try self.writeParamList(w);
        try w.print(") {{ Fiber.yield([{d}, [", .{id});
        try self.writeParamList(w);
        try w.print("]]) }}\n", .{});
    }
};

/// Register a Zig function with automatic wrapper generation
pub fn registerFunction(
    comptime func: anytype,
    comptime fn_info: std.builtin.Type.Fn,
    comptime name: [*:0]const u8,
) FfiFunction {
    const params = fn_info.params;
    const return_type = fn_info.return_type.?;
    const ret_info = @typeInfo(return_type);
    const is_error_union = ret_info == .error_union;

    const arity = blk: {
        var i = 0;
        var actual_arity = 0;
        while (i < params.len) : (i += 1) {
            if (params[i].type.? == *c.VM or params[i].type.? == *ScriptContext) {
                continue;
            }
            actual_arity += 1;
        }
        break :blk actual_arity;
    };

    const Wrapper = struct {
        fn wrapper(vm: *c.VM, ctx: *ScriptContext, arglist_slot: c_int) anyerror!void {
            const paramTupleType = std.meta.ArgsTuple(@TypeOf(func));
            var args: paramTupleType = undefined;
            var consumedListArgs: c_int = 0;
            comptime var i = 0;
            inline for (params) |param| {
                args[i] = readParam(vm, ctx, param.type.?, arglist_slot, &consumedListArgs);
                i += 1;
            }
            const result = @call(.auto, func, args);

            // Handle return value
            if (is_error_union) {
                if (result) |value| {
                    writeReturn(vm, 1, value);
                } else |err| {
                    return err;
                }
            } else {
                writeReturn(vm, 1, result);
            }
        }

        fn readParam(
            vm: *c.VM,
            ctx: *ScriptContext,
            comptime P: type,
            arglist_slot: c_int,
            list_index: *c_int,
        ) P {
            if (P == *c.VM) {
                return vm;
            }
            if (P == *ScriptContext) {
                return ctx;
            }

            c.wrenGetListElement(vm, arglist_slot, list_index.*, 0);
            list_index.* += 1;

            if (P == []const u8) {
                var len: c_int = 0;
                const ptr = c.wrenGetSlotBytes(vm, 0, &len);
                return ptr[0..@intCast(len)];
            }
            if (P == f64) return c.wrenGetSlotDouble(vm, 0);
            if (P == bool) return c.wrenGetSlotBool(vm, 0);
            if (P == *c.Handle) {
                return c.wrenGetSlotHandle(vm, 0) orelse @panic("Invalid Wren handle");
            }

            switch (@typeInfo(P)) {
                .int => {
                    const n = c.wrenGetSlotDouble(vm, 0);
                    return @as(P, @intFromFloat(n));
                },
                else => @compileError("Unsupported parameter type: " ++ @typeName(P)),
            }
        }
    };

    return FfiFunction{
        .name = name,
        .func = Wrapper.wrapper,
        .arity = arity,
    };
}

pub fn writeReturn(vm: *c.VM, slot: c_int, value: anytype) void {
    const R = @TypeOf(value);
    if (R == void) return;
    if (R == []const u8) {
        c.wrenSetSlotBytes(vm, slot, value.ptr, value.len);
        return;
    }
    if (R == [:0]const u8) {
        c.wrenSetSlotString(vm, slot, value);
        return;
    }
    if (R == f64) {
        c.wrenSetSlotDouble(vm, slot, value);
        return;
    }
    if (R == bool) {
        c.wrenSetSlotBool(vm, slot, value);
        return;
    }

    switch (@typeInfo(R)) {
        .int => {
            const d: f64 = @floatFromInt(value);
            c.wrenSetSlotDouble(vm, slot, d);
        },
        else => @compileError("Unsupported return type: " ++ @typeName(R)),
    }
}

pub const platform_functions = blk: {
    var funcs: [std.meta.declarations(ScriptContext.Platform).len]FfiFunction = undefined;
    var i: usize = 0;
    for (std.meta.declarations(ScriptContext.Platform)) |decl| {
        const func = @field(ScriptContext.Platform, decl.name);
        const name = decl.name;
        const info: std.builtin.Type = @typeInfo(@TypeOf(func));
        switch (info) {
            .@"fn" => |fn_info| {
                funcs[i] = registerFunction(func, fn_info, name);
                i += 1;
            },
            else => {
                @compileError("bogus function: " ++ @typeName(func));
            },
        }
    }
    break :blk funcs;
};

/// Generate Wren wrapper classes with yield-based trampolines
pub fn generateWrenWrappers(allocator: std.mem.Allocator) ![]u8 {
    // If no functions registered, return empty source
    if (platform_functions.len == 0) {
        return allocator.dupe(u8, "");
    }

    var src = std.ArrayList(u8).init(allocator);
    defer src.deinit();
    var w = src.writer();

    try w.writeAll("class Kernel {\n");
    try w.writeAll("  foreign static enqueue(fiber)\n");

    for (platform_functions, 0..) |func, i| {
        try func.writeYieldingMethod(i, w);
    }

    try w.writeAll("}\n\n");

    return src.toOwnedSlice();
}
