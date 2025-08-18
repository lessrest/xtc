const std = @import("std");
const c = @import("c.zig");

pub const ModuleSpec = struct {
    module_name: [:0]const u8,
    module_info: std.builtin.Type,
    module_classes: []const ClassSpec,
};

pub const ClassSpec = struct {
    class_name: [:0]const u8,
    class_info: std.builtin.Type,
    class_functions: []const FunctionSpec,
};

pub const FunctionSpec = struct {
    // Zig method name, e.g. "say"
    name: [:0]const u8,
    // Fully qualified Wren signature, e.g. "say(_)" or "hello()"
    wren_signature: [:0]const u8,
    // Pointer to the Zig function
    func: *const anyopaque,
    // Full parameter list including the leading VM and context pointers
    params: []const std.builtin.Type.Fn.Param,
    // Return payload type (if the function returns an error union, this is the payload)
    return_type: type,
    // Whether the Zig function returns an error union
    is_error_union: bool,
    // Full return type (may be error union)
    full_return_type: type,
    // Unique ID for the function
    id: usize = 0,

    pub fn arity(this: @This()) usize {
        // First two parameters are always *c.WrenVM and *T (ScriptContext)
        if (this.params.len <= 2) return 0;
        return this.params.len - 2;
    }
};

pub const ForeignFunction = struct {
    module_name: [:0]const u8,
    class_name: [:0]const u8,
    wren_signature: [:0]const u8,
    func: c.ForeignMethodFn,
    arity: usize,
    id: usize = 0,
};

// Generate module specs from a type's Modules struct
pub fn moduleSpecs(comptime T: type, comptime global_id: *usize) []const ModuleSpec {
    const decls = std.meta.declarations(T.Modules);
    var specs: [decls.len]ModuleSpec = undefined;
    var i = 0;
    inline for (decls) |decl| {
        specs[i] = .{
            .module_name = decl.name,
            .module_info = @typeInfo(@field(T.Modules, decl.name)),
            .module_classes = classSpecs(@field(T.Modules, decl.name), global_id),
        };
        i += 1;
    }
    const specs_final = specs;
    return &specs_final;
}

pub fn classSpecs(comptime T: type, comptime global_id: *usize) []const ClassSpec {
    const decls = std.meta.declarations(T);
    var specs: [decls.len]ClassSpec = undefined;
    var i = 0;
    inline for (decls) |decl| {
        specs[i] = .{
            .class_name = decl.name,
            .class_info = @typeInfo(@field(T, decl.name)),
            .class_functions = functionSpecs(@field(T, decl.name), global_id),
        };
        i += 1;
    }
    const specs_final = specs;
    return &specs_final;
}

pub fn functionSpecs(comptime T: type, comptime global_id: *usize) []const FunctionSpec {
    const decls = std.meta.declarations(T);
    var specs: [decls.len]FunctionSpec = undefined;
    var i = 0;
    inline for (decls) |decl| {
        const fn_type = @typeInfo(@TypeOf(@field(T, decl.name))).@"fn";
        const params = fn_type.params;
        const full_return_type = fn_type.return_type.?;
        const ret_info = @typeInfo(full_return_type);
        var is_error_union = false;
        var R: type = full_return_type;
        switch (ret_info) {
            .error_union => |eu| {
                is_error_union = true;
                R = eu.payload;
            },
            else => {},
        }

        const arity = if (params.len <= 2) 0 else params.len - 2;
        const sig = switch (arity) {
            0 => decl.name ++ "()",
            1 => decl.name ++ "(_)",
            2 => decl.name ++ "(_,_)",
            3 => decl.name ++ "(_,_,_)",
            else => @compileError("Unsupported arity (>3) for Wren signature generation"),
        };

        specs[i] = .{
            .name = decl.name,
            .wren_signature = sig,
            .func = @field(T, decl.name),
            .params = params,
            .return_type = R,
            .is_error_union = is_error_union,
            .full_return_type = full_return_type,
            .id = global_id.*,
        };
        global_id.* += 1;
        i += 1;
    }
    const specs_final = specs;
    return &specs_final;
}

