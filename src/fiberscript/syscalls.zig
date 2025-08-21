const std = @import("std");
const testing = std.testing;
const c = @import("wren.zig");

/// Example context type for testing
const TestContext = struct {
    output_buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{ .output_buffer = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *TestContext) void {
        self.output_buffer.deinit();
    }
};

/// Example syscalls interface parameterized by context type
pub fn TestSyscalls(comptime Context: type) type {
    return struct {
        const Self = @This();

        print: *const fn (*Context, struct { message: []const u8 }) anyerror![]const u8,
        readFile: *const fn (*Context, struct { path: []const u8 }) anyerror![]const u8,
        sleep: *const fn (*Context, struct { duration_ms: u64 }) anyerror!void,

        /// Extract payload type for a given operation
        pub fn Payload(comptime operation: std.meta.FieldEnum(Self)) type {
            const field_info = std.meta.fieldInfo(Self, operation);
            const ptr_info = @typeInfo(field_info.type).pointer;
            const func_info = @typeInfo(ptr_info.child).@"fn";
            return func_info.params[1].type.?;
        }
    };
}

/// DOM-focused syscalls for XTC
pub fn DOMSyscalls(comptime Context: type) type {
    return struct {
        const Self = @This();

        updateText: *const fn (*Context, struct { nodeId: u32, text: []const u8 }) anyerror!void,
        updateClass: *const fn (*Context, struct { nodeId: u32, className: []const u8 }) anyerror!void,
        createElement: *const fn (*Context, struct { style: []const u8 }) anyerror!u32,
        appendChild: *const fn (*Context, struct { parentId: u32, childId: u32 }) anyerror!void,

        /// Extract payload type for a given operation
        pub fn Payload(comptime operation: std.meta.FieldEnum(Self)) type {
            const field_info = std.meta.fieldInfo(Self, operation);
            const ptr_info = @typeInfo(field_info.type).pointer;
            const func_info = @typeInfo(ptr_info.child).@"fn";
            return func_info.params[1].type.?;
        }
    };
}

/// TTY/Live Session syscalls for XTC browser functionality
pub fn TTYSyscalls(comptime Context: type) type {
    return struct {
        const Self = @This();

        // DOM operations
        createElement: *const fn (*Context, struct { style: []const u8 }) anyerror!u32,
        updateText: *const fn (*Context, struct { nodeId: u32, text: []const u8 }) anyerror!void,
        updateClass: *const fn (*Context, struct { nodeId: u32, className: []const u8 }) anyerror!void,
        appendChild: *const fn (*Context, struct { parentId: u32, childId: u32 }) anyerror!void,
        removeChild: *const fn (*Context, struct { parentId: u32, childId: u32 }) anyerror!void,

        // Rendering operations
        requestRender: *const fn (*Context, struct {}) anyerror!void,
        clearScreen: *const fn (*Context, struct {}) anyerror!void,
        requestAnimationFrame: *const fn (*Context, struct {}) anyerror!void,
        setTimeout: *const fn (*Context, struct { delayMs: f64 }) anyerror!void,

        // Event handling
        addEventListener: *const fn (*Context, struct { eventType: []const u8 }) anyerror!void,
        getViewportSize: *const fn (*Context, struct {}) anyerror!void,
        setViewportSize: *const fn (*Context, struct { width: u32, height: u32 }) anyerror!void,

        /// Extract payload type for a given operation
        pub fn Payload(comptime operation: std.meta.FieldEnum(Self)) type {
            const field_info = std.meta.fieldInfo(Self, operation);
            const ptr_info = @typeInfo(field_info.type).pointer;
            const func_info = @typeInfo(ptr_info.child).@"fn";
            return func_info.params[1].type.?;
        }
    };
}

/// Example implementation as function declarations using the interface's payload types
fn buildTestSyscallsImpl(comptime SyscallsType: type) type {
    return struct {
        pub fn print(context: *TestContext, payload: SyscallsType.Payload(.print)) anyerror![]const u8 {
            try context.output_buffer.appendSlice(payload.message);
            return payload.message;
        }

        pub fn readFile(context: *TestContext, payload: SyscallsType.Payload(.readFile)) anyerror![]const u8 {
            _ = context;
            if (std.mem.eql(u8, payload.path, "test.txt")) {
                return "file contents";
            }
            return error.FileNotFound;
        }

        pub fn sleep(context: *TestContext, payload: SyscallsType.Payload(.sleep)) anyerror!void {
            _ = context;
            _ = payload.duration_ms;
            return;
        }
    };
}

