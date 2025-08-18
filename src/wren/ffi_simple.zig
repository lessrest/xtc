const std = @import("std");
const c = @import("c.zig");

/// Function registry entry with comptime-generated wrapper
pub const FfiFunction = struct {
    /// Human-readable name for debugging
    name: [*:0]const u8,
    /// Generated wrapper function that handles argument parsing/return value conversion
    func: *const fn (*c.VM) callconv(.C) void,
    /// Expected number of arguments (for validation)
    arity: usize,
};

/// Register a Zig function with automatic wrapper generation
pub fn registerFunction(
    comptime func: anytype,
    comptime name: [*:0]const u8,
    comptime ScriptContext: type,
) FfiFunction {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const params = fn_info.params;
    const return_type = fn_info.return_type.?;

    // Parse return type (handle error unions)
    const ret_info = @typeInfo(return_type);
    const is_error_union = ret_info == .error_union;
    const payload_type = if (is_error_union) ret_info.error_union.payload else return_type;

    // Calculate arity (excluding vm and context params)
    const arity = if (params.len <= 2) 0 else params.len - 2;

    const Wrapper = struct {
        fn wrapper(vm: *c.VM) callconv(.C) void {
            const ctx: *ScriptContext = @ptrCast(@alignCast(c.wrenGetUserData(vm)));

            // Call the function with proper argument parsing
            const result = switch (arity) {
                0 => func(vm, ctx),
                1 => func(vm, ctx, readParam(vm, params[2].type.?, 1)),
                2 => func(vm, ctx, readParam(vm, params[2].type.?, 1), readParam(vm, params[3].type.?, 2)),
                3 => func(vm, ctx, readParam(vm, params[2].type.?, 1), readParam(vm, params[3].type.?, 2), readParam(vm, params[4].type.?, 3)),
                else => @compileError("Unsupported arity > 3"),
            };

            // Handle return value
            if (is_error_union) {
                if (result) |value| {
                    writeReturn(vm, payload_type, value);
                } else |_| {
                    c.wrenSetSlotNull(vm, 0);
                }
            } else {
                writeReturn(vm, payload_type, result);
            }
        }

        fn readParam(vm: *c.VM, comptime P: type, slot: c_int) P {
            if (P == []const u8) {
                var len: c_int = 0;
                const ptr = c.wrenGetSlotBytes(vm, slot, &len);
                return ptr[0..@intCast(len)];
            }
            if (P == f64) return c.wrenGetSlotDouble(vm, slot);
            if (P == bool) return c.wrenGetSlotBool(vm, slot);
            if (P == *c.Handle) {
                return c.wrenGetSlotHandle(vm, slot) orelse @panic("Invalid Wren handle");
            }

            switch (@typeInfo(P)) {
                .int => {
                    const n = c.wrenGetSlotDouble(vm, slot);
                    return @as(P, @intFromFloat(n));
                },
                else => @compileError("Unsupported parameter type: " ++ @typeName(P)),
            }
        }

        fn writeReturn(vm: *c.VM, comptime R: type, value: R) void {
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
                else => @compileError("Unsupported return type: " ++ @typeName(R)),
            }
        }
    };

    return FfiFunction{
        .name = name,
        .func = Wrapper.wrapper,
        .arity = arity,
    };
}

/// Simple flat function registry builder
pub fn buildFunctionRegistry(comptime ScriptContext: type) []const FfiFunction {
    // Check if this context has the required fields for DOM/TUI functionality
    const has_dom = @hasField(ScriptContext, "document");
    const has_scheduler = @hasField(ScriptContext, "scheduler");

    if (!has_dom or !has_scheduler) {
        // Return empty registry for minimal contexts like the eval handler
        const empty: [0]FfiFunction = .{};
        return &empty;
    }

    const DOM = @import("platform/DOM.zig");

    // Use comptime block to ensure proper string literal handling
    const functions = comptime blk: {
        var funcs: [16]FfiFunction = undefined;
        var i: usize = 0;

        // TUI enqueue function - needed as real foreign for bootstrapping
        const TUI = @import("platform/Tui.zig");
        funcs[i] = registerFunction(TUI.enqueue, "enqueue", ScriptContext);
        i += 1;

        // DOM functions - all go through fiber trampoline
        funcs[i] = registerFunction(DOM.getElementById, "getElementById", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.createElement, "createElement", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.createText, "createText", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.appendChild, "appendChild", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.updateText, "updateText", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.updateClass, "updateClass", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.setDebugId, "setDebugId", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.removeChild, "removeChild", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.getChildCount, "getChildCount", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.getFirstChild, "getFirstChild", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.addEventListener, "addEventListener", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.removeEventListener, "removeEventListener", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.viewportWidth, "viewportWidth", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.viewportHeight, "viewportHeight", ScriptContext);
        i += 1;
        funcs[i] = registerFunction(DOM.root, "root", ScriptContext);
        i += 1;

        break :blk funcs;
    };

    return &functions;
}

/// Generate Wren wrapper classes with yield-based trampolines
pub fn generateWrenWrappers(allocator: std.mem.Allocator, comptime ScriptContext: type) ![]u8 {
    const functions = buildFunctionRegistry(ScriptContext);

    // If no functions registered, return empty source
    if (functions.len == 0) {
        return allocator.dupe(u8, "");
    }

    var src = std.ArrayList(u8).init(allocator);
    defer src.deinit();
    var w = src.writer();

    // Generate Platform class with all FFI methods
    try w.writeAll("class Platform {\n");
    for (functions, 0..) |func, i| {
        switch (func.arity) {
            0 => try w.print("  static {s}() {{ Fiber.yield([1, {d}]) }}\n", .{ func.name, i }),
            1 => try w.print("  static {s}(a) {{ Fiber.yield([1, {d}, a]) }}\n", .{ func.name, i }),
            2 => try w.print("  static {s}(a, b) {{ Fiber.yield([1, {d}, a, b]) }}\n", .{ func.name, i }),
            3 => try w.print("  static {s}(a, b, c) {{ Fiber.yield([1, {d}, a, b, c]) }}\n", .{ func.name, i }),
            4 => try w.print("  static {s}(a, b, c, d) {{ Fiber.yield([1, {d}, a, b, c, d]) }}\n", .{ func.name, i }),
            else => @panic("Unsupported arity"),
        }
    }
    try w.writeAll("}\n\n");

    // Only enqueue stays as a real foreign function
    try w.writeAll("class Tui { foreign static enqueue(fiber) }\n");

    return src.toOwnedSlice();
}
