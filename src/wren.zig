const std = @import("std");

// Clean Wren bindings - extracted from wren.h and cleaned up
// Opaque types
pub const WrenVM = opaque {};
pub const WrenHandle = opaque {};

// Function pointer types
pub const WrenReallocateFn = ?*const fn (?*anyopaque, usize, *anyopaque) callconv(.c) ?*anyopaque;
pub const WrenForeignMethodFn = ?*const fn (*WrenVM) callconv(.c) void;
pub const WrenFinalizerFn = ?*const fn (?*anyopaque) callconv(.c) void;
pub const WrenResolveModuleFn = ?*const fn (*WrenVM, [*:0]const u8, [*:0]const u8) callconv(.c) [*:0]const u8;
pub const WrenLoadModuleCompleteFn = ?*const fn (*WrenVM, [*:0]const u8, WrenLoadModuleResult) callconv(.c) void;
pub const WrenLoadModuleFn = ?*const fn (*WrenVM, [*:0]const u8) callconv(.c) WrenLoadModuleResult;
pub const WrenBindForeignMethodFn = ?*const fn (*WrenVM, [*:0]const u8, [*:0]const u8, bool, [*:0]const u8) callconv(.c) WrenForeignMethodFn;
pub const WrenWriteFn = ?*const fn (*WrenVM, [*:0]const u8) callconv(.c) void;
pub const WrenErrorFn = ?*const fn (*WrenVM, WrenErrorType, [*:0]const u8, c_int, [*:0]const u8) callconv(.c) void;
pub const WrenBindForeignClassFn = ?*const fn (*WrenVM, [*:0]const u8, [*:0]const u8) callconv(.c) WrenForeignClassMethods;

// Structs
pub const WrenLoadModuleResult = extern struct {
    source: ?[*:0]const u8 = null,
    onComplete: WrenLoadModuleCompleteFn = null,
    userData: ?*anyopaque = null,
};

pub const WrenForeignClassMethods = extern struct {
    allocate: WrenForeignMethodFn = null,
    finalize: WrenFinalizerFn = null,
};

pub const WrenConfiguration = extern struct {
    reallocateFn: WrenReallocateFn = null,
    resolveModuleFn: WrenResolveModuleFn = null,
    loadModuleFn: WrenLoadModuleFn = null,
    bindForeignMethodFn: WrenBindForeignMethodFn = null,
    bindForeignClassFn: WrenBindForeignClassFn = null,
    writeFn: WrenWriteFn = null,
    errorFn: WrenErrorFn = null,
    initialHeapSize: usize = 0,
    minHeapSize: usize = 0,
    heapGrowthPercent: c_int = 0,
    userData: ?*anyopaque = null,
};

// Error types
pub const WREN_ERROR_COMPILE: c_int = 0;
pub const WREN_ERROR_RUNTIME: c_int = 1;
pub const WREN_ERROR_STACK_TRACE: c_int = 2;
pub const WrenErrorType = c_uint;

// Result types
pub const WREN_RESULT_SUCCESS: c_int = 0;
pub const WREN_RESULT_COMPILE_ERROR: c_int = 1;
pub const WREN_RESULT_RUNTIME_ERROR: c_int = 2;
pub const WrenInterpretResult = c_uint;

// Value types
pub const WREN_TYPE_BOOL: c_int = 0;
pub const WREN_TYPE_NUM: c_int = 1;
pub const WREN_TYPE_FOREIGN: c_int = 2;
pub const WREN_TYPE_LIST: c_int = 3;
pub const WREN_TYPE_MAP: c_int = 4;
pub const WREN_TYPE_NULL: c_int = 5;
pub const WREN_TYPE_STRING: c_int = 6;
pub const WREN_TYPE_UNKNOWN: c_int = 7;
pub const WrenType = c_uint;

// Core API functions
pub extern fn wrenGetVersionNumber(...) c_int;
pub extern fn wrenInitConfiguration(configuration: *WrenConfiguration) void;
pub extern fn wrenNewVM(configuration: *WrenConfiguration) ?*WrenVM;
pub extern fn wrenFreeVM(vm: *WrenVM) void;
pub extern fn wrenCollectGarbage(vm: *WrenVM) void;
pub extern fn wrenInterpret(vm: *WrenVM, module: [*:0]const u8, source: [*:0]const u8) WrenInterpretResult;

