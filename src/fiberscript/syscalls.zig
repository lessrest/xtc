const std = @import("std");

/// Marker type for syscalls that complete asynchronously.
pub const Pending = struct {};

const c = @import("wren.zig");
const Fiber = *c.Handle;

/// Generate a Request union from a syscalls implementation struct.
pub fn RequestUnion(comptime Syscalls: type) type {
    const decls = std.meta.declarations(Syscalls);
    comptime var count: usize = 0;
    inline for (decls) |decl| {
        const value = @field(Syscalls, decl.name);
        if (@typeInfo(@TypeOf(value)) == .@"fn") count += 1;
    }
    var union_fields: [count]std.builtin.Type.UnionField = undefined;
    var enum_fields: [count]std.builtin.Type.EnumField = undefined;
    comptime var idx: usize = 0;
    inline for (decls) |decl| {
        const value = @field(Syscalls, decl.name);
        const value_type = @TypeOf(value);
        if (@typeInfo(value_type) == .@"fn") {
            const fn_info = @typeInfo(value_type).@"fn";
            const PayloadType = fn_info.params[3].type.?;
            union_fields[idx] = .{
                .name = decl.name,
                .type = PayloadType,
                .alignment = @alignOf(PayloadType),
            };
            enum_fields[idx] = .{ .name = decl.name, .value = idx };
            idx += 1;
        }
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

/// Generate a union type representing the return values of each syscall.
pub fn ResultUnion(comptime Syscalls: type) type {
    const decls = std.meta.declarations(Syscalls);
    comptime var count: usize = 0;
    inline for (decls) |decl| {
        const value = @field(Syscalls, decl.name);
        if (@typeInfo(@TypeOf(value)) == .@"fn") count += 1;
    }
    var union_fields: [count]std.builtin.Type.UnionField = undefined;
    var enum_fields: [count]std.builtin.Type.EnumField = undefined;
    comptime var idx: usize = 0;
    inline for (decls) |decl| {
        const value = @field(Syscalls, decl.name);
        const value_type = @TypeOf(value);
        if (@typeInfo(value_type) == .@"fn") {
            var return_type = @typeInfo(value_type).@"fn".return_type.?;
            if (@typeInfo(return_type) == .error_union) {
                return_type = @typeInfo(return_type).error_union.payload;
            }
            const alignment = if (return_type == void) 0 else @alignOf(return_type);
            union_fields[idx] = .{
                .name = decl.name,
                .type = return_type,
                .alignment = alignment,
            };
            enum_fields[idx] = .{ .name = decl.name, .value = idx };
            idx += 1;
        }
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

/// Wrapper union distinguishing between immediate results and pending operations.
pub fn SyscallResult(comptime Syscalls: type) type {
    return union(enum) {
        immediate: ResultUnion(Syscalls),
        pending: void,
    };
}

/// Generate slot parsing function for a Request union.
pub fn generateSlotParser(comptime Request: type, comptime Syscalls: type) type {
    return struct {
        pub fn parseRequest(slot_map: anytype) !Request {
            const operation = try slot_map.lookup("operation", []const u8);
            const decls = comptime std.meta.declarations(Syscalls);
            inline for (decls) |decl| {
                const value = @field(Syscalls, decl.name);
                const value_type = @TypeOf(value);
                if (@typeInfo(value_type) == .@"fn" and std.mem.eql(u8, operation, decl.name)) {
                    const PayloadType = @typeInfo(value_type).@"fn".params[3].type.?;
                    const payload_fields = std.meta.fields(PayloadType);
                    var payload: PayloadType = undefined;
                    inline for (payload_fields) |pf| {
                        @field(payload, pf.name) = try slot_map.lookup(pf.name, pf.type);
                    }
                    return @unionInit(Request, decl.name, payload);
                }
            }
            return error.InvalidOperation;
        }
    };
}

pub fn generateResultSetter(comptime Syscalls: type) type {
    const ResultType = ResultUnion(Syscalls);
    return struct {
        pub fn set(
            work: *@import("slots.zig").SlotBuilder,
            index: c_int,
            result: ResultType,
        ) !void {
            inline for (@typeInfo(ResultType).@"union".fields) |field| {
                if (field.type != Pending) {
                    if (std.mem.eql(u8, field.name, @tagName(result))) {
                        _ = work.set(index, @field(result, field.name));
                        return;
                    }
                }
            }
            return error.InvalidResult;
        }
    };
}

/// Generate Wren source code defining foreign classes for each syscall payload.
pub fn generateWrenModule(comptime Syscalls: type) []const u8 {
    const Request = RequestUnion(Syscalls);
    comptime var source: []const u8 = "";
    inline for (@typeInfo(Request).@"union".fields) |field| {
        const Payload = field.type;
        const class_name = pascalCase(field.name);
        source = source ++ "foreign class " ++ class_name ++ " {\n";
        source = source ++ "  construct new(";
        const params = std.meta.fields(Payload);
        inline for (params, 0..) |pf, idx| {
            if (idx != 0) source = source ++ ", ";
            source = source ++ pf.name;
        }
        source = source ++ ") {}\n";
        source = source ++ "}\n";
    }
    source = source ++ "foreign class SubmissionBatch {\n";
    source = source ++ "  construct new(capacity) {}\n";
    source = source ++ "  foreign add(request)\n";
    source = source ++ "}\n";
    source = source ++ "foreign class CompletionBatch {\n";
    source = source ++ "  foreign wait(n)\n";
    source = source ++ "  foreign waitAll()\n";
    source = source ++ "}\n";
    return source;
}

pub fn pascalCase(comptime name: []const u8) []const u8 {
    if (name.len == 0) return "";
    const first = if (name[0] >= 'a' and name[0] <= 'z')
        name[0] - ('a' - 'A')
    else
        name[0];
    return std.fmt.comptimePrint("{c}{s}", .{ first, name[1..] });
}

/// Generate a dispatcher that bridges Wren fiber yields to syscall implementations.
pub fn generateDispatcher(
    comptime Syscalls: type,
    comptime Engine: type,
    comptime Context: type,
) type {
    return struct {
        const RequestType = RequestUnion(Syscalls);
        const ResultType = ResultUnion(Syscalls);
        const DispatchResult = SyscallResult(Syscalls);

        engine: *Engine,
        context: *Context,

        /// Process a single request from a yielding fiber
        pub fn dispatch(self: *@This(), request: RequestType, fiber: *c.Handle) !DispatchResult {
            const decls = comptime std.meta.declarations(Syscalls);
            switch (request) {
                inline else => |payload, tag| {
                    inline for (decls) |decl| {
                        const value = @field(Syscalls, decl.name);
                        const value_type = @TypeOf(value);
                        if (@typeInfo(value_type) == .@"fn" and comptime std.mem.eql(u8, @tagName(tag), decl.name)) {
                            const fn_info = @typeInfo(value_type).@"fn";
                            const ReturnType = fn_info.return_type.?;
                            if (ReturnType == Pending) {
                                try value(self.engine, self.context, fiber, payload);
                                return .{ .pending = {} };
                            } else if (ReturnType == void) {
                                try value(self.engine, self.context, fiber, payload);
                                return .{ .immediate = @unionInit(ResultType, decl.name, {}) };
                            } else {
                                const val = try value(self.engine, self.context, fiber, payload);
                                return .{ .immediate = @unionInit(ResultType, decl.name, val) };
                            }
                        }
                    }
                    std.debug.print("unknown syscall: {any}\n", .{tag});
                    return error.UnknownSyscall;
                },
            }
        }
    };
}

// ------------------------ Tests ----------------------------

const testing = std.testing;

const TestEngine = struct {};

const TestContext = struct {
    output_buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{ .output_buffer = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *TestContext) void {
        self.output_buffer.deinit();
    }
};

const TestSyscalls = struct {
    pub fn print(engine: *TestEngine, context: *TestContext, fiber: Fiber, payload: struct { message: []const u8 }) anyerror![]const u8 {
        _ = fiber; // autofix
        _ = engine;
        try context.output_buffer.appendSlice(payload.message);
        return payload.message;
    }

    pub fn sleep(engine: *TestEngine, context: *TestContext, fiber: Fiber, payload: struct { duration_ms: u64 }) anyerror!void {
        _ = engine;
        _ = context;
        _ = payload;
        _ = fiber;
    }
};

test "can generate trampoline dispatcher" {
    const Dispatcher = generateDispatcher(TestSyscalls, TestEngine, TestContext);
    var engine = TestEngine{};
    var context = TestContext.init(testing.allocator);
    defer context.deinit();
    const fiber: Fiber = undefined;
    var dispatcher = Dispatcher{ .engine = &engine, .context = &context };
    const request = Dispatcher.RequestType{ .print = .{ .message = "hello" } };
    const result = try dispatcher.dispatch(request, fiber);
    switch (result) {
        .immediate => |im| switch (im) {
            .print => |msg| try testing.expectEqualStrings("hello", msg),
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }
    try testing.expectEqualStrings("hello", context.output_buffer.items);
}
