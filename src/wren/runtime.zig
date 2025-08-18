const std = @import("std");
const wren = @import("vm.zig");
const dom = @import("../dom.zig");
const scheduler_mod = @import("../scheduler.zig");
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;
const events = @import("../events.zig");
const EventType = events.EventType;
const writeReturn = @import("ffi_simple.zig").writeReturn;

vm: wren.ScriptEngine,
script_context: ScriptContext,
output: std.ArrayList(u8),

allocator: std.mem.Allocator,

pub const ScriptContext = struct {
    allocator: std.mem.Allocator,
    document: *Dom,
    output: *std.ArrayList(u8),
    viewport_width: usize = 80,
    viewport_height: usize = 24,

    scheduler: ?*scheduler_mod.Scheduler = null,
    fiber_call_handle: *wren.c.Handle = undefined,
    fiber_transfer_error_handle: *wren.c.Handle = undefined,

    pub const Platform = @import("platform/DOM.zig");

    pub fn write(self: *@This(), text: []const u8) void {
        if (self.scheduler) |scheduler| {
            if (!(text.len == 1 and text[0] == '\n')) {
                scheduler.trace.yell("print: \"{s}\"", .{text});
            }
        }

        self.output.appendSlice(text) catch {};
    }

    pub fn callFiber(self: *@This(), vm: *wren.c.VM, fiber: *wren.c.Handle, arg: anytype) !void {
        try self.call(vm, fiber, self.fiber_call_handle, arg);
    }

    pub fn callFiberWithReturnAlreadyInSlot1(self: *@This(), vm: *wren.c.VM, fiber: *wren.c.Handle) !void {
        wren.c.wrenSetSlotHandle(vm, 0, fiber);
        switch (@as(wren.c.InterpretResult, @enumFromInt(wren.c.wrenCall(vm, self.fiber_call_handle)))) {
            .success => {},
            .compile_error => {
                return error.CompileError;
            },
            .runtime_error => {
                return error.RuntimeError;
            },
        }
    }

    pub fn call(
        self: *@This(),
        vm: *wren.c.VM,
        receiver: *wren.c.Handle,
        method: *wren.c.Handle,
        arg: anytype,
    ) !void {
        _ = self; // autofix
        wren.c.wrenEnsureSlots(vm, 2);
        wren.c.wrenSetSlotHandle(vm, 0, receiver);
        writeReturn(vm, 1, arg);
        switch (@as(wren.c.InterpretResult, @enumFromInt(wren.c.wrenCall(vm, method)))) {
            .success => {},
            .compile_error => {
                return error.CompileError;
            },
            .runtime_error => {
                return error.RuntimeError;
            },
        }
    }

    pub fn rejectFiber(self: *@This(), vm: *wren.c.VM, fiber: *wren.c.Handle, message: []const u8) !void {
        try self.call(vm, fiber, self.fiber_transfer_error_handle, message);
    }

    pub fn onError(
        self: *@This(),
        error_type: wren.c.ErrorType,
        module: []const u8,
        line: c_int,
        message: []const u8,
    ) void {
        switch (error_type) {
            .compile => {
                std.fmt.format(
                    self.output.writer(),
                    "[{s} line {d}] Compile error: {s}\n",
                    .{ module, line, message },
                ) catch {};
            },
            .runtime => {
                std.fmt.format(
                    self.output.writer(),
                    "[{s} line {d}] Runtime error: {s}\n",
                    .{ module, line, message },
                ) catch {};
            },
            .stack_trace => {
                std.fmt.format(
                    self.output.writer(),
                    "  [{s} line {d}] in {s}\n",
                    .{ module, line, message },
                ) catch {};
            },
        }
        std.log.warn("VM {s} error in {s}:{d}: {s}\n", .{
            @tagName(error_type),
            module,
            line,
            message,
        });
    }
};

pub fn init(allocator: std.mem.Allocator, document: *Dom) !*@This() {
    var this = try allocator.create(@This());
    this.* = .{
        .allocator = allocator,
        .output = std.ArrayList(u8).init(allocator),
        .vm = undefined,
        .script_context = undefined,
    };

    this.script_context = .{
        .allocator = allocator,
        .document = document,
        .output = &this.output,
    };

    this.vm = try wren.create(&this.script_context);

    try this.vm.registerForeignModules();
    try this.vm.interpret("dom", @embedFile("modules/dom.wren"));

    return this;
}

pub fn deinit(self: *@This()) void {
    wren.c.wrenReleaseHandle(self.vm.vm, self.vm.ctx.fiber_call_handle);
    self.vm.deinit();
    self.output.deinit();
    self.allocator.destroy(self);
}

pub fn executeScript(self: *@This(), source: []const u8, module_name: ?[]const u8) !void {
    const script_module = module_name orelse "global-script";

    try self.vm.interpret(script_module, source);
}
