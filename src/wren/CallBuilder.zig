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
};
