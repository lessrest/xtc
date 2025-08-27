const std = @import("std");

comptime {
    @setEvalBranchQuota(200000);
}

pub const Pending = struct {};
const log = std.log.scoped(.vmsys);

const c = @import("wren.zig");
const FiberID = @import("vm.zig").FiberID;
const SlotBuilder = @import("slots.zig").SlotBuilder;

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
            const actual_type = if (return_type == void) u8 else return_type;
            const alignment = @alignOf(actual_type);
            union_fields[idx] = .{
                .name = decl.name,
                .type = actual_type,
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

pub fn SyscallResult(comptime Syscalls: type) type {
    return union(enum) {
        immediate: ResultUnion(Syscalls),
        pending: Pending,
    };
}

pub fn generateWrenModule(comptime Syscalls: type) []const u8 {
    const Request = RequestUnion(Syscalls);
    comptime var source: []const u8 =
        \\import "xtc" for Core
        \\
        \\class Syscall {
        \\  call() {
        \\    return Core.call(this)
        \\  }
        \\}
        \\
    ;
    inline for (@typeInfo(Request).@"union".fields) |field| {
        const Payload = field.type;
        const class_name = pascalCase(field.name);
        source = source ++ "foreign class " ++ class_name ++ " is Syscall {\n";
        source = source ++ "  construct new(";
        const params = std.meta.fields(Payload);
        inline for (params, 0..) |pf, idx| {
            if (idx != 0) source = source ++ ", ";
            source = source ++ pf.name;
        }
        source = source ++ ") {}\n";
        source = source ++ "}\n";
    }

    return source;
}

pub fn pascalCase(comptime name: []const u8) []const u8 {
    if (name.len == 0) return "";
    const first = if (name[0] >= 'a' and name[0] <= 'z')
        name[0] - ('a' - 'A')
    else
        name[0];
    const head = [_]u8{first};
    return head ++ name[1..];
}

pub fn Syscaller(
    comptime Syscalls: type,
    comptime Engine: type,
    comptime Context: type,
) type {
    comptime {
        @setEvalBranchQuota(200000);
    }
    return struct {
        const RequestType = RequestUnion(Syscalls);
        const ResultType = ResultUnion(Syscalls);
        const DispatchResult = SyscallResult(Syscalls);

        engine: *Engine,
        context: *Context,

        pub fn dispatch(
            self: *@This(),
            request: RequestType,
            fiber: FiberID,
            slots: *SlotBuilder,
        ) !DispatchResult {
            switch (request) {
                inline else => |payload, tag| {
                    const name = @tagName(tag);
                    const function = @field(Syscalls, name);
                    const function_type = @TypeOf(function);

                    if (@typeInfo(function_type) != .@"fn") return error.UnknownSyscall;
                    const fn_info = @typeInfo(function_type).@"fn";
                    const RawReturn = fn_info.return_type.?;
                    const ReturnType = if (@typeInfo(RawReturn) == .error_union)
                        @typeInfo(RawReturn).error_union.payload
                    else
                        RawReturn;

                    const result = try function(self.engine, self.context, fiber, payload);

                    _ = slots.set(0, result);
                    if (ReturnType == Pending) {
                        return .{ .pending = Pending{} };
                    } else if (ReturnType == void) {
                        return .{ .immediate = @unionInit(ResultType, name, 0) };
                    } else {
                        return .{ .immediate = @unionInit(ResultType, name, result) };
                    }
                },
            }
        }

        pub fn free(self: *@This(), result: ResultType) void {
            switch (result) {
                inline else => |payload, tag| {
                    _ = tag;
                    const PayloadType = @TypeOf(payload);
                    if (PayloadType == []const u8 or PayloadType == []u8) {
                        self.context.allocator.free(@constCast(payload));
                    }
                },
            }
        }
    };
}
