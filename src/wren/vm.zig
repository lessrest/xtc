const std = @import("std");

pub const c = @import("c.zig");

const TrackedAllocator = @import("../lib/TrackingAllocator.zig");
const ffi_simple = @import("ffi.zig");
const ScriptContext = @import("runtime.zig").ScriptContext;

pub const ScriptEngine = struct {
    vm: *c.VM,
    ctx: *ScriptContext,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *ScriptContext) !Self {
        var config: c.Configuration = .{};
        c.wrenInitConfiguration(&config);

        config.writeFn = writeFn;
        config.errorFn = errorFn;
        config.loadModuleFn = null;
        config.bindForeignMethodFn = bindForeignMethodFn;
        config.bindForeignClassFn = null;
        config.reallocateFn = reallocateFn;
        config.userData = ctx;

        const vm_ptr = c.wrenNewVM(&config) orelse return error.VMCreationFailed;

        ctx.fiber_call_handle = c.wrenMakeCallHandle(vm_ptr, "call(_)") orelse return error.FailedToMakeCallHandle;
        ctx.fiber_transfer_error_handle = c.wrenMakeCallHandle(vm_ptr, "transferError(_)") orelse return error.FailedToMakeCallHandle;

        return Self{
            .vm = vm_ptr,
            .ctx = ctx,
            .allocator = ctx.allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        c.wrenReleaseHandle(self.vm, self.ctx.fiber_call_handle);
        c.wrenReleaseHandle(self.vm, self.ctx.fiber_transfer_error_handle);
        c.wrenFreeVM(self.vm);
    }

    pub fn interpret(self: *Self, module_name: []const u8, source: []const u8) !void {
        const module_z = try self.allocator.dupeZ(u8, module_name);
        defer self.allocator.free(module_z);

        const source_z = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(source_z);

        const result = c.wrenInterpret(self.vm, module_z, source_z);

        switch (@as(c.InterpretResult, @enumFromInt(result))) {
            .success => {},
            .compile_error => {
                return error.CompileError;
            },
            .runtime_error => {
                return error.RuntimeError;
            },
        }
    }

    fn setValueSlot(vm: *c.VM, slot: c_int, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    c.wrenSetSlotBytes(vm, slot, value.ptr, value.len);
                    return;
                }
                @panic(@typeName(T));
            },
            .int => {
                const d: f64 = @floatFromInt(value);
                c.wrenSetSlotDouble(vm, slot, d);
                return;
            },
            .float => {
                const d: f64 = if (@TypeOf(value) == f64) value else @as(f64, value);
                c.wrenSetSlotDouble(vm, slot, d);
                return;
            },
            .bool => {
                c.wrenSetSlotBool(vm, slot, value);
                return;
            },
            else => @panic(@typeName(T)),
        }
    }

    pub fn registerForeignModules(self: *Self) !void {
        const wrapper_src = try ffi_simple.generateWrenWrappers(self.allocator);
        defer self.allocator.free(wrapper_src);

        if (wrapper_src.len > 0) {
            if (self.interpret("xtc", wrapper_src)) |_| {
                // ok
            } else |err| {
                std.debug.print("Error interpreting xtc module: {any}\n", .{err});
                std.debug.print("Source:\n{s}\n", .{wrapper_src});
                return err;
            }
        }
    }

    fn reallocateFn(memory: ?*anyopaque, new_size: usize, ctxptr: *anyopaque) callconv(.C) ?*anyopaque {
        const ctx: *ScriptContext = @ptrCast(@alignCast(ctxptr));
        const allocator = ctx.allocator;
        var tracked = TrackedAllocator.create(allocator);

        if (new_size == 0) {
            if (memory) |mem| {
                const ptr: [*]u8 = @ptrCast(mem);
                tracked.free(ptr);
                return null;
            } else {
                return null;
            }
        } else if (memory) |mem| {
            const old_ptr: [*]u8 = @ptrCast(mem);
            return tracked.realloc(old_ptr, new_size);
        } else {
            return tracked.alloc(new_size);
        }
    }

    fn writeFn(vm: *c.VM, text: [*:0]const u8) callconv(.C) void {
        const ptr = c.wrenGetUserData(vm);
        const ctx: *ScriptContext = @ptrCast(@alignCast(ptr));
        const str = std.mem.span(text);
        ctx.write(str);
    }

    fn errorFn(
        vm: *c.VM,
        error_type: c.ErrorType,
        module: ?[*:0]const u8,
        line: c_int,
        message: ?[*:0]const u8,
    ) callconv(.C) void {
        const ptr = c.wrenGetUserData(vm);
        const ctx: *ScriptContext = @ptrCast(@alignCast(ptr));
        const module_str = if (module) |m| std.mem.span(m) else "";
        const msg_str = if (message) |m| std.mem.span(m) else "";
        ctx.onError(error_type, module_str, line, msg_str);
    }

    fn abortWithError(vm: *c.VM, msg: []const u8) void {
        c.wrenSetSlotBytes(vm, 0, msg.ptr, msg.len);
        c.wrenAbortFiber(vm, 0);
    }

    pub const foreign_functions = ffi_simple.platform_functions;

    fn bindForeignMethodFn(
        vm: *c.VM,
        moduleName: [*:0]const u8,
        className: [*:0]const u8,
        isStatic: bool,
        signature: [*:0]const u8,
    ) callconv(.C) c.ForeignMethodFn {
        _ = vm; // unused
        if (!isStatic) return null;

        if (std.mem.eql(u8, std.mem.span(moduleName), "xtc") and
            std.mem.eql(u8, std.mem.span(className), "Kernel") and
            std.mem.eql(u8, std.mem.span(signature), "enqueue(_)"))
        {
            return enqueue;
        }

        return null;
    }
};

fn enqueue(vm: *c.VM) callconv(.C) void {
    const ptr = c.wrenGetUserData(vm);
    const ctx: *ScriptContext = @ptrCast(@alignCast(ptr));
    const slot_count = c.wrenGetSlotCount(vm);

    if (slot_count != 2) {
        c.wrenSetSlotString(vm, 0, "Expected one fiber argument");
        c.wrenAbortFiber(vm, 0);
        return;
    }

    const fiber = c.wrenGetSlotHandle(vm, 1) orelse {
        c.wrenSetSlotString(vm, 0, "Invalid fiber handle");
        c.wrenAbortFiber(vm, 0);
        return;
    };

    if (ctx.scheduler) |scheduler| {
        scheduler.enqueueReady(fiber) catch {
            std.debug.panic("Error enqueuing fiber", .{});
        };
    } else {
        c.wrenSetSlotString(vm, 0, "No scheduler");
        c.wrenAbortFiber(vm, 0);
        return;
    }
}

// Simple wrapper for creating a VM
pub fn create(x: *ScriptContext) !ScriptEngine {
    return try ScriptEngine.init(x);
}
