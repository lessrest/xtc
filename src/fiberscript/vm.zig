const std = @import("std");

const c = @import("wren.zig");
const VMContext = @import("vm_context.zig").VMContext;
const ErrorHandler = @import("error_handler.zig").ErrorHandler;
const slots_api = @import("slots.zig");

const ansi = @import("ansi");
const tree = ansi.nest;

pub const Configuration = struct {
    API: type = struct {},
};

pub const ErrorReport = ErrorHandler.ErrorReport;
pub const StackTraceLine = ErrorHandler.StackTraceLine;

pub fn Engine(configuration: Configuration) type {
    return struct {
        const Self = @This();

        pub const API = configuration.API;

        pub const Options = struct {
            output_buffer_size: usize = 1024 * 32,
            error_buffer_size: usize = 1024 * 32,
        };

        allocator: std.mem.Allocator,
        vm: *c.VM,
        context: *VMContext,

        fn getContext(vm: *c.VM) *VMContext {
            const user_data = c.wrenGetUserData(vm);
            return @ptrCast(@alignCast(user_data));
        }

        pub fn init(allocator: std.mem.Allocator) !*Self {
            var self = try allocator.create(Self);
            try self.setup(allocator, .{});
            return self;
        }

        pub fn setup(self: *Self, allocator: std.mem.Allocator, options: Options) !void {
            const context = try VMContext.init(allocator, .{
                .output_buffer_size = options.output_buffer_size,
                .error_buffer_size = options.error_buffer_size,
            });
            errdefer context.deinit(allocator);

            var vmconf = context.createVMConfiguration();

            if (c.wrenNewVM(&vmconf)) |vm| {
                self.* = .{
                    .allocator = allocator,
                    .vm = vm,
                    .context = context,
                };

                try self.bind();
            } else {
                context.deinit(allocator);
                return error.FailedToCreateVM;
            }
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            for (self.context.fiber_queue.items) |fiber| {
                c.wrenReleaseHandle(self.vm, fiber);
            }

            self.context.deinit(allocator);
            c.wrenFreeVM(self.vm);
            allocator.destroy(self);
        }

        pub fn runTopLevel(self: *Self, module_name: []const u8, source: []const u8) !void {
            const source_as_cstr = try self.allocator.dupeZ(u8, source);
            defer self.allocator.free(source_as_cstr);

            const module_name_as_cstr = try self.allocator.dupeZ(u8, module_name);
            defer self.allocator.free(module_name_as_cstr);

            const result = c.wrenInterpret(self.vm, module_name_as_cstr, source_as_cstr);

            const outcome = @as(c.InterpretResult, @enumFromInt(result));
            switch (outcome) {
                .success => {},
                .compile_error => {
                    return error.CompilationError;
                },
                .runtime_error => {
                    return error.RuntimeError;
                },
            }
        }

        fn bind(self: *Self) !void {
            inline for (@typeInfo(API).@"struct".fields) |field| {
                const module_name = field.name;
                if (@typeInfo(field.type) == .@"struct") {
                    var code = std.ArrayList(u8).init(self.allocator);
                    defer code.deinit();
                    var writer = code.writer();

                    inline for (@typeInfo(field.type).@"struct".fields) |method| {
                        const method_name = method.name;
                        const sighash = try @import("../ticket.zig").from(module_name ++ "." ++ method_name);
                        try writer.print(
                            \\var {s} = "{s}"
                            \\
                        , .{ method_name, sighash });
                    }

                    try self.runTopLevel(module_name, code.items);
                }
            }

            try self.runTopLevel("xtc", @embedFile("xtc.wren"));
        }

        /// Returns the current error and clears it.
        pub fn takeError(self: *Self) ErrorReport {
            return self.context.takeError();
        }

        /// Returns an error if there is a current error.
        /// If there is no error, does nothing.
        pub fn checkError(self: *Self) error{ CompilationError, RuntimeError }!void {
            return self.context.checkError();
        }

        pub fn takeOutput(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            return self.context.takeOutput(allocator);
        }

        pub fn croak(self: *Self) !void {
            return self.context.croak();
        }

        /// Start building a slot configuration for method calls.
        /// Provides a fluent interface for working with Wren slots.
        pub fn slots(self: *Self) slots_api.SlotBuilder {
            return slots_api.SlotBuilder.init(self.vm, self.allocator);
        }
    };
}