/// Comptime functor: transforms struct with fn declarations into vtable with function pointers
/// Validates that the implementation matches the interface at compile time
pub fn bindSyscalls(comptime Interface: type, comptime Impl: type) Interface {
    var result: Interface = undefined;

    // For each field in the interface, bind the corresponding implementation function
    inline for (std.meta.fields(Interface)) |field| {
        if (!@hasDecl(Impl, field.name)) {
            @compileError("Implementation missing function: " ++ field.name);
        }

        const impl_fn = @field(Impl, field.name);
        const expected_type = field.type;
        const actual_type = @TypeOf(&impl_fn);

        // Validate that the function signature matches
        if (expected_type != actual_type) {
            @compileError(std.fmt.comptimePrint("Function signature mismatch for {s}: expected {}, got {}", .{ field.name, expected_type, actual_type }));
        }

        @field(result, field.name) = &impl_fn;
    }

    return result;
}

/// Generate a Request union type from a syscalls struct
pub fn RequestUnion(comptime Syscalls: type) type {
    const syscall_fields = std.meta.fields(Syscalls);

    // Ring meta-ops + syscalls
    var union_fields: [syscall_fields.len + 2]std.builtin.Type.UnionField = undefined;

    // Add ring meta-operations
    union_fields[0] = .{
        .name = "Ring.push",
        .type = struct { ring: *c.Handle },
        .alignment = @alignOf(struct { ring: *c.Handle }),
    };

    union_fields[1] = .{
        .name = "Ring.pull",
        .type = struct { ring: *c.Handle },
        .alignment = @alignOf(struct { ring: *c.Handle }),
    };

    // Add syscalls - extract parameter struct from function pointer signature
    for (syscall_fields, 0..) |field, i| {
        // Handle function pointer: *const fn(...)
        const ptr_info = @typeInfo(field.type).pointer;
        const func_info = @typeInfo(ptr_info.child).@"fn";

        // Get the payload struct (second parameter, after context)
        const param_type = func_info.params[1].type.?;

        union_fields[i + 2] = .{
            .name = field.name,
            .type = param_type,
            .alignment = @alignOf(param_type),
        };
    }

    // Generate the tag enum
    var enum_fields: [union_fields.len]std.builtin.Type.EnumField = undefined;
    for (union_fields, 0..) |field, i| {
        enum_fields[i] = .{
            .name = field.name,
            .value = i,
        };
    }

    const TagEnum = @Type(.{
        .@"enum" = .{
            .tag_type = u32,
            .fields = &enum_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });

    return @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = TagEnum,
            .fields = &union_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

/// Generate slot parsing function for a Request union
pub fn generateSlotParser(comptime Request: type, comptime Syscalls: type) type {
    return struct {
        pub fn parseRequest(slot_map: anytype) !Request {
            const operation = try slot_map.lookup("operation", []const u8);

            // Handle ring meta-operations
            if (std.mem.eql(u8, operation, "Ring.push")) {
                const ring = try slot_map.lookup("ring", *c.Handle);
                return Request{ .@"Ring.push" = .{ .ring = ring } };
            }

            if (std.mem.eql(u8, operation, "Ring.pull")) {
                const ring = try slot_map.lookup("ring", *c.Handle);
                return Request{ .@"Ring.pull" = .{ .ring = ring } };
            }

            // Generate syscall parsing - comptime loop
            const syscall_fields = comptime std.meta.fields(Syscalls);
            inline for (syscall_fields) |field| {
                if (std.mem.eql(u8, operation, field.name)) {
                    // Handle function pointer: *const fn(...)
                    const ptr_info = @typeInfo(field.type).pointer;
                    const func_info = @typeInfo(ptr_info.child).@"fn";
                    const PayloadType = func_info.params[1].type.?; // Second param after context
                    const payload_fields = std.meta.fields(PayloadType);

                    var payload: PayloadType = undefined;
                    inline for (payload_fields) |payload_field| {
                        @field(payload, payload_field.name) = try slot_map.lookup(payload_field.name, payload_field.type);
                    }

                    return @unionInit(Request, field.name, payload);
                }
            }

            return error.InvalidOperation;
        }
    };
}

/// Generate a trampoline dispatcher that bridges Wren fiber yields to syscall implementations.
///
/// ## The Trampoline Pattern
///
/// A "trampoline" in this context is a control flow mechanism that handles cooperative
/// multitasking between Wren fibers and native syscall implementations. It works like this:
///
/// 1. **Fiber Execution**: Wren fibers run until they need to perform I/O or other syscalls
/// 2. **Yield Request**: Fiber yields control with a structured request (ring.post() + ring.push())
/// 3. **Trampoline Processing**: Native code processes the request and produces a result
/// 4. **Fiber Resumption**: Fiber is resumed with the result (ring.pull())
///
/// ## Integration with Ring System
///
/// The ring acts as a structured message passing system:
/// - **Submission**: `ring.post()` queues operations, `ring.push()` yields to trampoline
/// - **Processing**: Trampoline dequeues operations via `ring.grab()`, dispatches to syscalls
/// - **Completion**: Results go to completion queue via `ring.give()`, fiber gets them via `ring.pull()`
///
/// ## Syscall Dispatch Flow
///
/// ```
/// Wren Fiber                Ring                 Trampoline              Syscalls
/// -----------                ----                 ----------              --------
/// ring.post(req) ──────────► submission_queue
/// ring.push() ──────────────► yield(Ring.push) ──► grab() ──────────────► dispatch
///                                                   │                     │
///                                                   │                     ▼
///                                                   │                    fn(*Context, Payload) Result
///                                                   │                     │
///                                                   ◄─────────────────────┘
///                                                   │
/// result ◄─────────────────── Ring.pull ◄─────────── give(result)
/// ```
///
/// ## Generated Dispatch Logic
///
/// The trampoline generator creates a switch statement that:
/// 1. Parses the Request union (generated from syscalls interface)
/// 2. Extracts the context and payload
/// 3. Calls the appropriate syscall function: `syscall_impl.operation(context, payload)`
/// 4. Handles the return value and fiber resumption
///
pub fn generateTrampoline(comptime Syscalls: type, comptime Context: type) type {
    return struct {
        const RequestType = RequestUnion(Syscalls);

        syscalls: Syscalls,
        context: *Context,

        /// Process a single request from a yielding fiber
        pub fn dispatch(self: *@This(), request: RequestType) !void {
            const syscall_fields = comptime std.meta.fields(Syscalls);

            switch (request) {
                // Ring meta-operations are handled by the VM context
                .@"Ring.push" => return error.ShouldBeHandledByVMContext,
                .@"Ring.pull" => return error.ShouldBeHandledByVMContext,

                // Generated syscall dispatch
                inline else => |payload, tag| {
                    // Find the matching syscall field
                    inline for (syscall_fields) |field| {
                        if (comptime std.mem.eql(u8, @tagName(tag), field.name)) {
                            const syscall_fn = @field(self.syscalls, field.name);
                            const result = syscall_fn(self.context, payload) catch |err| return err;
                            _ = result;
                            return;
                        }
                    }

                    std.debug.print("unknown syscall: {any}\n", .{tag});

                    return error.UnknownSyscall;
                },
            }
        }
    };
}

/// Generate Wren operation constants for efficient dispatch
pub fn generateWrenConstants(comptime Syscalls: type, allocator: std.mem.Allocator) ![]const u8 {
    const syscall_fields = comptime std.meta.fields(Syscalls);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    var writer = result.writer();

    // Generate base Request class with common patterns
    try writer.print("class Request {{\n", .{});
    try writer.print("  // Base class for all syscall requests\n", .{});
    try writer.print("  construct new() {{}}\n", .{});
    try writer.print("  \n", .{});
    try writer.print("  // Submit this request to the ring and yield\n", .{});
    try writer.print("  submit() {{\n", .{});
    try writer.print("    ring.post(this)\n", .{});
    try writer.print("    ring.push()\n", .{});
    try writer.print("    return ring.pull()\n", .{});
    try writer.print("  }}\n", .{});
    try writer.print("  \n", .{});
    try writer.print("  // Get the operation ID for fast dispatch\n", .{});
    try writer.print("  static id {{ -1 }} // Override in subclasses\n", .{});
    try writer.print("}}\n\n", .{});

    // Generate request classes inheriting from Request
    inline for (syscall_fields, 0..) |field, i| {
        try writer.print("class {s}Request is Request {{\n", .{field.name});
        try writer.print("  static id {{ {d} }}\n", .{i});

        // Generate constructor with payload field parameters
        const PayloadType = extractPayloadTypeFromField(field);
        const payload_fields = std.meta.fields(PayloadType);

        try writer.print("  construct new(", .{});
        inline for (payload_fields, 0..) |pfield, j| {
            try writer.print("{s}", .{pfield.name});
            if (j < payload_fields.len - 1) try writer.print(", ", .{});
        }
        try writer.print(") {{\n", .{});
        try writer.print("    super()\n", .{});
        inline for (payload_fields) |pfield| {
            try writer.print("    _{s} = {s}\n", .{ pfield.name, pfield.name });
        }
        try writer.print("  }}\n", .{});

        // Generate getters for payload fields
        inline for (payload_fields) |pfield| {
            try writer.print("  {s} {{ _{s} }}\n", .{ pfield.name, pfield.name });
        }

        try writer.print("}}\n\n", .{});
    }

    return result.toOwnedSlice();
}

/// Helper to extract payload type from a syscall field (function pointer)
fn extractPayloadTypeFromField(comptime field: std.builtin.Type.StructField) type {
    const ptr_info = @typeInfo(field.type).pointer;
    const func_info = @typeInfo(ptr_info.child).@"fn";
    return func_info.params[1].type.?; // Second param after context
}

/// Generate foreign class system for request types
/// Each syscall operation gets a foreign class that directly contains the payload struct
pub fn generateRequestClasses(comptime Syscalls: type) type {
    const syscall_fields = std.meta.fields(Syscalls);

    return struct {
        const Self = @This();

        /// Request wrapper that includes operation index + payload
        pub fn RequestData(comptime PayloadType: type, comptime operation_index: u32) type {
            return struct {
                operation_id: u32 = operation_index,
                payload: PayloadType,

                const OpIndex = operation_index;
            };
        }

        /// Bind foreign class for a specific request type
        pub fn bindForeignClass(vm: *c.VM, module: [*:0]const u8, className: [*:0]const u8) c.ForeignClassMethods {
            _ = vm;
            _ = module;

            const class_name = std.mem.span(className);

            // Match class name to operation
            inline for (syscall_fields, 0..) |field, i| {
                const expected_name = field.name ++ "Request";
                if (std.mem.eql(u8, class_name, expected_name)) {
                    const PayloadType = extractPayloadType(field.type);
                    const RequestDataType = RequestData(PayloadType, i);

                    return c.ForeignClassMethods{
                        .allocate = generateAllocator(RequestDataType),
                        .finalize = null,
                    };
                }
            }

            return c.ForeignClassMethods{ .allocate = null, .finalize = null };
        }

        /// Generate allocator for specific request type
        fn generateAllocator(comptime RequestDataType: type) c.ForeignMethodFn {
            return struct {
                fn allocate(vm: *c.VM) callconv(.C) void {
                    const foreign_data = c.wrenSetSlotNewForeign(vm, 0, 0, @sizeOf(RequestDataType));
                    const request_data: *RequestDataType = @ptrCast(@alignCast(foreign_data));

                    // Initialize with operation index and zero payload
                    request_data.* = .{
                        .operation_id = RequestDataType.OpIndex,
                        .payload = std.mem.zeroes(@TypeOf(request_data.payload)),
                    };

                    // Initialize payload from constructor arguments
                    const payload_fields = std.meta.fields(@TypeOf(request_data.payload));
                    inline for (payload_fields, 0..) |field, slot_idx| {
                        const slot = @as(c_int, @intCast(slot_idx + 1)); // Skip receiver in slot 0

                        switch (field.type) {
                            []const u8 => {
                                if (c.wrenGetSlotType(vm, slot) == @intFromEnum(c.Type.string)) {
                                    const str = std.mem.span(c.wrenGetSlotString(vm, slot));
                                    @field(request_data.payload, field.name) = str;
                                }
                            },
                            u64 => {
                                if (c.wrenGetSlotType(vm, slot) == @intFromEnum(c.Type.num)) {
                                    const num = c.wrenGetSlotDouble(vm, slot);
                                    @field(request_data.payload, field.name) = @intFromFloat(num);
                                }
                            },
                            else => @compileError("Unsupported payload field type: " ++ @typeName(field.type)),
                        }
                    }
                }
            }.allocate;
        }

        /// Extract payload type from function pointer
        fn extractPayloadType(comptime func_ptr_type: type) type {
            const ptr_info = @typeInfo(func_ptr_type).pointer;
            const func_info = @typeInfo(ptr_info.child).@"fn";
            return func_info.params[1].type.?; // Second param after context
        }

        /// Fast dispatch - just read the operation_id from foreign data
        pub fn dispatchRequest(foreign_data: *anyopaque) !RequestUnion(Syscalls) {
            // Try each possible RequestData type to find the matching one
            inline for (syscall_fields, 0..) |field, op_id| {
                const PayloadType = extractPayloadType(field.type);
                const RequestDataType = RequestData(PayloadType, op_id);
                const request_data: *RequestDataType = @ptrCast(@alignCast(foreign_data));

                if (request_data.operation_id == op_id) {
                    return @unionInit(RequestUnion(Syscalls), field.name, request_data.payload);
                }
            }

            return error.InvalidOperationId;
        }
    };
}

test "can generate Request union from syscalls struct" {
    const SyscallsType = TestSyscalls(TestContext);
    const Request = RequestUnion(SyscallsType);

    // Should have ring ops + syscalls
    const union_info = @typeInfo(Request).@"union";
    try testing.expect(union_info.fields.len == 5); // Ring.push, Ring.pull, print, readFile, sleep

    // Check field names are correct
    try testing.expectEqualStrings("Ring.push", union_info.fields[0].name);
    try testing.expectEqualStrings("Ring.pull", union_info.fields[1].name);
    try testing.expectEqualStrings("print", union_info.fields[2].name);
    try testing.expectEqualStrings("readFile", union_info.fields[3].name);
    try testing.expectEqualStrings("sleep", union_info.fields[4].name);
}

test "generated Request union has correct field types" {
    const SyscallsType = TestSyscalls(TestContext);
    const Request = RequestUnion(SyscallsType);

    // Test we can create instances with meaningful field names
    const print_req = Request{ .print = .{ .message = "hello" } };
    const read_req = Request{ .readFile = .{ .path = "test.txt" } };
    const sleep_req = Request{ .sleep = .{ .duration_ms = 1000 } };

    // Basic smoke test that types work
    switch (print_req) {
        .print => |args| try testing.expectEqualStrings("hello", args.message),
        else => try testing.expect(false),
    }

    switch (read_req) {
        .readFile => |args| try testing.expectEqualStrings("test.txt", args.path),
        else => try testing.expect(false),
    }

    switch (sleep_req) {
        .sleep => |args| try testing.expect(args.duration_ms == 1000),
        else => try testing.expect(false),
    }
}

const SlotValue = union(enum) {
    string: []const u8,
    number: u64,
    ring: *anyopaque,
};

const MockSlotMap = struct {
    data: std.StringHashMap(SlotValue),
    pub fn init(allocator: std.mem.Allocator) MockSlotMap {
        return .{ .data = std.StringHashMap(SlotValue).init(allocator) };
    }

    pub fn deinit(self: *MockSlotMap) void {
        self.data.deinit();
    }

    pub fn put(self: *MockSlotMap, key: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .pointer => |ptr_info| {
                switch (@typeInfo(ptr_info.child)) {
                    .int => |int_info| {
                        if (int_info.bits == 8) {
                            // Handle []const u8
                            const str: []const u8 = value;
                            try self.data.put(key, .{ .string = str });
                        } else {
                            @compileError("Unsupported pointer type: " ++ @typeName(T));
                        }
                    },
                    .array => |arr_info| {
                        if (arr_info.child == u8) {
                            // Handle *const [N:0]u8 (string literals)
                            const str: []const u8 = value;
                            try self.data.put(key, .{ .string = str });
                        } else {
                            @compileError("Unsupported array pointer type: " ++ @typeName(T));
                        }
                    },
                    else => {
                        @compileError("Unsupported pointer type: " ++ @typeName(T));
                    },
                }
            },
            .int => {
                try self.data.put(key, .{ .number = @intCast(value) });
            },
            else => {
                if (T == *anyopaque) {
                    try self.data.put(key, .{ .ring = value });
                } else {
                    @compileError("Unsupported type: " ++ @typeName(T));
                }
            },
        }
    }

    pub fn lookup(self: *MockSlotMap, key: []const u8, comptime T: type) !T {
        const entry = self.data.get(key) orelse return error.KeyNotFound;

        if (T == []const u8) {
            switch (entry) {
                .string => |s| return s,
                else => return error.TypeMismatch,
            }
        } else if (T == u64) {
            switch (entry) {
                .number => |n| return n,
                else => return error.TypeMismatch,
            }
        } else if (T == *anyopaque) {
            switch (entry) {
                .ring => |r| return r,
                else => return error.TypeMismatch,
            }
        }

        return error.UnsupportedType;
    }
};

test "can generate slots parser" {
    const SyscallsType = TestSyscalls(TestContext);
    const Request = RequestUnion(SyscallsType);
    const Parser = generateSlotParser(Request, SyscallsType);

    var slot_map = MockSlotMap.init(testing.allocator);
    defer slot_map.deinit();

    // Test parsing a print request
    try slot_map.put("operation", "print");
    try slot_map.put("message", "hello world");

    const request = try Parser.parseRequest(&slot_map);
    switch (request) {
        .print => |args| try testing.expectEqualStrings("hello world", args.message),
        else => try testing.expect(false),
    }
}

test "can bind syscalls implementation to interface" {
    const SyscallsType = TestSyscalls(TestContext);
    const TestImpl = buildTestSyscallsImpl(SyscallsType);
    const syscalls_impl = bindSyscalls(SyscallsType, TestImpl);

    // Test that we can extract payload types
    const PrintPayload = SyscallsType.Payload(.print);
    const ReadFilePayload = SyscallsType.Payload(.readFile);
    const SleepPayload = SyscallsType.Payload(.sleep);

    // Test payload type correctness
    try testing.expect(@hasField(PrintPayload, "message"));
    try testing.expect(@hasField(ReadFilePayload, "path"));
    try testing.expect(@hasField(SleepPayload, "duration_ms"));

    _ = syscalls_impl; // Ensure it compiles
}

test "can generate trampoline dispatcher" {
    const SyscallsType = TestSyscalls(TestContext);
    const Trampoline = generateTrampoline(SyscallsType, TestContext);

    var context = TestContext.init(testing.allocator);
    defer context.deinit();

    // Use the binding system to create the implementation
    const TestImpl = buildTestSyscallsImpl(SyscallsType);
    const syscalls_impl = bindSyscalls(SyscallsType, TestImpl);

    var trampoline = Trampoline{
        .syscalls = syscalls_impl,
        .context = &context,
    };

    // Test dispatching a print request
    const print_request = Trampoline.RequestType{ .print = .{ .message = "hello trampoline" } };
    try trampoline.dispatch(print_request);

    // Verify the syscall was called
    try testing.expectEqualStrings("hello trampoline", context.output_buffer.items);

    // Test dispatching a readFile request
    const read_request = Trampoline.RequestType{ .readFile = .{ .path = "test.txt" } };
    try trampoline.dispatch(read_request);
}

test "can generate foreign class system for requests" {
    const SyscallsType = TestSyscalls(TestContext);
    const RequestClasses = generateRequestClasses(SyscallsType);

    // Test RequestData structure
    const PrintPayload = SyscallsType.Payload(.print);
    const PrintRequestData = RequestClasses.RequestData(PrintPayload, 0);

    // Verify structure
    try testing.expect(@hasField(PrintRequestData, "operation_id"));
    try testing.expect(@hasField(PrintRequestData, "payload"));
    try testing.expect(PrintRequestData.OpIndex == 0);
    // Size check - struct may have padding
    try testing.expect(@sizeOf(PrintRequestData) >= @sizeOf(u32) + @sizeOf(PrintPayload));

    // Test extractPayloadType function using function pointer type
    const print_fn_ptr_type = @TypeOf(@as(*const fn (*TestContext, SyscallsType.Payload(.print)) []const u8, undefined));
    const extracted_payload = RequestClasses.extractPayloadType(print_fn_ptr_type);
    try testing.expect(extracted_payload == PrintPayload);
}

test "foreign class dispatch with operation id" {
    const SyscallsType = TestSyscalls(TestContext);
    const RequestClasses = generateRequestClasses(SyscallsType);

    // Create mock foreign data that looks like a print request
    const PrintPayload = SyscallsType.Payload(.print);
    const PrintRequestData = RequestClasses.RequestData(PrintPayload, 0);

    var mock_request = PrintRequestData{
        .payload = .{ .message = "test message" },
    };

    // Test dispatch
    const dispatched = try RequestClasses.dispatchRequest(&mock_request);
    switch (dispatched) {
        .print => |payload| try testing.expectEqualStrings("test message", payload.message),
        else => try testing.expect(false),
    }
}

test "can generate Wren operation constants" {
    const SyscallsType = TestSyscalls(TestContext);
    const constants = try generateWrenConstants(SyscallsType, testing.allocator);
    defer testing.allocator.free(constants);

    // Check that the generated constants contain expected content
    // Base Request class
    try testing.expect(std.mem.indexOf(u8, constants, "class Request {") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "submit() {") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "ring.post(this)") != null);

    // Specific request classes inheriting from Request
    try testing.expect(std.mem.indexOf(u8, constants, "class printRequest is Request") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "static id { 0 }") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "construct new(message)") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "message { _message }") != null);

    try testing.expect(std.mem.indexOf(u8, constants, "class readFileRequest is Request") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "static id { 1 }") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "construct new(path)") != null);

    try testing.expect(std.mem.indexOf(u8, constants, "class sleepRequest is Request") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "static id { 2 }") != null);
    try testing.expect(std.mem.indexOf(u8, constants, "construct new(duration_ms)") != null);
}