// Generate a foreign function wrapper for a specific function spec
pub fn generateForeignFunction(
    comptime T: type,
    comptime module_name: [:0]const u8,
    comptime class_name: [:0]const u8,
    comptime spec: FunctionSpec,
) ForeignFunction {
    const container = struct {
        inline fn readParam(vm: *c.VM, comptime P: type, slot_index: c_int) P {
            if (P == []const u8) {
                var len: c_int = 0;
                const ptr = c.wrenGetSlotBytes(vm, slot_index, &len);
                return ptr[0..@intCast(len)];
            }
            if (P == f64) return c.wrenGetSlotDouble(vm, slot_index);
            if (P == bool) return c.wrenGetSlotBool(vm, slot_index);
            if (P == *c.Handle) {
                // Get a handle to a Wren object (function, class, etc)
                return c.wrenGetSlotHandle(vm, slot_index) orelse @panic("Invalid Wren handle");
            }

            switch (@typeInfo(P)) {
                .int => {
                    const n = c.wrenGetSlotDouble(vm, slot_index);
                    return @as(P, @intFromFloat(n));
                },
                else => @compileError("Unsupported parameter type for Wren foreign method"),
            }
        }

        inline fn writeReturn(vm: *c.VM, comptime R: type, value: R) void {
            if (R == void) return;
            if (R == []const u8) {
                c.wrenSetSlotBytes(vm, 0, value.ptr, value.len);
                return;
            }
            if (R == f64) {
                c.wrenSetSlotDouble(vm, 0, value);
                return;
            }
            if (R == bool) {
                c.wrenSetSlotBool(vm, 0, value);
                return;
            }
            switch (@typeInfo(R)) {
                .int => {
                    const d: f64 = @floatFromInt(value);
                    c.wrenSetSlotDouble(vm, 0, d);
                },
                else => @compileError("Unsupported return type for Wren foreign method"),
            }
        }

        pub fn invoke(vm: *c.VM) callconv(.C) void {
            //            std.debug.print("invoke {s}\n", .{spec.name});
            const data: *T = @ptrCast(@alignCast(c.wrenGetUserData(vm)));
            // Build the function type from spec
            const params = spec.params;
            const R = spec.return_type;
            // Now we expect functions to have signature: fn(vm: *c.WrenVM, ctx: *T, ...)
            // So arity is params.len - 2 (excluding vm and ctx)
            const arity = if (params.len <= 2) 0 else params.len - 2;
            switch (arity) {
                0 => {
                    const Fun = if (spec.is_error_union)
                        *const fn (*c.VM, *T) R
                    else
                        *const fn (*c.VM, *T) R;
                    const func: Fun = @ptrCast(@alignCast(spec.func));
                    if (spec.is_error_union) {
                        const result = func(vm, data);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    } else {
                        const result = func(vm, data);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    }
                },
                1 => {
                    const P1 = params[2].type.?;
                    const Fun = if (spec.is_error_union)
                        *const fn (*c.VM, *T, P1) R
                    else
                        *const fn (*c.VM, *T, P1) R;
                    const func: Fun = @ptrCast(@alignCast(spec.func));
                    const a1 = readParam(vm, P1, 1);
                    if (spec.is_error_union) {
                        const result = func(vm, data, a1);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    } else {
                        const result = func(vm, data, a1);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    }
                },
                2 => {
                    const P1 = params[2].type.?;
                    const P2 = params[3].type.?;
                    const Fun = if (spec.is_error_union)
                        *const fn (*c.VM, *T, P1, P2) R
                    else
                        *const fn (*c.VM, *T, P1, P2) R;
                    const func: Fun = @ptrCast(@alignCast(spec.func));
                    const a1 = readParam(vm, P1, 1);
                    const a2 = readParam(vm, P2, 2);
                    if (spec.is_error_union) {
                        const result = func(vm, data, a1, a2);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    } else {
                        const result = func(vm, data, a1, a2);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    }
                },
                3 => {
                    const P1 = params[2].type.?;
                    const P2 = params[3].type.?;
                    const P3 = params[4].type.?;
                    const Fun = if (spec.is_error_union)
                        *const fn (*c.VM, *T, P1, P2, P3) R
                    else
                        *const fn (*c.VM, *T, P1, P2, P3) R;
                    const func: Fun = @ptrCast(@alignCast(spec.func));
                    const a1 = readParam(vm, P1, 1);
                    const a2 = readParam(vm, P2, 2);
                    const a3 = readParam(vm, P3, 3);
                    if (spec.is_error_union) {
                        const result = func(vm, data, a1, a2, a3);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    } else {
                        const result = func(vm, data, a1, a2, a3);
                        if (@typeInfo(R) != .void) writeReturn(vm, R, result);
                    }
                },
                else => @compileError("Unsupported arity (>3) for Wren foreign method"),
            }
        }
    };

    return .{
        .module_name = module_name,
        .class_name = class_name,
        .wren_signature = spec.wren_signature,
        .func = container.invoke,
        .id = spec.id,
        .arity = spec.arity(),
    };
}
