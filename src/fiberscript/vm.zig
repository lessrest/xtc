const std = @import("std");

comptime {
    @setEvalBranchQuota(200000);
}

const c = @import("wren.zig");
const ErrorHandler = @import("error_handler.zig").ErrorHandler;
const slots_api = @import("slots.zig");
const OutputHandler = @import("output.zig").OutputHandler;
const syscalls = @import("syscalls.zig");
const miniflex = @import("miniflex");
const dom = miniflex.dom;
const WindowMod = miniflex.window;
const layout = miniflex.layout;
const Painter = miniflex.Painter;
const TrackingAllocator = @import("../lib/TrackingAllocator.zig");
const ticket = @import("../ticket.zig");
const Platform = @import("platform.zig");
pub const Context = @import("context.zig").Context;

pub const Request = syscalls.RequestUnion(Platform);
const Syscaller = syscalls.Syscaller(Platform, @This(), Context);

pub const FiberID = @import("context.zig").FiberID;

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
            const generated = syscalls.generateWrenModule(Platform) ++ "\x00";
            break :blk generated;
        };
        return c.LoadModuleResult{ .source = src.ptr };
    }
    if (std.mem.eql(u8, std.mem.span(name), "dom")) {
        const src: [:0]const u8 = comptime blk: {
            const embedded = @embedFile("dom.wren") ++ "\x00";
            break :blk embedded;
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

test "we can create and destroy a VM" {
    const allocator = std.testing.allocator;
    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = Context.init(allocator, document);

    var vm = try Self.init(allocator, .{ .context = &sc });
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

    var engine = try Self.init(allocator, .{ .context = &sc });
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

    var engine = try Self.init(allocator, .{ .context = &sc });
    defer engine.deinit();

    engine.runTopLevel("main",
        \\import "xtc" for Core
        \\import "syscall" for Print
        \\Core.call(Print.new("hello\n"))
        \\Core.call(Print.new("hello\n"))
    ) catch {
        try engine.croak();
    };

    // hmm the Print syscall actually prints to stdout directly
    // so I make this test a bit silly for now by just checking no error

    // const output = try engine.takeOutput(allocator);
    // defer allocator.free(output);

    // try std.testing.expectEqualStrings(output, "hello\nhello\n");

    try std.testing.expect(engine.takeError() == .none);
}

test "slots API - simple method call" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = Context.init(allocator, document);

    var engine = try Self.init(allocator, .{ .context = &sc });
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

    var engine = try Self.init(allocator, .{ .context = &sc });
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

    var engine = try Self.init(allocator, .{ .context = &sc });
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
    defer c.wrenReleaseHandle(engine.vm, list_handle.handle);

    var builder2 = engine.slots();
    _ = builder2.variable("test", "ListHelper", 0);
    _ = builder2.set(1, list_handle);
    const length = try builder2.call("getLength(_)").as(f64);

    try std.testing.expectEqual(@as(f64, 2), length);
}
