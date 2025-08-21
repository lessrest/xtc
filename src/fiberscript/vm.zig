const std = @import("std");

const c = @import("wren.zig");
const ErrorHandler = @import("error_handler.zig").ErrorHandler;
const slots_api = @import("slots.zig");
const OutputHandler = @import("output.zig").OutputHandler;
const syscalls = @import("syscalls.zig");
const TrackingAllocator = @import("tracking_allocator.zig");

const ansi = @import("ansi");
const tree = ansi.nest;

pub const Configuration = struct {
    Syscalls: fn (comptime EngineType: type, comptime Context: type) type,
    Context: type,
};

pub const ErrorReport = ErrorHandler.ErrorReport;
pub const StackTraceLine = ErrorHandler.StackTraceLine;

pub fn Engine(comptime configuration: Configuration) type {
    return struct {
        allocator: std.mem.Allocator,
        output_handler: OutputHandler,
        error_handler: ErrorHandler,
        fiber_queue: std.ArrayList(*c.Handle),
        trampoliner: Trampoline,
        syscall_context: *Context,
        vm: *c.VM,

        const Self = @This();

        const Context = configuration.Context;
        const SyscallsType = configuration.Syscalls(Self, Context);
        const Request = syscalls.RequestUnion(SyscallsType);
        const Trampoline = syscalls.generateTrampoline(SyscallsType, Self, Context);
        const SlotParser = syscalls.generateSlotParser(Request, SyscallsType);

        pub const Options = struct {
            output_buffer_size: usize = 1024 * 32,
            error_buffer_size: usize = 1024 * 32,
            syscall_context: *Context,
        };

        pub fn init(base_allocator: std.mem.Allocator, options: Options) !*Self {
            const self = try base_allocator.create(Self);
            errdefer base_allocator.destroy(self);

            try self.setup(base_allocator, options);
            return self;
        }

        pub fn setup(self: *Self, allocator: std.mem.Allocator, options: Options) !void {
            // Initialize fields needed prior to VM creation
            self.allocator = allocator;

            self.output_handler = try OutputHandler.init(
                allocator,
                .{ .buffer_size = options.output_buffer_size },
            );

            errdefer self.output_handler.deinit(allocator);

            self.error_handler = try ErrorHandler.init(
                allocator,
                .{ .buffer_size = options.error_buffer_size },
            );
            errdefer self.error_handler.deinit(allocator);

            self.fiber_queue = std.ArrayList(*c.Handle).init(allocator);

            self.syscall_context = options.syscall_context;
            self.trampoliner = Trampoline{ .engine = self, .context = self.syscall_context };

            var vmconf = c.Configuration{};
            c.wrenInitConfiguration(&vmconf);

            vmconf.reallocateFn = reallocateFn;
            vmconf.writeFn = writeFn;
            vmconf.errorFn = errorFn;
            vmconf.userData = self;
            vmconf.bindForeignMethodFn = bindForeignMethodFn;

            if (c.wrenNewVM(&vmconf)) |vm| {
                self.vm = vm;
                try self.bind();
            } else {
                self.fiber_queue.deinit();
                self.error_handler.deinit(allocator);
                self.output_handler.deinit(allocator);
                return error.FailedToCreateVM;
            }
        }

        pub fn deinit(self: *Self) void {
            for (self.fiber_queue.items) |fiber| {
                c.wrenReleaseHandle(self.vm, fiber);
            }

            c.wrenFreeVM(self.vm);

            self.fiber_queue.deinit();
            self.error_handler.deinit(self.allocator);
            self.output_handler.deinit(self.allocator);

            self.allocator.destroy(self);
        }

        /// C callback function for Wren's memory allocation needs.
        ///
        /// Handles allocation, reallocation, and deallocation according to Wren's
        /// memory management contract:
        /// - memory=null, new_size>0: allocate new memory
        /// - memory!=null, new_size>0: reallocate existing memory
        /// - memory!=null, new_size=0: free memory
        /// - memory=null, new_size=0: no-op, return null
        pub fn reallocateFn(
            memory: ?*anyopaque,
            new_size: usize,
            user_data: *anyopaque,
        ) callconv(.C) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(user_data));
            var tracked = TrackingAllocator.create(self.allocator);

            if (memory) |mem| {
                const ptr: [*]u8 = @ptrCast(mem);
                if (new_size == 0) {
                    // Free memory
                    tracked.free(ptr);
                    return null;
                } else {
                    // Reallocate memory
                    return tracked.realloc(ptr, new_size);
                }
            } else {
                if (new_size == 0) {
                    // No-op case
                    return null;
                }
                // Allocate new memory
                return tracked.alloc(new_size);
            }
        }

        fn bindForeignMethodFn(
            vm: *c.VM,
            module: [*:0]const u8,
            className: [*:0]const u8,
            isStatic: bool,
            method: [*:0]const u8,
        ) callconv(.C) c.ForeignMethodFn {
            _ = vm; // autofix
            if (!isStatic) return null;

            if (std.mem.eql(u8, std.mem.span(module), "xtc")) {
                if (std.mem.eql(u8, std.mem.span(className), "Core")) {
                    if (std.mem.eql(u8, std.mem.span(method), "scheduleImmediately(_)")) {
                        return &(struct {
                            fn callback(ptr: *c.VM) callconv(.C) void {
                                var ctx: *Self = @ptrCast(@alignCast(c.wrenGetUserData(ptr)));
                                var work = slots_api.SlotBuilder.init(ptr, ctx.allocator);
                                const fiber = work.get(1, *c.Handle) catch std.debug.panic("expected fiber", .{});
                                ctx.scheduleImmediately(fiber) catch std.debug.panic("failed to schedule fiber", .{});
                                _ = work.set(0, void{});
                            }
                        }).callback;
                    }
                }
            }

            return null;
        }

        pub fn scheduleImmediately(self: *Self, fiber: *c.Handle) !void {
            try self.fiber_queue.append(fiber);
            std.debug.print("scheduled fiber: {any}\n", .{fiber});
        }

        pub fn trampoline(self: *Self, vm: *c.VM) !void {
            var work = slots_api.SlotBuilder.init(vm, self.allocator);
            std.debug.print("first round of trampoline\n", .{});
            var steps: usize = 0;

            errdefer self.croak() catch {};

            while (steps < 16) : (steps += 1) {
                if (self.fiber_queue.items.len == 0) {
                    std.debug.print("trampoline: no fibers to run\n", .{});
                    return;
                }

                const fiber = self.fiber_queue.orderedRemove(0);

                defer c.wrenReleaseHandle(vm, fiber);

                std.debug.print("trampoline: running fiber: {any}\n", .{fiber});
                try work.set(0, fiber).call("call()").checkSuccess();

                if (work.countSlots() < 2) {
                    std.debug.print("trampoline: no slots, {}\n", .{steps});
                    return;
                }

                var slot_map = work.slotMap(0);
                var request = try SlotParser.parseRequest(&slot_map);
                std.debug.print("trampoline: {any} {any}\n", .{ fiber, request });

                while (true) {
                    const dispatch_result = try self.trampoliner.dispatch(request);
                    switch (dispatch_result) {
                        .immediate => |result| {
                            _ = work.set(0, fiber);
                            switch (result) {
                                inline else => |value| {
                                    if (@TypeOf(value) == void) {
                                        _ = work.set(1, {});
                                    } else {
                                        _ = work.set(1, value);
                                    }
                                },
                            }
                            _ = work.call("call(_)");

                            if (work.countSlots() < 2) {
                                c.wrenReleaseHandle(vm, fiber);
                                break;
                            }

                            slot_map = work.slotMap(0);
                            request = try SlotParser.parseRequest(&slot_map);
                            std.debug.print("trampoline: {any} {any}\n", .{ fiber, request });
                            continue;
                        },
                        .pending => break,
                    }
                }
            }
        }

        /// C callback wrapper for output handling.
        fn writeFn(vm: *c.VM, text: [*:0]const u8) callconv(.C) void {
            const self = getSelf(vm);
            self.output_handler.writeFn(vm, text);
        }

        /// C callback wrapper for error handling.
        fn errorFn(
            vm: *c.VM,
            error_type: c.ErrorType,
            module_ptr: ?[*:0]const u8,
            line: c_int,
            message_ptr: ?[*:0]const u8,
        ) callconv(.C) void {
            const self = getSelf(vm);
            self.error_handler.errorFn(error_type, module_ptr, line, message_ptr);
        }

        pub fn takeError(self: *Self) ErrorReport {
            return self.error_handler.takeError();
        }

        pub fn checkError(self: *Self) !void {
            return self.error_handler.checkError();
        }

        fn getSelf(vm: *c.VM) *Self {
            const user_data = c.wrenGetUserData(vm);
            return @ptrCast(@alignCast(user_data));
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
            try self.runTopLevel("xtc", @embedFile("xtc.wren"));
        }

        pub fn takeOutput(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            return self.output_handler.takeOutput(allocator);
        }

        pub fn croak(self: *Self) !void {
            return self.error_handler.croak();
        }

        /// Start building a slot configuration for method calls.
        /// Provides a fluent interface for working with Wren slots.
        pub fn slots(self: *Self) slots_api.SlotBuilder {
            return slots_api.SlotBuilder.init(self.vm, self.allocator);
        }
    };
}