// Handle management
pub extern fn wrenMakeCallHandle(vm: *WrenVM, signature: [*:0]const u8) ?*WrenHandle;
pub extern fn wrenCall(vm: *WrenVM, method: *WrenHandle) WrenInterpretResult;
pub extern fn wrenReleaseHandle(vm: *WrenVM, handle: *WrenHandle) void;

// Slot management
pub extern fn wrenGetSlotCount(vm: *WrenVM) c_int;
pub extern fn wrenEnsureSlots(vm: *WrenVM, numSlots: c_int) void;
pub extern fn wrenGetSlotType(vm: *WrenVM, slot: c_int) WrenType;

// Slot getters
pub extern fn wrenGetSlotBool(vm: *WrenVM, slot: c_int) bool;
pub extern fn wrenGetSlotBytes(vm: *WrenVM, slot: c_int, length: *c_int) [*]const u8;
pub extern fn wrenGetSlotDouble(vm: *WrenVM, slot: c_int) f64;
pub extern fn wrenGetSlotForeign(vm: *WrenVM, slot: c_int) ?*anyopaque;
pub extern fn wrenGetSlotString(vm: *WrenVM, slot: c_int) [*:0]const u8;
pub extern fn wrenGetSlotHandle(vm: *WrenVM, slot: c_int) ?*WrenHandle;

// Slot setters
pub extern fn wrenSetSlotBool(vm: *WrenVM, slot: c_int, value: bool) void;
pub extern fn wrenSetSlotBytes(vm: *WrenVM, slot: c_int, bytes: [*]const u8, length: usize) void;
pub extern fn wrenSetSlotDouble(vm: *WrenVM, slot: c_int, value: f64) void;
pub extern fn wrenSetSlotNewForeign(vm: *WrenVM, slot: c_int, classSlot: c_int, size: usize) ?*anyopaque;
pub extern fn wrenSetSlotNewList(vm: *WrenVM, slot: c_int) void;
pub extern fn wrenSetSlotNewMap(vm: *WrenVM, slot: c_int) void;
pub extern fn wrenSetSlotNull(vm: *WrenVM, slot: c_int) void;
pub extern fn wrenSetSlotString(vm: *WrenVM, slot: c_int, text: [*:0]const u8) void;
pub extern fn wrenSetSlotHandle(vm: *WrenVM, slot: c_int, handle: *WrenHandle) void;

// List operations
pub extern fn wrenGetListCount(vm: *WrenVM, slot: c_int) c_int;
pub extern fn wrenGetListElement(vm: *WrenVM, listSlot: c_int, index: c_int, elementSlot: c_int) void;
pub extern fn wrenSetListElement(vm: *WrenVM, listSlot: c_int, index: c_int, elementSlot: c_int) void;
pub extern fn wrenInsertInList(vm: *WrenVM, listSlot: c_int, index: c_int, elementSlot: c_int) void;

// Map operations
pub extern fn wrenGetMapCount(vm: *WrenVM, slot: c_int) c_int;
pub extern fn wrenGetMapContainsKey(vm: *WrenVM, mapSlot: c_int, keySlot: c_int) bool;
pub extern fn wrenGetMapValue(vm: *WrenVM, mapSlot: c_int, keySlot: c_int, valueSlot: c_int) void;
pub extern fn wrenSetMapValue(vm: *WrenVM, mapSlot: c_int, keySlot: c_int, valueSlot: c_int) void;
pub extern fn wrenRemoveMapValue(vm: *WrenVM, mapSlot: c_int, keySlot: c_int, removedValueSlot: c_int) void;

// Variable operations
pub extern fn wrenGetVariable(vm: *WrenVM, module: [*:0]const u8, name: [*:0]const u8, slot: c_int) void;
pub extern fn wrenHasVariable(vm: *WrenVM, module: [*:0]const u8, name: [*:0]const u8) bool;
pub extern fn wrenHasModule(vm: *WrenVM, module: [*:0]const u8) bool;