test "complete syscalls system integration" {
    // This demonstrates the complete syscalls system working together
    const SyscallsType = TestSyscalls(TestContext);
    const Request = RequestUnion(SyscallsType);
    const Trampoline = generateTrampoline(SyscallsType, TestContext);
    const RequestClasses = generateRequestClasses(SyscallsType);

    // Verify we can create parsers (tested separately)
    _ = generateSlotParser(Request, SyscallsType);

    // 1. Create syscalls implementation
    const TestImpl = buildTestSyscallsImpl(SyscallsType);
    const syscalls_impl = bindSyscalls(SyscallsType, TestImpl);

    // 2. Set up context and trampoline
    var context = TestContext.init(testing.allocator);
    defer context.deinit();

    var trampoline = Trampoline{
        .syscalls = syscalls_impl,
        .context = &context,
    };

    // 3. Create a foreign class request (simulating Wren foreign object)
    const PrintPayload = SyscallsType.Payload(.print);
    const PrintRequestData = RequestClasses.RequestData(PrintPayload, 0);
    var foreign_request = PrintRequestData{
        .payload = .{ .message = "Hello from foreign class!" },
    };

    // 4. Dispatch foreign class request to get union
    const request = try RequestClasses.dispatchRequest(&foreign_request);

    // 5. Process through trampoline
    try trampoline.dispatch(request);

    // 6. Verify syscall was executed
    try testing.expectEqualStrings("Hello from foreign class!", context.output_buffer.items);

    // 7. Generate Wren constants for runtime
    const constants = try generateWrenConstants(SyscallsType, testing.allocator);
    defer testing.allocator.free(constants);
    try testing.expect(constants.len > 0);
}