fn NoSyscalls(comptime EngineType: type, comptime Context: type) type {
    _ = EngineType;
    _ = Context;
    return struct {};
}

const TestContext = struct {};

test "we can create and destroy a VM" {
    const allocator = std.testing.allocator;
    const EngineType = Engine(.{ .Syscalls = NoSyscalls, .Context = TestContext });
    var context = TestContext{};
    var vm = try EngineType.init(allocator, .{ .syscall_context = &context });
    defer vm.deinit();

    const output = try vm.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(output, "");
    try std.testing.expect(vm.takeError() == .none);
}

test "we can run a simple script" {
    const allocator = std.testing.allocator;
    const EngineType = Engine(.{ .Syscalls = NoSyscalls, .Context = TestContext });
    var context = TestContext{};
    var engine = try EngineType.init(allocator, .{ .syscall_context = &context });
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
    const EngineType = Engine(.{ .Syscalls = NoSyscalls, .Context = TestContext });
    var context = TestContext{};
    var engine = try EngineType.init(allocator, .{ .syscall_context = &context });
    defer engine.deinit();

    engine.runTopLevel("main",
        \\import "xtc" for Core
        \\Core.spawn {
        \\  System.print("hello")
        \\}
        \\Core.spawn {
        \\  System.print("hello")
        \\}
    ) catch {
        try engine.croak();
    };

    try engine.trampoline(engine.vm);
}

