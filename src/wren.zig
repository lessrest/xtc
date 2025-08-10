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

// // Zig allocator wrapper for Wren's reallocate function
// fn wrenReallocate(memory: ?*anyopaque, new_size: usize, user_data: *anyopaque) callconv(.c) ?*anyopaque {
//     const ptr: *UserData = @ptrCast(@alignCast(user_data));
//     const allocator = @ptrCast(@alignCast(ptr.*.allocator));
//     const tracked = TrackedAllocator{ .allocator = allocator };

//     if (new_size == 0) {
//         // Free memory
//         if (memory) |mem| {
//             const ptr: [*]u8 = @ptrCast(mem);
//             tracked.free(ptr);
//         }
//         return null;
//     } else if (memory) |mem| {
//         // Realloc existing memory
//         const old_ptr: [*]u8 = @ptrCast(mem);
//         return tracked.realloc(old_ptr, new_size);
//     } else {
//         // Allocate new memory
//         return tracked.alloc(new_size);
//     }
// }

pub fn create(t: type, x: *t) !VM(t) {
    return try VM(t).init(x);
}

// Zig-friendly wrapper around Wren VM
pub fn VM(comptime UserData: type) type {
    return struct {
        ptr: *WrenVM,
        user_data: *UserData,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(user_data: *UserData) !Self {
            var config: WrenConfiguration = .{}; // Initialize with default values
            wrenInitConfiguration(&config);

            // Set up callbacks
            config.writeFn = writeFn;
            config.errorFn = errorFn;
            config.loadModuleFn = null;
            config.bindForeignMethodFn = null;
            config.bindForeignClassFn = null;

            // Use our allocator for Wren's memory management
            config.reallocateFn = reallocateFn;

            // Store user data (allocator and handlers)
            config.userData = user_data;

            const vm_ptr = wrenNewVM(&config) orelse return error.VMCreationFailed;

            return Self{
                .ptr = vm_ptr,
                .user_data = user_data,
                .allocator = user_data.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self.user_data);
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
            module: [*:0]const u8,
            line: c_int,
            message: [*:0]const u8,
        ) callconv(.c) void {
            const ptr = wrenGetUserData(vm);
            const user_data: *UserData = @ptrCast(@alignCast(ptr));
            const module_str = std.mem.span(module);
            const msg_str = std.mem.span(message);
            user_data.onError(error_type, module_str, line, msg_str);
        }
    };
}

// Simple wrapper for one-shot evaluation
pub fn eval(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const Handlers = struct {
        output: *std.ArrayList(u8),

        pub fn write(self: @This(), text: []const u8) void {
            self.output.appendSlice(text) catch {};
        }

        pub fn onError(self: @This(), error_type: WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
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
    var vm = try WrenVMType.init(allocator, Handlers{ .output = &output });
    defer vm.deinit();

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

test "VM with custom writer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with different writer types
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    const handlers = .{
        .writer = fbs.writer(),
        .errorHandler = struct {
            fn errorHandler(error_type: WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
                _ = error_type;
                _ = module;
                _ = line;
                _ = message;
                // Just ignore errors for this test
            }
        }.errorHandler,
    };
    const WrenVMType = VM(handlers);
    var vm = try WrenVMType.init(allocator);
    defer vm.deinit();

    try vm.interpret("main",
        \\System.print("Hello to fixed buffer!")
        \\System.print("Numbers: %(1 + 2 + 3)")
    );

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello to fixed buffer!") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Numbers: 6") != null);
}

test "VM with stderr writer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test that we can write directly to stderr (this won't be captured in test output)
    const handlers = .{
        .writer = std.io.getStdErr().writer(),
        .errorHandler = struct {
            fn errorHandler(error_type: WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
                _ = error_type;
                _ = module;
                _ = line;
                _ = message;
                // Just ignore errors for this test
            }
        }.errorHandler,
    };
    const WrenVMType = VM(handlers);
    var vm = try WrenVMType.init(allocator);
    defer vm.deinit();

    // This should succeed without throwing
    try vm.interpret("main", "System.print(\"This goes to stderr\")");
}

test "VM with custom error handler" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var error_count: u32 = 0;
    var last_error_type: WrenErrorType = 0;

    const ErrorHandler = struct {
        counter: *u32,
        last_type: *WrenErrorType,

        fn errorHandler(self: @This(), error_type: WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
            _ = module;
            _ = line;
            _ = message;
            self.counter.* += 1;
            self.last_type.* = error_type;
        }
    };

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const handlers = struct {
        writer: @TypeOf(output.writer()),
        errorHandler: ErrorHandler,
    }{
        .writer = output.writer(),
        .errorHandler = ErrorHandler{ .counter = &error_count, .last_type = &last_error_type },
    };

    const WrenVMType = VM(handlers);
    var vm = try WrenVMType.init(allocator);
    defer vm.deinit();

    // This should trigger a compile error
    const result = vm.interpret("main", "invalid_syntax_here...");
    try std.testing.expectError(error.CompileError, result);

    // Check that our custom error handler was called
    try std.testing.expect(error_count > 0);
    try std.testing.expect(last_error_type == WREN_ERROR_COMPILE);
}
