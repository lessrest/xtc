const std = @import("std");
const wren = @import("vm.zig");

pub const CallBuilder = struct {
    vm: *wren.c.VM,

    pub fn init(vm: *wren.c.VM) CallBuilder {
        return .{ .vm = vm };
    }

    pub fn ensureSlots(self: *CallBuilder, n: c_int) void {
        wren.c.wrenEnsureSlots(self.vm, n);
    }

    pub fn beginMap(self: *CallBuilder, slot_index: c_int) void {
        wren.c.wrenSetSlotNewMap(self.vm, slot_index);
    }

    pub fn mapPutStr(self: *CallBuilder, map_slot: c_int, key: [:0]const u8, val: []const u8) void {
        // Uses slots 0 and 1 as scratch
        wren.c.wrenSetSlotString(self.vm, 0, key);
        wren.c.wrenSetSlotBytes(self.vm, 1, val.ptr, val.len);
        wren.c.wrenSetMapValue(self.vm, map_slot, 0, 1);
    }

    pub fn mapPutNum(self: *CallBuilder, map_slot: c_int, key: [:0]const u8, val: f64) void {
        wren.c.wrenSetSlotString(self.vm, 0, key);
        wren.c.wrenSetSlotDouble(self.vm, 1, val);
        wren.c.wrenSetMapValue(self.vm, map_slot, 0, 1);
    }

    pub fn callFiber(self: *CallBuilder, fiber: *wren.c.Handle, arg_slot: c_int) !void {
        _ = arg_slot; // autofix
        // Put receiver in slot 0
        wren.c.wrenSetSlotHandle(self.vm, 0, fiber);
        // arg is already in arg_slot
        const call = wren.c.wrenMakeCallHandle(self.vm, "call(_)") orelse return;
        defer wren.c.wrenReleaseHandle(self.vm, call);
        const result = wren.c.wrenCall(self.vm, call);
        switch (@as(wren.c.InterpretResult, @enumFromInt(result))) {
            .success => {},
            .compile_error => {
                return error.CompileError;
            },
            .runtime_error => {
                return error.RuntimeError;
            },
        }
    }
};