// test "Core.print operation" {
//     const allocator = std.testing.allocator;

//     var engine = try Engine(.{}).init(allocator, .{});
//     defer engine.deinit();

//     engine.runTopLevel("main",
//         \\import "xtc" for Core
//         \\
//         \\var fiber = Fiber.new {
//         \\  Core.print("Hello from fiber!")
//         \\}
//         \\
//         \\Core.scheduleImmediately(fiber)
//         \\
//     ) catch {
//         try engine.croak();
//     };

//     const output = try engine.takeOutput(allocator);
//     defer allocator.free(output);

//     try engine.trampoline(engine.vm);
// }

test "slots API - simple method call" {
    const allocator = std.testing.allocator;
    const EngineType = Engine(.{ .Syscalls = NoSyscalls, .Context = TestContext });
    var context = TestContext{};
    var engine = try EngineType.init(allocator, .{ .syscall_context = &context });
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
    const EngineType = Engine(.{ .Syscalls = NoSyscalls, .Context = TestContext });
    var context = TestContext{};
    var engine = try EngineType.init(allocator, .{ .syscall_context = &context });
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
    const EngineType = Engine(.{ .Syscalls = NoSyscalls, .Context = TestContext });
    var context = TestContext{};
    var engine = try EngineType.init(allocator, .{ .syscall_context = &context });
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