// VM operations
pub extern fn wrenAbortFiber(vm: *WrenVM, slot: c_int) void;
pub extern fn wrenGetUserData(vm: *WrenVM) *anyopaque;
pub extern fn wrenSetUserData(vm: *WrenVM, userData: *anyopaque) void;

// Allocation tracking wrapper - stores size prefix and ensures 8-byte alignment
const TrackedAllocator = struct {
    allocator: std.mem.Allocator,

    const Header = struct {
        size: u64, // Use u64 to guarantee 8-byte alignment for data that follows
    };

    const header_size = @sizeOf(Header);
    const alignment = std.mem.Alignment.fromByteUnits(8);

    fn alloc(self: TrackedAllocator, size: usize) ?[*]u8 {
        const total_size = header_size + size;
        const slice = self.allocator.rawAlloc(total_size, alignment, @returnAddress()) orelse return null;

        const header: *Header = @ptrCast(@alignCast(slice));
        header.size = @intCast(size);

        return slice + header_size;
    }

    fn realloc(self: TrackedAllocator, old_ptr: [*]u8, new_size: usize) ?[*]u8 {
        // Get old size from header
        const old_header_ptr = old_ptr - header_size;
        const old_header: *Header = @ptrCast(@alignCast(old_header_ptr));
        const old_size: usize = @intCast(old_header.size);

        // Allocate new memory
        const new_ptr = self.alloc(new_size) orelse return null;

        // Copy old data
        const copy_size = @min(old_size, new_size);
        @memcpy(new_ptr[0..copy_size], old_ptr[0..copy_size]);

        // Free old allocation
        const old_slice = old_header_ptr[0 .. header_size + old_size];
        self.allocator.rawFree(old_slice, alignment, @returnAddress());

        return new_ptr;
    }

    fn free(self: TrackedAllocator, ptr: [*]u8) void {
        const header_ptr = ptr - header_size;
        const header: *Header = @ptrCast(@alignCast(header_ptr));
        const size: usize = @intCast(header.size);

        const slice = header_ptr[0 .. header_size + size];
        self.allocator.rawFree(slice, alignment, @returnAddress());
    }
};

pub fn create(t: type, x: *t) !VM(t) {
    return try VM(t).init(x);
}

const ForeignModuleSpec = struct {
    module_name: []const u8,
    module_info: std.builtin.Type,
    module_classes: []const ForeignClassSpec,
};

const ForeignClassSpec = struct {
    class_name: []const u8,
    class_info: std.builtin.Type,
    class_functions: []const FunctionSpec,
};

const FunctionSpec = struct {
    name: []const u8,
    signature: []const u8,
    func: *const anyopaque,
    params: []const std.builtin.Type.Fn.Param,

    fn paramTypes(this: @This()) []type {
        var xs: [this.params.len]type = undefined;
        var i = 0;
        for (this.params) |param| {
            xs[i] = param.type.?;
            i += 1;
        }
        return &xs;
    }

    fn functionType(this: @This(), comptime T: type) type {
        const ps = this.paramTypes();
        if (ps.len == 1) {
            return (*const fn (*T) anyerror!void);
        } else if (ps.len == 2) {
            return (*const fn (*T, []const u8) anyerror!void);
        } else {
            @compileError("mad");
        }
    }
};

const ForeignFunction = struct {
    name: []const u8,
    func: WrenForeignMethodFn,
};

fn getForeignFunction(comptime T: type, comptime spec: FunctionSpec) ForeignFunction {
    const container = struct {
        pub fn invoke(vm: *WrenVM) callconv(.C) void {
            const data: *T = @ptrCast(@alignCast(wrenGetUserData(vm)));
            const functype = spec.functionType(T);
            const func: functype = @ptrCast(@alignCast(spec.func));

            if (functype == (*const fn (*T) anyerror!void)) {
                func(data) catch @panic(spec.name);
            } else if (functype == (*const fn (*T, []const u8) anyerror!void)) {
                const x1 = wrenGetSlotString(vm, 1);
                func(data, std.mem.span(x1)) catch @panic(spec.name);
            }
        }
    };

    return .{
        .name = spec.name,
        .func = container.invoke,
    };
}

