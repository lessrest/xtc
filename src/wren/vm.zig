const std = @import("std");

pub const c = @import("c.zig");

const TrackedAllocator = @import("../lib/TrackingAllocator.zig");
const ffi = @import("ffi.zig");

pub fn ScriptEngine(comptime ScriptContext: type) type {
    return struct {
        vm: *c.VM,
        ctx: *ScriptContext,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(ctx: *ScriptContext) !Self {
            var config: c.Configuration = .{};
            c.wrenInitConfiguration(&config);

            config.writeFn = writeFn;
            config.errorFn = errorFn;
            config.loadModuleFn = null;
            config.bindForeignMethodFn = bindForeignMethodFn;
            config.bindForeignClassFn = null;
            config.reallocateFn = reallocateFn;
            config.userData = ctx;

            const vm_ptr = c.wrenNewVM(&config) orelse return error.VMCreationFailed;

            return Self{
                .vm = vm_ptr,
                .ctx = ctx,
                .allocator = ctx.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            c.wrenFreeVM(self.vm);
        }

        pub fn interpret(self: *Self, module_name: []const u8, source: []const u8) !void {
            const module_z = try self.allocator.dupeZ(u8, module_name);
            defer self.allocator.free(module_z);

            const source_z = try self.allocator.dupeZ(u8, source);
            defer self.allocator.free(source_z);

            const result = c.wrenInterpret(self.vm, module_z, source_z);

            switch (@as(c.InterpretResult, @enumFromInt(result))) {
                .success => {},
                .compile_error => {
                    return error.CompileError;
                },
                .runtime_error => {
                    return error.RuntimeError;
                },
            }
        }

        fn setValueSlot(vm: *c.VM, slot: c_int, value: anytype) void {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        c.wrenSetSlotBytes(vm, slot, value.ptr, value.len);
                        return;
                    }
                    @panic(@typeName(T));
                },
                .int => {
                    const d: f64 = @floatFromInt(value);
                    c.wrenSetSlotDouble(vm, slot, d);
                    return;
                },
                .float => {
                    const d: f64 = if (@TypeOf(value) == f64) value else @as(f64, value);
                    c.wrenSetSlotDouble(vm, slot, d);
                    return;
                },
                .bool => {
                    c.wrenSetSlotBool(vm, slot, value);
                    return;
                },
                else => @panic(@typeName(T)),
            }
        }

        pub fn callStatic(
            self: *Self,
            module: []const u8,
            class_name: []const u8,
            signature: []const u8,
            args: anytype,
        ) !void {
            const module_z = try self.allocator.dupeZ(u8, module);
            defer self.allocator.free(module_z);
            const class_z = try self.allocator.dupeZ(u8, class_name);
            defer self.allocator.free(class_z);
            const sig_z = try self.allocator.dupeZ(u8, signature);
            defer self.allocator.free(sig_z);

            const arg_types = @typeInfo(@TypeOf(args)).@"struct".fields;
            const arg_count: c_int = @intCast(@min(arg_types.len, std.math.maxInt(c_int)));
            c.wrenEnsureSlots(self.vm, arg_count + 1);
            c.wrenGetVariable(self.vm, module_z, class_z, 0);

            var i: c_int = 1;
            inline for (arg_types) |a| {
                const arg_name = a.name;
                const arg_value = @field(args, arg_name);
                setValueSlot(self.vm, i, arg_value);
                i += 1;
            }

            const handle = c.wrenMakeCallHandle(self.vm, sig_z) orelse return error.CallHandleCreateFailed;
            defer c.wrenReleaseHandle(self.vm, handle);
            const result = c.wrenCall(self.vm, handle);
            switch (@as(c.InterpretResult, @enumFromInt(result))) {
                .success => {},
                .compile_error => return error.CompileError,
                .runtime_error => return error.RuntimeError,
            }
        }

        pub fn callStaticGetNumber(
            self: *Self,
            module: []const u8,
            class_name: []const u8,
            signature: []const u8,
            args: anytype,
        ) !f64 {
            const module_z = try self.allocator.dupeZ(u8, module);
            defer self.allocator.free(module_z);
            const class_z = try self.allocator.dupeZ(u8, class_name);
            defer self.allocator.free(class_z);
            const sig_z = try self.allocator.dupeZ(u8, signature);
            defer self.allocator.free(sig_z);

            const arg_types = @typeInfo(@TypeOf(args)).@"struct".fields;
            const arg_count: c_int = @intCast(@min(arg_types.len, std.math.maxInt(c_int)));
            c.wrenEnsureSlots(self.vm, arg_count + 1);
            c.wrenGetVariable(self.vm, module_z, class_z, 0);

            var i: c_int = 0;
            inline for (arg_types, 0..) |a, idx| {
                _ = idx;
                const arg_name = a.name;
                const arg_value = @field(args, arg_name);
                setValueSlot(self.vm, i, arg_value);
                i += 1;
            }

            const handle = c.wrenMakeCallHandle(self.vm, sig_z) orelse return error.CallHandleCreateFailed;
            defer c.wrenReleaseHandle(self.vm, handle);
            const result = c.wrenCall(self.vm, handle);
            switch (@as(c.InterpretResult, @enumFromInt(result))) {
                .success => {},
                .compile_error => return error.CompileError,
                .runtime_error => return error.RuntimeError,
            }
            return c.wrenGetSlotDouble(self.vm, 0);
        }

        // Auto-generate and register Wren classes for all foreign modules/classes/methods
        pub fn registerForeignModules(self: *Self) !void {
            const specs = comptime ffi.moduleSpecs(ScriptContext);
            inline for (specs) |mod_spec| {
                var src = std.ArrayList(u8).init(self.allocator);
                defer src.deinit();

                var w = src.writer();

                inline for (mod_spec.module_classes) |cls| {
                    try w.print("class {s} {s}\n", .{ cls.class_name, "{" });
                    inline for (cls.class_functions) |fn_spec| {
                        const ar = fn_spec.arity();
                        switch (ar) {
                            0 => try w.print("  foreign static {s}()\n", .{fn_spec.name}),
                            1 => try w.print("  foreign static {s}(a)\n", .{fn_spec.name}),
                            2 => try w.print("  foreign static {s}(a, b)\n", .{fn_spec.name}),
                            3 => try w.print("  foreign static {s}(a, b, c)\n", .{fn_spec.name}),
                            else => @panic("nooo"),
                        }
                    }
                    try w.writeAll("}\n\n");
                }

                // Interpret generated source in the module namespace
                if (self.interpret(mod_spec.module_name, src.items)) |_| {
                    // ok
                } else |err| {
                    std.debug.print("Error interpreting module {s}: {any}\n", .{
                        mod_spec.module_name,
                        err,
                    });
                    std.debug.print("Source:\n{s}\n", .{src.items});
                    return err;
                }
            }
        }

        fn reallocateFn(memory: ?*anyopaque, new_size: usize, ctxptr: *anyopaque) callconv(.C) ?*anyopaque {
            const ctx: *ScriptContext = @ptrCast(@alignCast(ctxptr));
            const allocator = ctx.allocator;
            const tracked = TrackedAllocator{ .allocator = allocator };

            if (new_size == 0) {
                if (memory) |mem| {
                    const ptr: [*]u8 = @ptrCast(mem);
                    tracked.free(ptr);
                    return null;
                } else {
                    return null;
                }
            } else if (memory) |mem| {
                const old_ptr: [*]u8 = @ptrCast(mem);
                return tracked.realloc(old_ptr, new_size);
            } else {
                return tracked.alloc(new_size);
            }
        }

        fn writeFn(vm: *c.VM, text: [*:0]const u8) callconv(.C) void {
            const ptr = c.wrenGetUserData(vm);
            const ctx: *ScriptContext = @ptrCast(@alignCast(ptr));
            const str = std.mem.span(text);
            ctx.write(str);
        }

        fn errorFn(
            vm: *c.VM,
            error_type: c.ErrorType,
            module: ?[*:0]const u8,
            line: c_int,
            message: ?[*:0]const u8,
        ) callconv(.C) void {
            const ptr = c.wrenGetUserData(vm);
            const ctx: *ScriptContext = @ptrCast(@alignCast(ptr));
            const module_str = if (module) |m| std.mem.span(m) else "";
            const msg_str = if (message) |m| std.mem.span(m) else "";
            ctx.onError(error_type, module_str, line, msg_str);
        }

        fn abortWithError(vm: *c.VM, msg: []const u8) void {
            c.wrenSetSlotBytes(vm, 0, msg.ptr, msg.len);
            c.wrenAbortFiber(vm, 0);
        }

        const foreign_function_count = blk: {
            var i = 0;
            for (ffi.moduleSpecs(ScriptContext)) |module_spec| {
                for (module_spec.module_classes) |class| {
                    i += class.class_functions.len;
                }
            }
            break :blk i;
        };

        const foreign_functions: [foreign_function_count]ffi.ForeignFunction = blk: {
            var fns: [foreign_function_count]ffi.ForeignFunction = undefined;
            var i = 0;
            for (ffi.moduleSpecs(ScriptContext)) |module| {
                for (module.module_classes) |class| {
                    for (class.class_functions) |spec| {
                        fns[i] = ffi.generateForeignFunction(
                            ScriptContext,
                            module.module_name,
                            class.class_name,
                            spec,
                        );
                        i += 1;
                    }
                }
            }
            break :blk fns;
        };

        fn bindForeignMethodFn(
            vm: *c.VM,
            module: [*:0]const u8,
            className: [*:0]const u8,
            isStatic: bool,
            signature: [*:0]const u8,
        ) callconv(.C) c.ForeignMethodFn {
            _ = vm; // unused
            if (!isStatic) return null;

            const module_slice = std.mem.span(module);
            const class_slice = std.mem.span(className);
            const sig_slice = std.mem.span(signature);

            inline for (foreign_functions) |f| {
                if (std.mem.eql(u8, f.module_name, module_slice) and
                    std.mem.eql(u8, f.class_name, class_slice) and
                    std.mem.eql(u8, f.wren_signature, sig_slice))
                {
                    return f.func;
                }
            }

            return null;
        }
    };
}

