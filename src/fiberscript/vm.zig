const std = @import("std");

comptime {
    @setEvalBranchQuota(200000);
}

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
const ticket = @import("../ticket.zig");

const ansi = @import("ansi");
const tree = ansi.nest;

const log = std.log.scoped(.vm);

pub const ErrorReport = ErrorHandler.ErrorReport;
pub const StackTraceLine = ErrorHandler.StackTraceLine;

allocator: std.mem.Allocator,
output_handler: OutputHandler,
error_handler: ErrorHandler,
syscaller: Syscaller,
vm: *c.VM,
context: *Context,

const Self = @This();

pub const FiberID = struct {
    handle: *c.Handle,
    ticket: [10]u8,

    pub fn init(handle: *c.Handle) FiberID {
        const tix = ticket.from(handle) catch {
            std.debug.panic("failed to get ticket for handle {p}", .{handle});
        };
        return FiberID{
            .handle = handle,
            .ticket = tix,
        };
    }

    pub fn deinit(self: FiberID, vm: *c.VM) void {
        c.wrenReleaseHandle(vm, self.handle);
    }
};

const FiberReader = struct {
    context: *Context,
    fiber: FiberID,
    reader: std.io.Reader,

    pub fn init(context: *Context, fiber: FiberID, buffer: []u8) FiberReader {
        return FiberReader{
            .context = context,
            .fiber = fiber,
            .reader = .{
                .vtable = &std.io.Reader.VTable{
                    .stream = stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn deinit(self: *FiberReader) void {
        log.info("deinit fiber reader {s}", .{self.fiber.ticket});
        self.fiber.deinit(self.context.vm);
        self.context.allocator.free(self.reader.buffer);
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *FiberReader = @alignCast(@fieldParentPtr("reader", r));
        var builder = self.context.slots();

        log.debug(
            "reader pulling max {d}B from fiber {s}",
            .{ limit.toInt().?, self.fiber.ticket },
        );

        if (builder.set(0, self.fiber)
            .callWithHandle(self.context.methodHandle(.isDone))
            .as(bool) catch {
            return error.EndOfStream;
        }) {
            return error.EndOfStream;
        }

        if (builder.set(0, self.fiber)
            .set(1, limit.toInt())
            .callWithHandle(self.context.methodHandle(.@"call(_)"))
            .as(?[]const u8)) |maybe_data|
        {
            if (maybe_data) |data| {
                log.debug("fiber {s} yielded {d}B", .{ self.fiber.ticket, data.len });
                return w.write(limit.sliceConst(data)) catch {
                    return error.WriteFailed;
                };
            } else {
                log.warn("{s} yielded null", .{self.fiber.ticket});
                return error.EndOfStream;
            }
        } else |err| {
            std.debug.print(
                "{s} failed to stream: {any}\n",
                .{ self.fiber.ticket, err },
            );
            return error.ReadFailed;
        }
    }
};

pub const Handle = *c.Handle;

pub const Context = struct {
    document: *dom.Dom,
    allocator: std.mem.Allocator,
    vm: *c.VM,

    thunks: std.ArrayList(FiberID) = .{},
    background_threads: std.ArrayList(std.Thread) = .{},
    fiber_readers: std.SegmentedList(FiberReader, 64) = .{},

    handles: std.EnumMap(enum {
        @"call()",
        @"call(_)",
        @"error",
        isDone,
    }, Handle) = .{},

    pub fn deinit(self: *Context) void {
        self.thunks.deinit(self.allocator);
        self.background_threads.deinit(self.allocator);

        var it = self.fiber_readers.iterator(0);
        while (it.next()) |reader| {
            reader.deinit();
        }

        self.fiber_readers.deinit(self.allocator);
        var it2 = self.handles.iterator();
        while (it2.next()) |entry| {
            c.wrenReleaseHandle(self.vm, entry.value.*);
        }
    }

    pub fn addBackgroundThread(self: *Context, thread: std.Thread) !void {
        log.debug("starting background thread", .{});
        try self.background_threads.append(self.allocator, thread);
    }

    pub fn joinBackgroundThreads(self: *Context) !void {
        const threads = try self.background_threads.toOwnedSlice(self.allocator);
        defer self.allocator.free(threads);
        for (threads) |thread| {
            thread.join();
            log.debug("joined background thread", .{});
        }
    }

    pub fn methodHandle(self: *Context, tag: @TypeOf(self.handles).Key) Handle {
        if (self.handles.get(tag)) |handle| {
            return handle;
        } else {
            const handle = c.wrenMakeCallHandle(self.vm, @tagName(tag)) orelse {
                std.debug.panic("failed to make call handle for {s}", .{@tagName(tag)});
            };
            self.handles.put(tag, handle);
            return handle;
        }
    }

    pub fn readableStreamFromFiber(self: *Context, fiber: FiberID, size: u32) !u32 {
        const index = self.fiber_readers.count();
        const reader = try self.fiber_readers.addOne(self.allocator);

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        reader.* = .init(self, fiber, buffer);
        log.debug("created reader {d} for fiber {s}", .{ index, fiber.ticket });
        return @as(u32, @intCast(index));
    }

    pub fn slots(self: *Context) slots_api.SlotBuilder {
        return slots_api.SlotBuilder.init(self.vm, self.allocator);
    }
};

const SyscallsType = documentSyscalls;
const Request = syscalls.RequestUnion(SyscallsType);
const Syscaller = syscalls.Syscaller(SyscallsType, Self, Context);

pub const Options = struct {
    output_buffer_size: usize = 1024 * 32,
    error_buffer_size: usize = 1024 * 32,
    context: *Context,
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

    self.context = options.context;
    self.syscaller = Syscaller{ .engine = self, .context = self.context };

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
        self.context.vm = vm;
    } else {
        return error.FailedToCreateVM;
    }

    errdefer c.wrenFreeVM(self.vm);
    errdefer self.croak() catch {};

    try self.bind();
}

pub fn deinit(self: *Self) void {
    self.error_handler.deinit(self.allocator);
    self.output_handler.deinit(self.allocator);

    c.wrenFreeVM(self.vm);

    self.allocator.destroy(self);
}

pub fn reallocateFn(
    memory: ?*anyopaque,
    new_size: usize,
    user_data: *anyopaque,
) callconv(.c) ?*anyopaque {
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
) callconv(.c) c.ForeignMethodFn {
    _ = vm;
    if (std.mem.eql(u8, std.mem.span(module), "xtc")) {
        if (std.mem.eql(u8, std.mem.span(className), "Core") and isStatic) {
            if (std.mem.eql(u8, std.mem.span(method), "syscall(_,_)")) {
                return &foreignSyscall;
            }
        }
    }

    return null;
}

fn bindForeignClassFn(
    vm: *c.VM,
    module: [*:0]const u8,
    className: [*:0]const u8,
) callconv(.c) c.ForeignClassMethods {
    _ = vm;
    var methods = c.ForeignClassMethods{};
    if (!std.mem.eql(u8, std.mem.span(module), "syscall")) return methods;

    inline for (@typeInfo(Request).@"union".fields) |field| {
        const class_name = syscalls.pascalCase(field.name);
        if (std.mem.eql(u8, std.mem.span(className), class_name)) {
            const PayloadType = field.type;
            const Alloc = struct {
                pub fn allocate(vm_ptr: *c.VM) callconv(.c) void {
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
                        } else if (pf.type == FiberID) {
                            @field(payload, pf.name) = FiberID.init(c.wrenGetSlotHandle(vm_ptr, slot_index).?);
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

fn loadModuleFn(vm: *c.VM, name: [*:0]const u8) callconv(.c) c.LoadModuleResult {
    _ = vm;
    if (std.mem.eql(u8, std.mem.span(name), "syscall")) {
        const src: [:0]const u8 = comptime blk: {
            const src = syscalls.generateWrenModule(SyscallsType) ++ "\x00";
            break :blk src;
        };
        return c.LoadModuleResult{ .source = src.ptr };
    }
    return c.LoadModuleResult{};
}

fn foreignSyscall(ptr: *c.VM) callconv(.c) void {
    var ctx: *Self = @ptrCast(@alignCast(c.wrenGetUserData(ptr)));
    var work = ctx.slots();
    const fiber = work.get(1, FiberID) catch {
        std.debug.panic("expected fiber", .{});
    };
    const req_ptr = c.wrenGetSlotForeign(ptr, 2);
    const request = @as(*Request, @ptrCast(@alignCast(req_ptr))).*;
    ctx.syscall(fiber, request) catch {
        std.debug.panic("failed to schedule fiber", .{});
    };
}

pub fn syscall(self: *Self, fiber: FiberID, request: Request) !void {
    log.debug("[+ syscall {s} {s}]", .{ fiber.ticket, @tagName(request) });
    var work = self.slots();
    const result = try self.syscaller.dispatch(request, fiber, &work);
    switch (result) {
        .immediate => |x| {
            log.debug("[! immediate]", .{});
            self.syscaller.free(x);
            fiber.deinit(self.vm);
        },
        .pending => {
            log.debug("[& suspended]", .{});
            _ = work.set(0, fiber);
        },
    }
}

/// C callback wrapper for output handling.
fn writeFn(vm: *c.VM, text: [*:0]const u8) callconv(.c) void {
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
) callconv(.c) void {
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

    log.warn("(top level enter)", .{});
    const result = c.wrenInterpret(self.vm, module_name_as_cstr, source_as_cstr);
    log.warn("(top level exit)", .{});

    const outcome = @as(c.InterpretResult, @enumFromInt(result));
    switch (outcome) {
        .success => {},
        .compile_error => {
            std.debug.print("\n=== WREN COMPILATION ERROR ===\n", .{});
            std.debug.print("Module: {s}\n", .{module_name});
            std.debug.print("Source code:\n{s}\n", .{source});
            std.debug.print("===============================\n\n", .{});
            return self.croak();
        },
        .runtime_error => {
            std.debug.print("\n=== WREN RUNTIME ERROR ===\n", .{});
            std.debug.print("Module: {s}\n", .{module_name});
            std.debug.print("Source code:\n{s}\n", .{source});
            std.debug.print("==========================\n\n", .{});
            return self.croak();
        },
    }
}

fn bind(self: *Self) !void {
    try self.runTopLevel("xtc", @embedFile("xtc.wren"));
    //    try self.runTopLevel("dom", @embedFile("dom.wren"));
}

pub fn takeOutput(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
    return self.output_handler.takeOutput(allocator);
}

pub fn croak(self: *Self) !void {
    return self.error_handler.croak();
}

pub fn slots(self: *Self) slots_api.SlotBuilder {
    return slots_api.SlotBuilder.init(self.vm, self.allocator);
}

const Fiber = FiberID;

pub fn slowlyDrainStreamThread(source: *FiberReader) void {
    var stdout = std.fs.File.stdout().writer(&.{});
    while (true) {
        std.Thread.sleep(std.time.ns_per_ms * 250);
        const n = source.reader.stream(&stdout.interface, .limited(3)) catch {
            break;
        };
        _ = n; // autofix
        stdout.interface.flush() catch {};
    }
}

const documentSyscalls = struct {
    pub fn start(
        engine: *Self,
        context: *Context,
        fiber: Fiber,
        args: struct { subfiber: FiberID },
    ) anyerror!void {
        _ = engine; // autofix
        log.info("{s} wants to start {s}", .{ fiber.ticket, args.subfiber.ticket });
        try context.thunks.append(context.allocator, args.subfiber);
    }

    pub fn readableStreamFromFiber(
        engine: *Self,
        context: *Context,
        fiber: Fiber,
        args: struct { size: u32, subfiber: FiberID },
    ) anyerror!u32 {
        _ = fiber; // autofix
        _ = engine;

        return try context.readableStreamFromFiber(args.subfiber, args.size);
    }

    pub fn slowlyDrainStream(
        engine: *Self,
        context: *Context,
        fiber: Fiber,
        args: struct { id: u32 },
    ) anyerror!void {
        _ = engine; // autofix
        _ = fiber; // autofix
        const readableStream = context.fiber_readers.at(args.id);

        try context.addBackgroundThread(
            try std.Thread.spawn(
                .{},
                slowlyDrainStreamThread,
                .{readableStream},
            ),
        );
    }

    pub fn print(engine: *Self, context: *Context, fiber: Fiber, args: struct { message: []const u8 }) anyerror!void {
        _ = engine; // autofix
        _ = fiber;
        _ = context;
        std.debug.print("{s}", .{args.message});
    }

    pub fn createElement(engine: *Self, context: *Context, fiber: Fiber, args: struct { style: []const u8 }) anyerror!dom.DomNodeId {
        _ = engine;
        _ = fiber;
        return context.document.addElement(args.style);
    }

    pub fn createText(engine: *Self, context: *Context, fiber: Fiber, args: struct { text: []const u8 }) anyerror!dom.DomNodeId {
        _ = fiber;
        _ = engine;
        return context.document.addText(args.text);
    }

    pub fn updateText(engine: *Self, context: *Context, fiber: Fiber, args: struct { nodeId: u32, text: []const u8 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.updateText(args.nodeId, args.text);
    }

    pub fn updateClass(engine: *Self, context: *Context, fiber: Fiber, args: struct { nodeId: u32, className: []const u8 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.updateClass(args.nodeId, args.className);
    }

    pub fn appendChild(engine: *Self, context: *Context, fiber: Fiber, args: struct { parentId: u32, childId: u32 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.appendChild(args.parentId, args.childId);
    }

    pub fn removeChild(engine: *Self, context: *Context, fiber: Fiber, args: struct { parentId: u32, childId: u32 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.removeChild(args.parentId, args.childId);
    }

    // pub fn openWindow(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     _ = args;
    //     if (context.window == null) {
    //         const w = try context.document.alloc.create(WindowMod.Window);
    //         w.* = try WindowMod.Window.init(context.document.alloc, .{
    //             .width = context.viewport_width,
    //             .height = context.viewport_height,
    //         });
    //         context.window = w;
    //     }
    //     var out_buf: [2048]u8 = undefined;
    //     var out_state = std.fs.File.stdout().writer(&out_buf);
    //     const out: *std.Io.Writer = &out_state.interface;
    //     try context.window.?.renderAndPresent(context.document, 0, out);
    //     try out.flush();
    // }

    // pub fn printElement(engine: *Self, context: *Context, fiber: Fiber, args: struct { nodeId: u32 }) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     if (context.window == null) {
    //         const w = try context.document.alloc.create(WindowMod.Window);
    //         w.* = try WindowMod.Window.init(context.document.alloc, .{
    //             .width = context.viewport_width,
    //             .height = context.viewport_height,
    //         });
    //         context.window = w;
    //     }
    //     const w = context.window.?;
    //     w.state.back.clear();
    //     var box_tree = try layout.allocateBoxTreeFromDOM(context.document.alloc, context.document, 0);
    //     defer box_tree.deinit();
    //     var layout_engine = layout.init(context.document.alloc, w.unicode, w.trace);
    //     try layout_engine.layoutSubtree(&box_tree, context.document, box_tree.getNodeMut(0), .{
    //         .x = 0,
    //         .y = 0,
    //         .w = w.opts.width,
    //         .h = w.opts.height,
    //     });
    //     var painter = Painter.init(context.document.alloc, w.unicode, w.trace);
    //     defer painter.deinit();
    //     try painter.computePaintCommands(context.document, &box_tree, w.glyphs);
    //     try w.state.back.rasterizeDisplayList(context.document.alloc, w.glyphs, &painter);

    //     var rect = layout.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    //     var found = false;
    //     for (box_tree.nodes.items) |node| {
    //         if (node.data.dom_id == args.nodeId) {
    //             rect = node.data.rect;
    //             found = true;
    //             break;
    //         }
    //     }
    //     if (!found) return;

    //     var out_buf2: [2048]u8 = undefined;
    //     var out_state2 = std.fs.File.stdout().writer(&out_buf2);
    //     const out2: *std.Io.Writer = &out_state2.interface;
    //     try w.state.back.writeSubRectAsPlainText(out2, w.glyphs, rect.x, rect.y, rect.w, rect.h);
    //     try out2.flush();
    // }

    // pub fn requestRender(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     _ = args;
    //     if (context.window) |w| {
    //         var out_buf3: [2048]u8 = undefined;
    //         var out_state3 = std.fs.File.stdout().writer(&out_buf3);
    //         const out3: *std.Io.Writer = &out_state3.interface;
    //         try w.renderAndPresent(context.document, 0, out3);
    //         try out3.flush();
    //     }
    // }

    // pub fn clearScreen(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     _ = context;
    //     _ = args;
    //     @panic("clearScreen not implemented");
    // }

    // pub fn requestAnimationFrame(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!Pending {
    //     _ = engine;
    //     _ = args;
    //     try context.frame_fibers.append(context.allocator, fiber);
    //     return syscalls.Pending{};
    // }

    // pub fn sleep(engine: *Self, context: *Context, fiber: Fiber, args: struct { seconds: f64 }) anyerror!Pending {
    //     _ = engine;
    //     const now_ms = std.time.milliTimestamp();
    //     const delay_ms = @as(i64, @intFromFloat(args.seconds * 1000.0));
    //     const deadline: u64 = @intCast(now_ms + delay_ms);
    //     try context.sleep_timers.append(context.allocator, .{ .fiber = fiber, .deadline_ms = deadline });
    //     return syscalls.Pending{};
    // }

};

test "we can create and destroy a VM" {
    const allocator = std.testing.allocator;
    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = Context.init(allocator, document);

    var vm = try Self.init(allocator, .{ .syscall_context = &sc });
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
    var sc = Context.init(allocator, document);

    var engine = try Self.init(allocator, .{ .syscall_context = &sc });
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
    var sc = Context.init(allocator, document);

    var engine = try Self.init(allocator, .{ .syscall_context = &sc });
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

test "slots API - simple method call" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = Context.init(allocator, document);

    var engine = try Self.init(allocator, .{ .syscall_context = &sc });
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
    var sc = Context.init(allocator, document);

    var engine = try Self.init(allocator, .{ .syscall_context = &sc });
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
    var sc = Context.init(allocator, document);

    var engine = try Self.init(allocator, .{ .syscall_context = &sc });
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
        .as(FiberID);
    defer c.wrenReleaseHandle(engine.vm, list_handle);

    var builder2 = engine.slots();
    _ = builder2.variable("test", "ListHelper", 0);
    _ = builder2.set(1, list_handle);
    const length = try builder2.call("getLength(_)").as(f64);

    try std.testing.expectEqual(@as(f64, 2), length);
}
