const std = @import("std");
const c = @import("wren.zig");
const WrenAllocator = @import("allocator.zig").WrenAllocator;
const OutputHandler = @import("output.zig").OutputHandler;
const ErrorHandler = @import("error_handler.zig").ErrorHandler;
const Slots = @import("slots.zig");
const syscalls = @import("syscalls.zig");
const dom = @import("../dom.zig");

/// Unified context that ties together all VM support systems.
///
/// This struct serves as the user data for the Wren VM and provides
/// a single point of access to all the support systems (allocation,
/// output handling, error handling).
pub const VMContext = struct {
    allocator: WrenAllocator,
    output_handler: OutputHandler,
    error_handler: ErrorHandler,
    fiber_queue: std.ArrayList(*c.Handle),
    trampoliner: Trampoline,
    document: *dom.Dom,

    const Syscalls = syscalls.TTYSyscalls(@This());
    const Request = syscalls.RequestUnion(Syscalls);
    const Trampoline = syscalls.generateTrampoline(Syscalls, @This());
    const SlotParser = syscalls.generateSlotParser(Request, Syscalls);

    const SyscallsImpl = syscalls.bindSyscalls(Syscalls, struct {
        pub fn createElement(
            self: *VMContext,
            args: Syscalls.Payload(.createElement),
        ) anyerror!dom.DomNodeId {
            return self.document.addElement(args.style);
        }

        pub fn updateText(
            self: *VMContext,
            args: Syscalls.Payload(.updateText),
        ) anyerror!void {
            try self.document.updateText(args.nodeId, args.text);
        }

        pub fn updateClass(
            self: *VMContext,
            args: Syscalls.Payload(.updateClass),
        ) anyerror!void {
            try self.document.updateClass(args.nodeId, args.className);
        }

        pub fn appendChild(
            self: *VMContext,
            args: Syscalls.Payload(.appendChild),
        ) anyerror!void {
            try self.document.appendChild(args.parentId, args.childId);
        }

        pub fn removeChild(
            self: *VMContext,
            args: Syscalls.Payload(.removeChild),
        ) anyerror!void {
            try self.document.removeChild(args.parentId, args.childId);
        }

        pub fn requestRender(
            self: *VMContext,
            _: Syscalls.Payload(.requestRender),
        ) anyerror!void {
            _ = self; // autofix
            @panic("requestRender not implemented");
        }

        pub fn clearScreen(
            self: *VMContext,
            _: Syscalls.Payload(.clearScreen),
        ) anyerror!void {
            _ = self; // autofix
            @panic("clearScreen not implemented");
        }

        pub fn requestAnimationFrame(
            self: *VMContext,
            _: Syscalls.Payload(.requestAnimationFrame),
        ) anyerror!void {
            _ = self; // autofix
            @panic("requestAnimationFrame not implemented");
        }

        pub fn setTimeout(
            self: *VMContext,
            args: Syscalls.Payload(.setTimeout),
        ) anyerror!void {
            _ = self; // autofix
            _ = args; // autofix
            @panic("setTimeout not implemented");
        }

        pub fn addEventListener(
            self: *VMContext,
            args: Syscalls.Payload(.addEventListener),
        ) anyerror!void {
            _ = self; // autofix
            _ = args; // autofix
            @panic("addEventListener not implemented");
        }

        pub fn getViewportSize(
            self: *VMContext,
            _: Syscalls.Payload(.getViewportSize),
        ) anyerror!void {
            _ = self; // autofix
            @panic("getViewportSize not implemented");
        }

        pub fn setViewportSize(
            self: *VMContext,
            args: Syscalls.Payload(.setViewportSize),
        ) anyerror!void {
            _ = self; // autofix
            _ = args; // autofix
            @panic("setViewportSize not implemented");
        }
    });

    pub const Options = struct {
        output_buffer_size: usize = 1024 * 32,
        error_buffer_size: usize = 1024 * 32,
    };

    pub fn init(base_allocator: std.mem.Allocator, options: Options) !*VMContext {
        const context = try base_allocator.create(VMContext);
        errdefer base_allocator.destroy(context);

        context.allocator = WrenAllocator.init(base_allocator);

        context.output_handler = OutputHandler.init(base_allocator, .{
            .buffer_size = options.output_buffer_size,
        }) catch |err| {
            base_allocator.destroy(context);
            return err;
        };
        errdefer context.output_handler.deinit(base_allocator);

        context.error_handler = ErrorHandler.init(base_allocator, .{
            .buffer_size = options.error_buffer_size,
        }) catch |err| {
            context.output_handler.deinit(base_allocator);
            base_allocator.destroy(context);
            return err;
        };

        context.fiber_queue = std.ArrayList(*c.Handle).init(base_allocator);

        context.trampoliner = Trampoline{
            .context = context,
            .syscalls = SyscallsImpl,
        };

        return context;
    }

    pub fn deinit(self: *VMContext, base_allocator: std.mem.Allocator) void {
        self.error_handler.deinit(base_allocator);
        self.output_handler.deinit(base_allocator);

        self.fiber_queue.deinit();
        base_allocator.destroy(self);
    }

    /// Creates a Wren VM configuration with this context.
    pub fn createVMConfiguration(self: *VMContext) c.Configuration {
        var config = c.Configuration{};
        c.wrenInitConfiguration(&config);

        config.reallocateFn = WrenAllocator.reallocateFn;
        config.writeFn = writeFn;
        config.errorFn = errorFn;
        config.userData = self;
        config.bindForeignMethodFn = bindForeignMethodFn;

        return config;
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

        if (std.mem.eql(u8, std.mem.span(module), "core") and std.mem.eql(u8, std.mem.span(className), "Core")) {
            if (std.mem.eql(u8, std.mem.span(method), "scheduleImmediately(_)")) {
                return &(struct {
                    fn callback(ptr: *c.VM) callconv(.C) void {
                        var ctx: *VMContext = @ptrCast(@alignCast(c.wrenGetUserData(ptr)));
                        var work = Slots.SlotBuilder.init(ptr, ctx.allocator.allocator);
                        const fiber = work.get(0, *c.Handle) catch std.debug.panic("expected fiber", .{});
                        ctx.scheduleImmediately(fiber) catch std.debug.panic("failed to schedule fiber", .{});
                        _ = work.set(0, void{});
                    }
                }).callback;
            }
        }

        return null;
    }

    pub fn scheduleImmediately(self: *VMContext, fiber: *c.Handle) !void {
        try self.fiber_queue.append(fiber);
        std.debug.print("scheduled fiber: {any}\n", .{fiber});
    }

    pub fn trampoline(self: *VMContext, vm: *c.VM) !void {
        var work = Slots.SlotBuilder.init(vm, self.allocator.allocator);
        std.debug.print("first round of trampoline\n", .{});
        var steps: usize = 0;

        while (steps < 16) : (steps += 1) {
            if (self.fiber_queue.items.len == 0) {
                std.debug.print("trampoline: no fibers to run\n", .{});
                return;
            }

            const fiber = self.fiber_queue.orderedRemove(0);

            _ = work.set(0, fiber).call("call()");
            if (work.countSlots() < 2) {
                std.debug.print("trampoline: no slots, {}\n", .{steps});
                c.wrenReleaseHandle(vm, fiber);
                return;
            }

            var slot_map = work.slotMap(0);
            const request = try SlotParser.parseRequest(&slot_map);
            std.debug.print("trampoline: {any} {any}\n", .{ fiber, request });

            switch (request) {
                .@"Ring.push" => |push| {
                    _ = work.set(0, push.ring).call("grab()");
                    const grabbed = try SlotParser.parseRequest(&slot_map);

                    std.debug.print("grabbed: {any}\n", .{grabbed});
                    _ = work.set(0, fiber).set(1, 1).call("call(_)");
                },

                .@"Ring.pull" => |pull| {
                    _ = pull; // autofix
                    std.debug.panic("pull not implemented", .{});
                },

                else => {
                    try self.trampoliner.dispatch(request);
                },
            }
        }
    }

    /// C callback wrapper for output handling.
    fn writeFn(vm: *c.VM, text: [*:0]const u8) callconv(.C) void {
        const context = getContext(vm);
        context.output_handler.writeFn(vm, text);
    }

    /// C callback wrapper for error handling.
    fn errorFn(
        vm: *c.VM,
        error_type: c.ErrorType,
        module_ptr: ?[*:0]const u8,
        line: c_int,
        message_ptr: ?[*:0]const u8,
    ) callconv(.C) void {
        const context = getContext(vm);
        context.error_handler.errorFn(error_type, module_ptr, line, message_ptr);
    }

    /// Helper function to extract VMContext from VM user data.
    fn getContext(vm: *c.VM) *VMContext {
        const user_data = c.wrenGetUserData(vm);
        return @ptrCast(@alignCast(user_data));
    }

    /// Convenience functions that delegate to the appropriate handlers
    pub fn takeOutput(self: *VMContext, allocator: std.mem.Allocator) ![]const u8 {
        return self.output_handler.takeOutput(allocator);
    }

    pub fn takeError(self: *VMContext) ErrorHandler.ErrorReport {
        return self.error_handler.takeError();
    }

    pub fn checkError(self: *VMContext) error{ CompilationError, RuntimeError }!void {
        return self.error_handler.checkError();
    }

    pub fn croak(self: *VMContext) error{ CompilationError, RuntimeError }!void {
        return self.error_handler.croak();
    }
};