// Simple wrapper for creating a VM
pub fn create(t: type, x: *t) !ScriptEngine(t) {
    return try ScriptEngine(t).init(x);
}

// Simple wrapper for one-shot evaluation
pub fn eval(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const Handlers = struct {
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),

        pub const Modules = struct {};

        pub fn write(self: *@This(), text: []const u8) void {
            self.output.appendSlice(text) catch {};
        }

        pub fn onError(self: *@This(), error_type: c.ErrorType, module: []const u8, line: c_int, message: []const u8) void {
            switch (error_type) {
                .compile => {
                    self.output.appendSlice("[Compile error]") catch {};
                },
                .runtime => {
                    self.output.appendSlice("[Runtime error]") catch {};
                },
                .stack_trace => {
                    self.output.appendSlice("[Stack trace]") catch {};
                },
            }
            _ = module;
            _ = line;
            _ = message;
        }
    };
    const WrenVMType = ScriptEngine(Handlers);
    var handlers = Handlers{ .allocator = allocator, .output = &output };
    var vm = try WrenVMType.init(&handlers);
    defer vm.deinit();

    // No foreign modules in this one-shot helper, but call anyway to allow future expansion
    try vm.registerForeignModules();
    try vm.interpret("main", source);

    return output.toOwnedSlice();
}

