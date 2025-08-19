const std = @import("std");

const c = @import("wren.zig");

const TrackingAllocator = @import("../lib/TrackingAllocator.zig");

pub const Configuration = struct {
    API: type = struct {},
};

pub const ErrorReport = union(enum) {
    none: struct {},
    compilation_error: struct {
        error_message: []const u8,
        module_name: []const u8,
        source_line: usize,
    },
    runtime_error: struct {
        message: []const u8,
        stack_trace: std.ArrayListUnmanaged(StackTraceLine),
    },
};

pub const StackTraceLine = struct {
    symbol_name: []const u8,
    module_name: []const u8,
    source_line: usize,
};

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

        output_buffer: std.heap.FixedBufferAllocator,
        error_buffer: std.heap.FixedBufferAllocator,
        current_error: ErrorReport = .{ .none = .{} },
        current_output: std.ArrayList(u8),

        fn cast(ctx: anytype) *Self {
            if (@TypeOf(ctx) == *anyopaque) {
                return @ptrCast(@alignCast(ctx));
            } else if (@TypeOf(ctx) == ?*anyopaque) {
                return @ptrCast(@alignCast(ctx.?));
            } else if (@TypeOf(ctx) == *c.VM) {
                return @ptrCast(@alignCast(c.wrenGetUserData(ctx)));
            } else {
                @compileError("Invalid context type: " ++ @typeName(@TypeOf(ctx)));
            }
        }

        pub fn init(allocator: std.mem.Allocator) !*Self {
            var self = try allocator.create(Self);
            try self.setup(allocator, .{});
            return self;
        }

        pub fn setup(self: *Self, allocator: std.mem.Allocator, options: Options) !void {
            const error_buffer = std.heap.FixedBufferAllocator.init(
                try allocator.alloc(u8, options.error_buffer_size),
            );
            errdefer allocator.free(error_buffer.buffer);

            const output_buffer = std.heap.FixedBufferAllocator.init(
                try allocator.alloc(u8, options.output_buffer_size),
            );
            errdefer allocator.free(output_buffer.buffer);

            var vmconf = c.Configuration{};
            c.wrenInitConfiguration(&vmconf);
            vmconf.reallocateFn = reallocateFn;
            vmconf.writeFn = writeFn;
            vmconf.errorFn = errorFn;
            vmconf.bindForeignMethodFn = bindForeignMethodFn;

            // The VM initialization calls the reallocate function,
            // so we need to set the allocator before that,
            // and the user data pointer needs to be correct.
            vmconf.userData = self;
            self.allocator = allocator;

            if (c.wrenNewVM(&vmconf)) |vm| {
                self.* = .{
                    .allocator = allocator,
                    .vm = vm,
                    .output_buffer = output_buffer,
                    .error_buffer = error_buffer,
                    .current_output = std.ArrayList(u8).init(self.output_buffer.allocator()),
                };

                try self.bind();
            } else {
                return error.FailedToCreateVM;
            }
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;

            c.wrenFreeVM(self.vm);

            allocator.free(self.output_buffer.buffer);
            allocator.free(self.error_buffer.buffer);

            allocator.destroy(self);
        }

        pub fn runTopLevel(self: *Self, module_name: [:0]const u8, source: []const u8) !void {
            const source_as_cstr = try self.allocator.dupeZ(u8, source);
            defer self.allocator.free(source_as_cstr);

            const result = c.wrenInterpret(self.vm, module_name, source_as_cstr);

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

                    std.debug.print("code: \n{s}\n", .{code.items});
                    try self.runTopLevel(module_name, code.items);
                }
            }

            try self.runTopLevel("core",
                \\class Ring {
                \\  queue { _queue }
                \\
                \\  construct new() {
                \\    _queue = []
                \\  }
                \\
                \\  push(item) {
                \\    _queue.add(item)
                \\  }
                \\
                \\  soon(block) {
                \\    push(Fiber.new(block))
                \\  }
                \\
                \\  pop() {
                \\    return _queue.removeAt(0)
                \\  }
                \\
                \\  size { _queue.count }
                \\}
                \\
                \\var ring = Ring.new()
                \\
            );
        }

        fn bindForeignMethodFn(
            vm: *c.VM,
            module: [*:0]const u8,
            className: [*:0]const u8,
            isStatic: bool,
            method: [*:0]const u8,
        ) callconv(.C) c.ForeignMethodFn {
            _ = module; // autofix
            const self = cast(vm);
            _ = self; // autofix

            std.debug.print("className: {s}\n", .{className});
            std.debug.print("isStatic: {any}\n", .{isStatic});
            std.debug.print("method: {s}\n", .{method});

            inline for (@typeInfo(API).@"struct".fields) |field| {
                std.debug.print("field: {s}\n", .{field.name});
            }

            return null;
        }

        fn reallocateFn(
            memory: ?*anyopaque,
            new_size: usize,
            ctxptr: *anyopaque,
        ) callconv(.C) ?*anyopaque {
            const self = cast(ctxptr);
            const allocator = self.allocator;
            var tracked = TrackingAllocator.create(allocator);
            if (memory) |mem| {
                const ptr: [*]u8 = @ptrCast(mem);
                if (new_size == 0) {
                    tracked.free(ptr);
                    return null;
                } else {
                    return tracked.realloc(ptr, new_size);
                }
            } else {
                if (new_size == 0) {
                    return null;
                }
                return tracked.alloc(new_size);
            }
        }

        fn writeFn(vm: *c.VM, text: [*:0]const u8) callconv(.C) void {
            var self = cast(vm);
            const str = std.mem.span(text);
            self.current_output.appendSlice(str) catch {
                const message = "output buffer full";
                c.wrenSetSlotString(self.vm, 1, message);
                c.wrenAbortFiber(vm, 1);
            };
        }

        /// Returns the current error and clears it.
        pub fn takeError(self: *Self) ErrorReport {
            const e = self.current_error;
            self.current_error = .{ .none = .{} };
            return e;
        }

        /// Returns an error if there is a current error.
        /// If there is no error, does nothing.
        pub fn checkError(self: *Self) error{ CompilationError, RuntimeError }!void {
            switch (self.current_error) {
                .compilation_error => return error.CompilationError,
                .runtime_error => return error.RuntimeError,
                else => {},
            }
        }

        pub fn takeOutput(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            const output = try allocator.dupe(u8, self.current_output.items);
            self.current_output.clearAndFree();
            return output;
        }

        pub fn croak(self: *Self) !void {
            const e = self.takeError();
            switch (e) {
                .none => {},
                .compilation_error => {
                    std.debug.print("compilation error: {s}\n", .{e.compilation_error.error_message});
                    return error.CompilationError;
                },
                .runtime_error => {
                    std.debug.print("runtime error: {s}\n", .{e.runtime_error.message});
                    for (e.runtime_error.stack_trace.items) |line| {
                        std.debug.print("  {s} in {s}:{d}\n", .{
                            line.symbol_name,
                            line.module_name,
                            line.source_line,
                        });
                    }
                    return error.RuntimeError;
                },
            }
        }

        fn errorFn(
            vm: *c.VM,
            error_type: c.ErrorType,
            module_ptr: ?[*:0]const u8,
            line: c_int,
            message_ptr: ?[*:0]const u8,
        ) callconv(.C) void {
            const self = cast(vm);

            const allocator = self.error_buffer.allocator();
            const message = if (message_ptr) |m| std.mem.span(m) else "";
            const module = if (module_ptr) |m| std.mem.span(m) else "";
            switch (self.current_error) {
                .runtime_error => |*runtime_error| {
                    switch (error_type) {
                        .stack_trace => {
                            runtime_error.stack_trace.append(allocator, .{
                                .symbol_name = allocator.dupe(u8, message) catch {
                                    std.debug.panic("failed to dupe symbol name", .{});
                                },
                                .module_name = allocator.dupe(u8, module) catch {
                                    std.debug.panic("failed to dupe module name", .{});
                                },
                                .source_line = @intCast(line),
                            }) catch {
                                std.debug.panic("failed to append stack trace line", .{});
                            };
                        },
                        else => std.debug.panic("{any} during runtime error", .{error_type}),
                    }
                },
                else => {
                    switch (error_type) {
                        .compile => {
                            self.current_error = .{
                                .compilation_error = .{
                                    .error_message = allocator.dupe(u8, message) catch {
                                        std.debug.panic("failed to dupe error message", .{});
                                    },
                                    .module_name = allocator.dupe(u8, module) catch {
                                        std.debug.panic("failed to dupe module name", .{});
                                    },
                                    .source_line = @intCast(line),
                                },
                            };
                        },
                        .runtime => {
                            self.current_error = .{
                                .runtime_error = .{
                                    .message = allocator.dupe(u8, message) catch {
                                        std.debug.panic("failed to dupe message", .{});
                                    },
                                    .stack_trace = std.ArrayListUnmanaged(StackTraceLine){},
                                },
                            };
                        },
                        .stack_trace => std.debug.panic("stack trace without error", .{}),
                    }
                },
            }
        }

        pub fn ringSize(self: *Self) !usize {
            c.wrenEnsureSlots(self.vm, 1);
            c.wrenGetVariable(self.vm, "core", "ring", 0);
            const handle = c.wrenMakeCallHandle(self.vm, "size") orelse {
                return error.FailedToMakeCallHandle;
            };
            defer c.wrenReleaseHandle(self.vm, handle);
            _ = c.wrenCall(self.vm, handle);
            const result = c.wrenGetSlotDouble(self.vm, 0);
            return @intFromFloat(result);
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

test "we can call ring.soon" {
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
        \\import "core" for ring
        \\
        \\System.print(hello)
        \\
        \\ring.soon {
        \\  Fiber.yield(hello)
        \\}
        \\
        \\ring.soon {
        \\  Fiber.yield(hello)
        \\}
        \\
    ) catch {
        try engine.croak();
    };

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqual(try engine.ringSize(), 2);
}
