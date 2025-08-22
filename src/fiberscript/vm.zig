const std = @import("std");

const c = @import("wren.zig");
const ErrorHandler = @import("error_handler.zig").ErrorHandler;
const slots_api = @import("slots.zig");
const OutputHandler = @import("output.zig").OutputHandler;
const syscalls = @import("syscalls.zig");
const dom = @import("../dom.zig");
const WindowMod = @import("../Window.zig");
const layout = @import("../layout.zig");
const Painter = @import("../Painter.zig").Painter;
const TrackingAllocator = @import("../lib/TrackingAllocator.zig");

const ansi = @import("ansi");
const tree = ansi.nest;

pub const Configuration = struct {
    Syscalls: fn (comptime EngineType: type, comptime ContextType: type) type = documentSyscalls,
};

pub const ErrorReport = ErrorHandler.ErrorReport;
pub const StackTraceLine = ErrorHandler.StackTraceLine;

pub fn Engine(configuration: Configuration) type {
    return struct {
        allocator: std.mem.Allocator,
        output_handler: OutputHandler,
        error_handler: ErrorHandler,
        syscalls: std.AutoArrayHashMap(*c.Handle, Request),
        dispatcher: Dispatcher,
        syscall_context: *SyscallContext,
        vm: *c.VM,

        const Self = @This();

        const SyscallsType = configuration.Syscalls(Self, SyscallContext);
        const Request = syscalls.RequestUnion(SyscallsType);
        const Dispatcher = syscalls.generateDispatcher(SyscallsType, Self, SyscallContext);
        const SlotParser = syscalls.generateSlotParser(Request, SyscallsType);

        pub const Options = struct {
            output_buffer_size: usize = 1024 * 32,
            error_buffer_size: usize = 1024 * 32,
            syscall_context: *SyscallContext,
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

            self.syscalls = std.AutoArrayHashMap(*c.Handle, Request).init(allocator);
            errdefer self.syscalls.deinit();

            self.syscall_context = options.syscall_context;
            self.dispatcher = Dispatcher{ .engine = self, .context = self.syscall_context };

            var vmconf = c.Configuration{};
            c.wrenInitConfiguration(&vmconf);

            vmconf.reallocateFn = reallocateFn;
            vmconf.writeFn = writeFn;
            vmconf.errorFn = errorFn;
            vmconf.userData = self;
            vmconf.bindForeignMethodFn = bindForeignMethodFn;

            if (c.wrenNewVM(&vmconf)) |vm| {
                self.vm = vm;
            } else {
                return error.FailedToCreateVM;
            }

            errdefer c.wrenFreeVM(self.vm);
            errdefer self.croak() catch {};

            try self.bind();
        }

        pub fn deinit(self: *Self) void {
            for (self.syscalls.keys()) |fiber| {
                c.wrenReleaseHandle(self.vm, fiber);
            }

            self.syscalls.deinit();
            self.error_handler.deinit(self.allocator);
            self.output_handler.deinit(self.allocator);
            self.syscall_context.deinit();

            c.wrenFreeVM(self.vm);

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
                    if (std.mem.eql(u8, std.mem.span(method), "syscall(_,_)")) {
                        return &foreignSyscall;
                    }
                }
            }

            return null;
        }

        fn foreignSyscall(ptr: *c.VM) callconv(.C) void {
            var ctx: *Self = @ptrCast(@alignCast(c.wrenGetUserData(ptr)));
            var work = ctx.slots();
            const fiber = work.get(1, *c.Handle) catch {
                std.debug.panic("expected fiber", .{});
            };
            var slot_map = work.slotMap(2);
            const request = SlotParser.parseRequest(&slot_map) catch {
                std.debug.panic("expected request", .{});
            };
            ctx.syscall(fiber, request) catch {
                std.debug.panic("failed to schedule fiber", .{});
            };
        }

        pub fn syscall(self: *Self, fiber: *c.Handle, request: Request) !void {
            std.debug.print("syscall: {d} {s}\n", .{ fiber, @tagName(request) });
            var work = self.slots();
            const result = try self.dispatcher.dispatch(request, fiber);
            const setter = syscalls.generateResultSetter(SyscallsType);
            switch (result) {
                .immediate => |x| {
                    defer c.wrenReleaseHandle(self.vm, fiber);
                    try setter.set(&work, 0, x);
                },
                .pending => {
                    _ = work.set(0, fiber);
                },
            }
        }

        /// C callback wrapper for output handling.
        fn writeFn(vm: *c.VM, text: [*:0]const u8) callconv(.C) void {
            const self = getSelf(vm);
            self.output_handler.writeFn(vm, text);
        }

        pub fn write(self: *Self, text: []const u8) void {
            self.output_handler.write(self.vm, text);
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

pub const SyscallContext = struct {
    allocator: std.mem.Allocator,
    document: *dom.Dom,
    window: ?*WindowMod.Window = null,
    viewport_width: usize = 80,
    viewport_height: usize = 24,
    frame_fibers: std.ArrayListUnmanaged(*c.Handle) = .{},

    pub fn deinit(self: *SyscallContext) void {
        if (self.window) |w| {
            w.deinit();
            self.allocator.destroy(w);
        }
    }
};
const Fiber = *c.Handle;

const Pending = syscalls.Pending;

pub fn documentSyscalls(comptime EngineType: type, comptime Context: type) type {
    return struct {
        pub fn print(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { message: []const u8 }) anyerror!void {
            _ = fiber; // autofix
            _ = context;
            engine.write(args.message);
        }

        pub fn createElement(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { style: []const u8 }) anyerror!dom.DomNodeId {
            _ = engine;
            _ = fiber;
            return context.document.addElement(args.style);
        }

        pub fn createText(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { text: []const u8 }) anyerror!dom.DomNodeId {
            _ = fiber; // autofix
            _ = engine;
            return context.document.addText(args.text);
        }

        pub fn updateText(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { nodeId: u32, text: []const u8 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            try context.document.updateText(args.nodeId, args.text);
        }

        pub fn updateClass(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { nodeId: u32, className: []const u8 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            try context.document.updateClass(args.nodeId, args.className);
        }

        pub fn appendChild(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { parentId: u32, childId: u32 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            try context.document.appendChild(args.parentId, args.childId);
        }

        pub fn removeChild(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { parentId: u32, childId: u32 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            try context.document.removeChild(args.parentId, args.childId);
        }

        pub fn openWindow(engine: *EngineType, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            _ = args;
            if (context.window == null) {
                const w = try context.document.alloc.create(WindowMod.Window);
                w.* = try WindowMod.Window.init(context.document.alloc, .{
                    .width = context.viewport_width,
                    .height = context.viewport_height,
                });
                context.window = w;
            }
            const stdout_writer = std.io.getStdOut().writer();
            try context.window.?.renderAndPresent(context.document, 0, stdout_writer);
        }

        pub fn printElement(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { nodeId: u32 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            if (context.window == null) {
                const w = try context.document.alloc.create(WindowMod.Window);
                w.* = try WindowMod.Window.init(context.document.alloc, .{
                    .width = context.viewport_width,
                    .height = context.viewport_height,
                });
                context.window = w;
            }
            const w = context.window.?;
            w.state.back.clear();
            var box_tree = try layout.allocateBoxTreeFromDOM(context.document.alloc, context.document, 0);
            defer box_tree.deinit();
            var layout_engine = layout.init(context.document.alloc, w.unicode, w.trace);
            try layout_engine.layoutSubtree(&box_tree, context.document, box_tree.getNodeMut(0), .{
                .x = 0,
                .y = 0,
                .w = w.opts.width,
                .h = w.opts.height,
            });
            var painter = Painter.init(context.document.alloc, w.unicode, w.trace);
            defer painter.deinit();
            try painter.computePaintCommands(context.document, &box_tree, w.glyphs);
            try w.state.back.rasterizeDisplayList(context.document.alloc, w.glyphs, &painter);

            var rect = layout.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
            var found = false;
            for (box_tree.nodes.items) |node| {
                if (node.data.dom_id == args.nodeId) {
                    rect = node.data.rect;
                    found = true;
                    break;
                }
            }
            if (!found) return;

            const stdout_writer = std.io.getStdOut().writer();
            try w.state.back.writeSubRectAsPlainText(stdout_writer, w.glyphs, rect.x, rect.y, rect.w, rect.h);
        }

        pub fn requestRender(engine: *EngineType, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            _ = args;
            if (context.window) |w| {
                const stdout_writer = std.io.getStdOut().writer();
                try w.renderAndPresent(context.document, 0, stdout_writer);
            }
        }

        pub fn clearScreen(engine: *EngineType, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            _ = context;
            _ = args;
            @panic("clearScreen not implemented");
        }

        pub fn requestAnimationFrame(engine: *EngineType, context: *Context, fiber: Fiber, args: struct {}) anyerror!Pending {
            _ = engine; // autofix
            _ = args; // autofix
            try context.frame_fibers.append(context.allocator, fiber);
            return syscalls.Pending{};
        }

        pub fn setTimeout(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { delayMs: f64 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            _ = context;
            _ = args;
            @panic("setTimeout not implemented");
        }

        pub fn addEventListener(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { eventType: []const u8 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            _ = context;
            _ = args;
            @panic("addEventListener not implemented");
        }

        pub fn getViewportSize(engine: *EngineType, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            _ = context;
            _ = args;
        }

        pub fn setViewportSize(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { width: u32, height: u32 }) anyerror!void {
            _ = fiber; // autofix
            _ = engine;
            context.viewport_width = args.width;
            context.viewport_height = args.height;
            if (context.window) |w| {
                try w.setViewport(context.viewport_width, context.viewport_height);
            }
        }
    };
}

test "we can create and destroy a VM" {
    const allocator = std.testing.allocator;
    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var vm = try Engine(.{}).init(allocator, .{ .syscall_context = &sc });
    defer vm.deinit();

    const output = try vm.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(output, "");
    try std.testing.expect(vm.takeError() == .none);
}

test "we can run a simple script" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine(.{}).init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    try engine.runTopLevel("foo",
        \\System.print("Hello, world!")
    );

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(output, "Hello, world!\n");
    try std.testing.expect(engine.takeError() == .none);
}

test "we can call Core.call" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine(.{}).init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    engine.runTopLevel("main",
        \\import "xtc" for Core
        \\Core.call("print", { "message": "hello\n" })
        \\Core.call("print", { "message": "hello\n" })
    ) catch {
        try engine.croak();
    };

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(output, "hello\nhello\n");
    try std.testing.expect(engine.takeError() == .none);
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

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine(.{}).init(allocator, .{ .syscall_context = &sc });
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

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine(.{}).init(allocator, .{ .syscall_context = &sc });
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

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine(.{}).init(allocator, .{ .syscall_context = &sc });
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
