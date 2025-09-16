const std = @import("std");

comptime {
    @setEvalBranchQuota(200000);
}

const c = @import("wren.zig");
const slots_api = @import("slots.zig");
const syscalls = @import("syscalls.zig");
const miniflex = @import("miniflex");
const dom = miniflex.dom;
const WindowMod = miniflex.window;
const layout = miniflex.layout;
const Painter = miniflex.Painter;
const TrackingAllocator = @import("../lib/TrackingAllocator.zig");
const Platform = @import("platform.zig");
pub const Context = @import("context.zig").Context;

pub const Request = syscalls.RequestUnion(Platform);
const Syscaller = syscalls.Syscaller(Platform, @This(), Context);

pub const FiberID = @import("context.zig").FiberID;

const ansi = @import("ansi");
const tree = ansi.nest;

const log = std.log.scoped(.vm);

pub const WrenError = error{
    CompilationError,
    RuntimeError,
};

allocator: std.mem.Allocator,
output_writer: *std.Io.Writer,
error_writer: *std.Io.Writer,
problem: ?WrenError = null,
syscaller: Syscaller,
vm: *c.VM,
context: *Context,

const Self = @This();

var discarding = std.Io.Writer.Discarding.init(&.{});
const devnull = &discarding.writer;

pub const Options = struct {
    context: *Context,
    output_writer: *std.Io.Writer = devnull,
    error_writer: *std.Io.Writer = devnull,
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

    self.output_writer = options.output_writer;
    self.error_writer = options.error_writer;

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

    try self.bind();
}

pub fn deinit(self: *Self) void {
    self.output_writer.flush() catch {};
    self.error_writer.flush() catch {};
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
    self.output_writer.print("{s}", .{text}) catch {};
    self.output_writer.flush() catch {};
}

pub fn write(self: *Self, text: []const u8) void {
    self.output_writer.print("{s}", .{text}) catch {};
    self.output_writer.flush() catch {};
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
    switch (error_type) {
        .stack_trace => {
            self.error_writer.print("  at {s}:{d}\n", .{
                if (module_ptr) |m| m else "unknown",
                line,
            }) catch {};
        },

        .compile => {
            self.problem = WrenError.CompilationError;
            self.error_writer.print("Wren compiler error at [{s}:{d}]: {s}\n", .{
                if (module_ptr) |m| m else "unknown",
                line,
                if (message_ptr) |msg| msg else "unknown error",
            }) catch {};
        },

        .runtime => {
            self.problem = WrenError.RuntimeError;
            self.error_writer.print("Wren runtime error: {s}\n", .{
                if (message_ptr) |msg| msg else "unknown error",
            }) catch {};
        },
    }
}

pub fn checkError(self: *Self) !void {
    if (self.problem) |e| {
        self.error_writer.flush() catch {};
        return e;
    }
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

    if (result != 0) {
        return error.ScriptError;
    }
}

fn bind(self: *Self) !void {
    try self.runTopLevel("xtc", @embedFile("xtc.wren"));
    //    try self.runTopLevel("dom", @embedFile("dom.wren"));
}

pub fn slots(self: *Self) slots_api.SlotBuilder {
    return slots_api.SlotBuilder.init(self.vm, self.allocator);
}

const Fiber = FiberID;

var stderrbuf: [512]u8 = undefined;
var stderrstate = std.fs.File.stderr().writer(&stderrbuf);
const stderr: *std.Io.Writer = &stderrstate.interface;

test "we can create and destroy a VM" {
    const allocator = std.testing.allocator;
    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = Context.init(allocator, document);
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var vm = try Self.init(allocator, .{
        .context = &sc,
        .output_writer = &writer,
        .error_writer = stderr,
    });
    defer vm.deinit();
    try vm.checkError();
}

test "we can run a simple script" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = Context.init(allocator, document);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var engine = try Self.init(allocator, .{ .context = &sc, .output_writer = &writer });
    defer engine.deinit();

    try engine.runTopLevel("foo",
        \\System.print("Hello, world!")
    );

    try std.testing.expectEqualStrings(writer.buffered(), "Hello, world!\n");
}

test "we can call Core.call" {
    const allocator = std.testing.allocator;

    var document = try dom.Dom.init(allocator);
    defer document.deinit();
    var sc = Context.init(allocator, document);

    var engine = try Self.init(allocator, .{ .context = &sc });
    defer engine.deinit();

    try engine.runTopLevel("main",
        \\import "xtc" for Core
        \\import "syscall" for Print
        \\Core.call(Print.new("hello\n"))
        \\Core.call(Print.new("hello\n"))
    );

    // hmm the Print syscall actually prints to stdout directly
    // so I make this test a bit silly for now by just checking no error

    // const output = try engine.takeOutput(allocator);
    // defer allocator.free(output);

    // try std.testing.expectEqualStrings(output, "hello\nhello\n");
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
