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
        const SyscallModuleSource: [:0]const u8 = syscalls.generateWrenModule(SyscallsType) ++ "\x00";

        const SubmissionBatch = struct {
            requests: std.ArrayList(Request),

            pub fn init(allocator: std.mem.Allocator, capacity: usize) SubmissionBatch {
                var list = std.ArrayList(Request).init(allocator);
                list.ensureTotalCapacity(capacity) catch {};
                return .{ .requests = list };
            }

            pub fn deinit(self: *SubmissionBatch) void {
                self.requests.deinit();
            }
        };

        const CompletionBatch = struct {
            expected: usize = 0,
            completed: usize = 0,
        };

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
            vmconf.bindForeignClassFn = bindForeignClassFn;
            vmconf.loadModuleFn = loadModuleFn;

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
            if (std.mem.eql(u8, std.mem.span(module), "xtc")) {
                if (std.mem.eql(u8, std.mem.span(className), "Core") and isStatic) {
                    if (std.mem.eql(u8, std.mem.span(method), "syscall(_,_)")) {
                        return &foreignSyscall;
                    } else if (std.mem.eql(u8, std.mem.span(method), "submitBatch(_,_)")) {
                        return &foreignSubmitBatch;
                    }
                }
            } else if (std.mem.eql(u8, std.mem.span(module), "syscall")) {
                if (std.mem.eql(u8, std.mem.span(className), "SubmissionBatch") and !isStatic) {
                    if (std.mem.eql(u8, std.mem.span(method), "add(_)")) {
                        return &submissionBatchAdd;
                    }
                } else if (std.mem.eql(u8, std.mem.span(className), "CompletionBatch") and !isStatic) {
                    if (std.mem.eql(u8, std.mem.span(method), "wait(_)")) {
                        return &completionBatchWait;
                    } else if (std.mem.eql(u8, std.mem.span(method), "waitAll()")) {
                        return &completionBatchWaitAll;
                    }
                }
            }

            return null;
        }

        fn bindForeignClassFn(
            vm: *c.VM,
            module: [*:0]const u8,
            className: [*:0]const u8,
        ) callconv(.C) c.ForeignClassMethods {
            _ = vm; // autofix
            var methods = c.ForeignClassMethods{};
            if (!std.mem.eql(u8, std.mem.span(module), "syscall")) return methods;

            if (std.mem.eql(u8, std.mem.span(className), "SubmissionBatch")) {
                const Alloc = struct {
                    pub fn allocate(vm_ptr: *c.VM) callconv(.C) void {
                        const self = getSelf(vm_ptr);
                        const capacity = @as(usize, @intFromFloat(c.wrenGetSlotDouble(vm_ptr, 1)));
                        const sb_ptr = c.wrenSetSlotNewForeign(vm_ptr, 0, 0, @sizeOf(SubmissionBatch));
                        const sb = @as(*SubmissionBatch, @ptrCast(@alignCast(sb_ptr)));
                        sb.* = SubmissionBatch.init(self.allocator, capacity);
                    }
                };
                const Final = struct {
                    pub fn finalize(data: ?*anyopaque) callconv(.C) void {
                        const sb = @as(*SubmissionBatch, @ptrCast(@alignCast(data.?)));
                        sb.deinit();
                    }
                };
                methods.allocate = Alloc.allocate;
                methods.finalize = Final.finalize;
                return methods;
            } else if (std.mem.eql(u8, std.mem.span(className), "CompletionBatch")) {
                const Alloc = struct {
                    pub fn allocate(vm_ptr: *c.VM) callconv(.C) void {
                        const cb_ptr = c.wrenSetSlotNewForeign(vm_ptr, 0, 0, @sizeOf(CompletionBatch));
                        const cb = @as(*CompletionBatch, @ptrCast(@alignCast(cb_ptr)));
                        cb.* = CompletionBatch{};
                    }
                };
                methods.allocate = Alloc.allocate;
                return methods;
            }

            inline for (@typeInfo(Request).@"union".fields) |field| {
                const class_name = syscalls.pascalCase(field.name);
                if (std.mem.eql(u8, std.mem.span(className), class_name)) {
                    const PayloadType = field.type;
                    const Alloc = struct {
                        pub fn allocate(vm_ptr: *c.VM) callconv(.C) void {
                            const req_ptr = c.wrenSetSlotNewForeign(vm_ptr, 0, 0, @sizeOf(Request));
                            const req = @as(*Request, @ptrCast(@alignCast(req_ptr)));
                            var payload: PayloadType = undefined;
                            inline for (std.meta.fields(PayloadType), 0..) |pf, idx| {
                                const slot_index: c_int = @as(c_int, @intCast(idx + 1));
                                if (pf.type == []const u8) {
                                    var len: c_int = 0;
                                    const ptr = c.wrenGetSlotBytes(vm_ptr, slot_index, &len);
                                    @field(payload, pf.name) = ptr[0..@as(usize, @intCast(len))];
                                } else if (pf.type == u32) {
                                    @field(payload, pf.name) = @as(u32, @intFromFloat(c.wrenGetSlotDouble(vm_ptr, slot_index)));
                                } else if (pf.type == f64) {
                                    @field(payload, pf.name) = c.wrenGetSlotDouble(vm_ptr, slot_index);
                                } else {
                                    @compileError("unsupported field type");
                                }
                            }
                            req.* = @unionInit(Request, field.name, payload);
                        }
                    };
                    methods.allocate = Alloc.allocate;
                    return methods;
                }
            }

            return methods;
        }

        fn loadModuleFn(vm: *c.VM, name: [*:0]const u8) callconv(.C) c.LoadModuleResult {
            _ = vm; // autofix
            if (std.mem.eql(u8, std.mem.span(name), "syscall")) {
                return c.LoadModuleResult{ .source = SyscallModuleSource.ptr };
            }
            return c.LoadModuleResult{};
        }

        fn foreignSyscall(ptr: *c.VM) callconv(.C) void {
            var ctx: *Self = @ptrCast(@alignCast(c.wrenGetUserData(ptr)));
            var work = ctx.slots();
            const fiber = work.get(1, *c.Handle) catch {
                std.debug.panic("expected fiber", .{});
            };
            const req_ptr = c.wrenGetSlotForeign(ptr, 2);
            const request = @as(*Request, @ptrCast(@alignCast(req_ptr))).*;
            ctx.syscall(fiber, request) catch {
                std.debug.panic("failed to schedule fiber", .{});
            };
        }

        fn foreignSubmitBatch(ptr: *c.VM) callconv(.C) void {
            var ctx: *Self = @ptrCast(@alignCast(c.wrenGetUserData(ptr)));
            var work = ctx.slots();
            const fiber = work.get(1, *c.Handle) catch {
                std.debug.panic("expected fiber", .{});
            };
            const batch_ptr = c.wrenGetSlotForeign(ptr, 2);
            const batch = @as(*SubmissionBatch, @ptrCast(@alignCast(batch_ptr)));
            c.wrenGetVariable(ptr, "syscall", "CompletionBatch", 0);
            const completion_ptr = c.wrenSetSlotNewForeign(ptr, 0, 0, @sizeOf(CompletionBatch));
            const completion = @as(*CompletionBatch, @ptrCast(@alignCast(completion_ptr)));
            completion.* = CompletionBatch{};
            ctx.submitBatch(fiber, batch, completion) catch {
                std.debug.panic("failed to submit batch", .{});
            };
            c.wrenReleaseHandle(ptr, fiber);
        }

        fn submissionBatchAdd(ptr: *c.VM) callconv(.C) void {
            const batch_ptr = c.wrenGetSlotForeign(ptr, 0);
            const req_ptr = c.wrenGetSlotForeign(ptr, 1);
            var batch = @as(*SubmissionBatch, @ptrCast(@alignCast(batch_ptr)));
            const req = @as(*Request, @ptrCast(@alignCast(req_ptr))).*;
            batch.requests.append(req) catch {};
            c.wrenSetSlotNull(ptr, 0);
        }

        fn completionBatchWait(ptr: *c.VM) callconv(.C) void {
            const comp_ptr = c.wrenGetSlotForeign(ptr, 0);
            const comp = @as(*CompletionBatch, @ptrCast(@alignCast(comp_ptr)));
            const n = @as(usize, @intFromFloat(c.wrenGetSlotDouble(ptr, 1)));
            while (comp.completed < n) {
                std.time.sleep(std.time.ns_per_ms);
            }
            c.wrenSetSlotNull(ptr, 0);
        }

        fn completionBatchWaitAll(ptr: *c.VM) callconv(.C) void {
            const comp_ptr = c.wrenGetSlotForeign(ptr, 0);
            const comp = @as(*CompletionBatch, @ptrCast(@alignCast(comp_ptr)));
            while (comp.completed < comp.expected) {
                std.time.sleep(std.time.ns_per_ms);
            }
            c.wrenSetSlotNull(ptr, 0);
        }

        pub fn syscall(self: *Self, fiber: *c.Handle, request: Request) !void {
            std.debug.print("syscall: {d} {s}\n", .{ fiber, @tagName(request) });
            var work = self.slots();
            const result = try self.dispatcher.dispatch(request, fiber);
            const setter = syscalls.generateResultSetter(SyscallsType);
            const freer = syscalls.generateResultFreer(SyscallsType, SyscallContext);
            switch (result) {
                .immediate => |x| {
                    defer c.wrenReleaseHandle(self.vm, fiber);
                    try setter.set(&work, 0, x);
                    freer.free(self.syscall_context, x);
                },
                .pending => {
                    _ = work.set(0, fiber);
                },
            }
        }

        pub fn submitBatch(
            self: *Self,
            fiber: *c.Handle,
            batch: *SubmissionBatch,
            completion: *CompletionBatch,
        ) !void {
            completion.expected = batch.requests.items.len;
            for (batch.requests.items) |req| {
                const result = try self.dispatcher.dispatch(req, fiber);
                switch (result) {
                    .immediate => {
                        completion.completed += 1;
                    },
                    .pending => {},
                }
            }
            batch.requests.clearRetainingCapacity();
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
            try self.runTopLevel("fs", @embedFile("fs.wren"));
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
    const Timer = struct {
        fiber: *c.Handle,
        deadline_ms: u64,
    };

    allocator: std.mem.Allocator,
    document: *dom.Dom,
    window: ?*WindowMod.Window = null,
    viewport_width: usize = 80,
    viewport_height: usize = 24,
    frame_fibers: std.ArrayListUnmanaged(*c.Handle) = .{},
    sleep_timers: std.ArrayListUnmanaged(Timer) = .{},
    key_events: std.ArrayListUnmanaged(u8) = .{},
    key_waiters: std.ArrayListUnmanaged(*c.Handle) = .{},

    pub fn deinit(self: *SyscallContext) void {
        if (self.window) |w| {
            w.deinit();
            self.allocator.destroy(w);
        }
        self.sleep_timers.deinit(self.allocator);
        self.key_events.deinit(self.allocator);
        self.key_waiters.deinit(self.allocator);
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

        pub fn closeWindow(engine: *EngineType, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
            _ = fiber; // autofix
            _ = args;
            if (context.window) |w| {
                w.deinit();
                context.document.alloc.destroy(w);
                context.window = null;
            }

            var i: usize = context.frame_fibers.items.len;
            while (i > 0) : (i -= 1) {
                const f = context.frame_fibers.items[i - 1];
                c.wrenReleaseHandle(engine.vm, f);
            }
            context.frame_fibers.clearRetainingCapacity();

            i = context.key_waiters.items.len;
            while (i > 0) : (i -= 1) {
                const f = context.key_waiters.items[i - 1];
                c.wrenReleaseHandle(engine.vm, f);
            }
            context.key_waiters.clearRetainingCapacity();
            context.key_events.clearRetainingCapacity();

            i = context.sleep_timers.items.len;
            while (i > 0) : (i -= 1) {
                const t = context.sleep_timers.items[i - 1];
                c.wrenReleaseHandle(engine.vm, t.fiber);
            }
            context.sleep_timers.clearRetainingCapacity();
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

        pub fn sleep(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { seconds: f64 }) anyerror!Pending {
            _ = engine;
            const now_ms = std.time.milliTimestamp();
            const delay_ms = @as(i64, @intFromFloat(args.seconds * 1000.0));
            const deadline: u64 = @intCast(now_ms + delay_ms);
            try context.sleep_timers.append(context.allocator, .{ .fiber = fiber, .deadline_ms = deadline });
            return syscalls.Pending{};
        }

        pub fn nextEvent(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { eventType: []const u8 }) anyerror!Pending {
            _ = engine;
            _ = args;
            try context.key_waiters.append(context.allocator, fiber);
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

        pub fn readFile(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { path: []const u8 }) anyerror![]const u8 {
            _ = engine;
            _ = fiber;
            return try std.fs.cwd().readFileAlloc(context.allocator, args.path, std.math.maxInt(usize));
        }

        pub fn writeFile(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { path: []const u8, data: []const u8 }) anyerror!void {
            _ = engine;
            _ = context;
            _ = fiber;
            try std.fs.cwd().writeFile(.{ .sub_path = args.path, .data = args.data });
        }

        pub fn readDir(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { path: []const u8 }) anyerror![]const u8 {
            _ = engine;
            _ = fiber;
            var dir = try std.fs.cwd().openDir(args.path, .{ .iterate = true });
            defer dir.close();
            var list = std.ArrayList(u8).init(context.allocator);
            var first = true;
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (first) {
                    first = false;
                } else {
                    try list.append('\n');
                }
                try list.appendSlice(entry.name);
            }
            return list.toOwnedSlice();
        }

        pub fn isDir(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { path: []const u8 }) anyerror!bool {
            _ = engine;
            _ = fiber;
            _ = context;
            const stat = try std.fs.cwd().statFile(args.path);
            return stat.kind == .directory;
        }

        pub fn exists(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { path: []const u8 }) anyerror!bool {
            _ = engine;
            _ = fiber;
            _ = context;
            _ = std.fs.cwd().statFile(args.path) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return false,
                else => return err,
            };
            return true;
        }

        pub fn remove(engine: *EngineType, context: *Context, fiber: Fiber, args: struct { path: []const u8 }) anyerror!void {
            _ = engine;
            _ = fiber;
            _ = context;
            try std.fs.cwd().deleteTree(args.path);
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
        \\import "syscall" for Print
        \\Core.call(Print.new("hello\n"))
        \\Core.call(Print.new("hello\n"))
    ) catch {
        try engine.croak();
    };

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(output, "hello\nhello\n");
    try std.testing.expect(engine.takeError() == .none);
}

test "can submit syscall batch" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = SyscallContext{ .allocator = allocator, .document = document };

    var engine = try Engine(.{}).init(allocator, .{ .syscall_context = &sc });
    defer engine.deinit();

    engine.runTopLevel("main",
        \\import "xtc" for Core
        \\import "syscall" for Print, SubmissionBatch
        \\var batch = SubmissionBatch.new(2)
        \\batch.add(Print.new("A"))
        \\batch.add(Print.new("B"))
        \\var cb = Core.submit(batch)
        \\cb.waitAll()
    ) catch {
        try engine.croak();
    };

    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("AB", output);
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