// Tests
test "wren virtual machine evaluates basic scripts and returns printed output" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try eval(allocator,
        \\System.print("Hello from Wren!")
        \\System.print("2 + 3 = %(2 + 3)")
    );
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Hello from Wren!") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2 + 3 = 5") != null);
}

test "wren allocator tracks memory usage across list and map operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try eval(allocator,
        \\// Test multiple allocations
        \\var list = []
        \\for (i in 1..10) {
        \\    list.add("Item %(i)")
        \\}
        \\System.print("Created list with %(list.count) items")
        \\
        \\var map = {}
        \\for (i in 1..5) {
        \\    map[i] = "Value %(i * i)"
        \\}
        \\System.print("Map[3]: %(map[3])")
    );
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Created list with 10 items") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Map[3]: Value 9") != null);
}

test "wren compilation errors are caught and returned as zig errors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test compilation error
    const result = eval(allocator,
        \\System.print("This should work")
        \\invalid_syntax_here...
    );

    try std.testing.expectError(error.CompileError, result);
}

test "tracked allocator wrapper properly forwards allocation calls to underlying allocator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tracked = TrackedAllocator{ .allocator = allocator };

    // Test basic allocation
    const ptr1 = tracked.alloc(64).?;
    ptr1[0] = 42;
    ptr1[63] = 24;

    // Test reallocation
    const ptr2 = tracked.realloc(ptr1, 128).?;
    try std.testing.expect(ptr2[0] == 42); // Old data preserved
    try std.testing.expect(ptr2[63] == 24); // Old data preserved
    ptr2[127] = 99; // New space is accessible

    // Test freeing
    tracked.free(ptr2);

    // Test allocation after free (should not crash)
    const ptr3 = tracked.alloc(32).?;
    tracked.free(ptr3);
}