pub fn foreignModuleSpecs(comptime T: type) [@typeInfo(T.Modules).@"struct".decls.len]ForeignModuleSpec {
    const decls = std.meta.declarations(T.Modules);
    var specs: [decls.len]ForeignModuleSpec = undefined;
    var i = 0;
    inline for (decls) |decl| {
        specs[i] = .{
            .module_name = decl.name,
            .module_info = @typeInfo(@field(T.Modules, decl.name)),
            .module_classes = foreignClassSpecs(@field(T.Modules, decl.name)),
        };
        i += 1;
    }
    return specs;
}

fn foreignClassSpecs(comptime T: type) []const ForeignClassSpec {
    const decls = std.meta.declarations(T);
    var specs: [decls.len]ForeignClassSpec = undefined;
    var i = 0;
    inline for (decls) |decl| {
        specs[i] = .{
            .class_name = decl.name,
            .class_info = @typeInfo(@field(T, decl.name)),
            .class_functions = functionSpecs(@field(T, decl.name)),
        };
        i += 1;
    }
    const specs_final = specs;
    return &specs_final;
}

fn functionSpecs(comptime T: type) []const FunctionSpec {
    const decls = std.meta.declarations(T);
    var specs: [decls.len]FunctionSpec = undefined;
    var i = 0;
    inline for (decls) |decl| {
        specs[i] = .{
            .name = decl.name,
            .signature = @typeName(@typeInfo(@TypeOf(@field(T, decl.name))).@"fn".params[0].type.?),
            .func = @field(T, decl.name),
            .params = @typeInfo(@TypeOf(@field(T, decl.name))).@"fn".params,
        };
        i += 1;
    }
    const specs_final = specs;
    return &specs_final;
}