test "we can create and destroy a VM" {
    const allocator = std.testing.allocator;

    var vm = try Engine(.{}).init(allocator);
    defer vm.deinit();

    const output = try vm.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(output, "");
    try std.testing.expect(vm.takeError() == .none);
}

test "we can run a simple script" {
    const allocator = std.testing.allocator;

    var engine = try Engine(.{}).init(allocator);
    defer engine.deinit();

    try engine.runTopLevel("foo",
        \\System.print("Hello, world!")
    );

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(output, "Hello, world!\n");
    try std.testing.expect(engine.takeError() == .none);
}

test "we can call Core.spawn" {
    const allocator = std.testing.allocator;

    const API = struct {
        const Self = Engine(.{ .API = @This() });

        foo: struct {
            hello: fn (self: *Self) void,
        },
    };

    var engine = try Engine(.{
        .API = API,
    }).init(allocator);
    defer engine.deinit();

    engine.runTopLevel("main",
        \\import "foo" for hello
        \\import "xtc" for Core
        \\
        \\System.print(hello)
        \\
        \\Core.spawn {
        \\  System.print("hello")
        \\}
        \\
        \\Core.spawn {
        \\  System.print("hello")
        \\}
        \\
    ) catch {
        try engine.croak();
    };

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try engine.context.trampoline(engine.vm);
}

test "Core.print operation" {
    const allocator = std.testing.allocator;

    const API = struct {
        const Self = Engine(.{ .API = @This() });
    };

    var engine = try Engine(.{
        .API = API,
    }).init(allocator);
    defer engine.deinit();

    engine.runTopLevel("main",
        \\import "xtc" for Core
        \\
        \\var fiber = Fiber.new {
        \\  Core.print("Hello from fiber!")
        \\}
        \\
        \\Core.scheduleImmediately(fiber)
        \\
    ) catch {
        try engine.croak();
    };

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try engine.context.trampoline(engine.vm);
}

test "slots API - simple method call" {
    const allocator = std.testing.allocator;

    var engine = try Engine(.{}).init(allocator);
    defer engine.deinit();

    try engine.runTopLevel("test",
        \\class TestClass {
        \\  static getValue() { 42 }
        \\  static add(a, b) { a + b }
        \\}
    );

    // Test simple static method call
    var builder1 = engine.slots();
    const result = try builder1
        .variable("test", "TestClass", 0)
        .call("getValue()")
        .as(f64);

    try std.testing.expectEqual(@as(f64, 42), result);

    // Test method call with arguments
    var builder2 = engine.slots();
    _ = builder2.variable("test", "TestClass", 0);
    _ = builder2.set(1, 10);
    _ = builder2.set(2, 32);
    const sum = try builder2.call("add(_,_)").as(f64);

    try std.testing.expectEqual(@as(f64, 42), sum);
}

test "slots API - working with strings" {
    const allocator = std.testing.allocator;

    var engine = try Engine(.{}).init(allocator);
    defer engine.deinit();

    try engine.runTopLevel("test",
        \\class StringHelper {
        \\  static reverse(str) {
        \\    var result = ""
        \\    for (i in (str.count-1)..0) {
        \\      result = result + str[i]
        \\    }
        \\    return result
        \\  }
        \\}
    );

    var builder = engine.slots();
    _ = builder.variable("test", "StringHelper", 0);
    _ = builder.set(1, "hello");
    const result = try builder.call("reverse(_)").as([]const u8);
    try std.testing.expectEqualStrings("olleh", result);
}

test "slots API - list operations" {
    const allocator = std.testing.allocator;

    var engine = try Engine(.{}).init(allocator);
    defer engine.deinit();

    try engine.runTopLevel("test",
        \\class ListHelper {
        \\  static createList() {
        \\    var list = []
        \\    list.add("first")
        \\    list.add("second")
        \\    return list
        \\  }
        \\  static getLength(list) { list.count }
        \\}
    );

    // Create a list and get its length
    var builder1 = engine.slots();
    const list_handle = try builder1
        .variable("test", "ListHelper", 0)
        .call("createList()")
        .as(*c.Handle);
    defer c.wrenReleaseHandle(engine.vm, list_handle);

    var builder2 = engine.slots();
    _ = builder2.variable("test", "ListHelper", 0);
    _ = builder2.set(1, list_handle);
    const length = try builder2.call("getLength(_)").as(f64);

    try std.testing.expectEqual(@as(f64, 2), length);
}