// Zig-friendly wrapper around Wren VM
pub fn VM(comptime UserData: type) type {
    return struct {
        ptr: *WrenVM,
        user_data: *UserData,
        allocator: std.mem.Allocator,

        const Self = @This();

        const foreign_function_count = blk: {
            var i = 0;
            for (foreignModuleSpecs(UserData)) |module_spec| {
                for (module_spec.module_classes) |class| {
                    i += class.class_functions.len;
                }
            }
            break :blk i;
        };

        const foreign_functions: [foreign_function_count]ForeignFunction = blk: {
            var fns: [foreign_function_count]ForeignFunction = undefined;
            var i = 0;
            for (foreignModuleSpecs(UserData)) |module| {
                for (module.module_classes) |class| {
                    for (class.class_functions) |spec| {
                        fns[i] = getForeignFunction(UserData, spec);
                        i += 1;
                    }
                }
            }
            break :blk fns;
        };

        pub fn init(user_data: *UserData) !Self {
            var config: WrenConfiguration = .{}; // Initialize with default values
            wrenInitConfiguration(&config);

            // Set up callbacks
            config.writeFn = writeFn;
            config.errorFn = errorFn;
            config.loadModuleFn = null;
            config.bindForeignMethodFn = bindForeignMethodFn;
            config.bindForeignClassFn = null;

            // Use our allocator for Wren's memory management
            config.reallocateFn = reallocateFn;

            // Store user data (allocator and handlers)
            config.userData = user_data;

            const module_specs = foreignModuleSpecs(UserData);
            try std.io.getStdErr().writer().print("foreigns: {d}\n", .{module_specs.len});

            const stderr = std.io.getStdErr().writer();
            inline for (foreign_functions) |f| {
                try stderr.print("{s} {any}\n", .{ f.name, f.func });
            }

            const vm_ptr = wrenNewVM(&config) orelse return error.VMCreationFailed;

            return Self{
                .ptr = vm_ptr,
                .user_data = user_data,
                .allocator = user_data.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Do not destroy user_data: VM does not own it.
            wrenFreeVM(self.ptr);
        }

        pub fn interpret(self: *Self, module_name: []const u8, source: []const u8) !void {
            // Null-terminate strings for C API
            const module_z = try self.allocator.dupeZ(u8, module_name);
            defer self.allocator.free(module_z);

            const source_z = try self.allocator.dupeZ(u8, source);
            defer self.allocator.free(source_z);

            const result = wrenInterpret(self.ptr, module_z, source_z);

            switch (result) {
                WREN_RESULT_SUCCESS => {},
                WREN_RESULT_COMPILE_ERROR => return error.CompileError,
                WREN_RESULT_RUNTIME_ERROR => return error.RuntimeError,
                else => return error.UnknownError,
            }
        }

        fn reallocateFn(memory: ?*anyopaque, new_size: usize, user_data_ptr: *anyopaque) callconv(.c) ?*anyopaque {
            const user_data: *UserData = @ptrCast(@alignCast(user_data_ptr));
            const allocator = user_data.allocator;
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

        // Callback functions for Wren VM
        fn writeFn(vm: *WrenVM, text: [*:0]const u8) callconv(.c) void {
            const ptr = wrenGetUserData(vm);
            const user_data: *UserData = @ptrCast(@alignCast(ptr));
            const str = std.mem.span(text);
            user_data.write(str);
        }

        fn errorFn(
            vm: *WrenVM,
            error_type: WrenErrorType,
            module: ?[*:0]const u8,
            line: c_int,
            message: ?[*:0]const u8,
        ) callconv(.c) void {
            const ptr = wrenGetUserData(vm);
            const user_data: *UserData = @ptrCast(@alignCast(ptr));
            const module_str = if (module) |m| std.mem.span(m) else "";
            const msg_str = if (message) |m| std.mem.span(m) else "";
            user_data.onError(error_type, module_str, line, msg_str);
        }

        fn abortWithError(vm: *WrenVM, msg: []const u8) void {
            wrenSetSlotBytes(vm, 0, msg.ptr, msg.len);
            wrenAbortFiber(vm, 0);
        }

        fn bindForeignMethodFn(
            vm: *WrenVM,
            module: [*:0]const u8,
            className: [*:0]const u8,
            isStatic: bool,
            signature: [*:0]const u8,
        ) callconv(.c) WrenForeignMethodFn {
            _ = vm; // autofix
            std.debug.print("bindForeignMethodFn: {s}.{s}.{s}\n", .{ module, className, signature });
            std.debug.print("isStatic: {}\n", .{isStatic});

            if (!isStatic) return null;

            inline for (foreign_functions) |f| {
                std.debug.print("hmm {s} {s}\n", .{ f.name, std.mem.sliceTo(signature, "("[0]) });
                if (std.mem.eql(u8, f.name, std.mem.sliceTo(signature, "("[0]))) {
                    return f.func;
                }
            }

            return null;
        }
    };
}

// Simple wrapper for one-shot evaluation
pub fn eval(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const Handlers = struct {
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),

        pub fn write(self: *@This(), text: []const u8) void {
            self.output.appendSlice(text) catch {};
        }

        pub fn onError(self: *@This(), error_type: WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
            switch (error_type) {
                WREN_ERROR_COMPILE => {
                    self.output.appendSlice("[Compile error]") catch {};
                },
                WREN_ERROR_RUNTIME => {
                    self.output.appendSlice("[Runtime error]") catch {};
                },
                WREN_ERROR_STACK_TRACE => {
                    self.output.appendSlice("[Stack trace]") catch {};
                },
            }
            _ = module;
            _ = line;
            _ = message;
        }
    };
    const WrenVMType = VM(Handlers);
    var handlers = Handlers{ .allocator = allocator, .output = &output };
    var vm = try WrenVMType.init(&handlers);
    defer vm.deinit();

    // No foreign modules in this one-shot helper, but call anyway to allow future expansion
    try vm.registerForeignModules();
    try vm.interpret("main", source);

    return output.toOwnedSlice();
}

// Tests
test "wren basic evaluation" {
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

test "wren allocation tracking" {
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

test "wren error handling" {
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

test "TrackedAllocator" {
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

// Additional VM init variants tests removed for concision
