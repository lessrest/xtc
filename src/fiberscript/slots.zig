const std = @import("std");
const c = @import("wren.zig");
const syscalls = @import("syscalls.zig");
const FiberID = @import("vm.zig").FiberID;
const log = std.log.scoped(.slot);
/// Builder for setting up slots before making a call.
pub const SlotBuilder = struct {
    vm: *c.VM,
    allocator: std.mem.Allocator,
    next_slot: c_int,
    has_error: bool,

    pub fn init(vm: *c.VM, allocator: std.mem.Allocator) SlotBuilder {
        return SlotBuilder{
            .vm = vm,
            .allocator = allocator,
            .next_slot = 0,
            .has_error = false,
        };
    }

    pub fn countSlots(self: *SlotBuilder) c_int {
        return c.wrenGetSlotCount(self.vm);
    }

    /// Set a specific slot to a value.
    pub fn set(self: *SlotBuilder, slot: c_int, value: anytype) *SlotBuilder {
        if (self.has_error) return self;

        self.ensureSlots(slot + 1) catch {
            self.has_error = true;
            return self;
        };

        self.setSlotValue(slot, value) catch {
            self.has_error = true;
            return self;
        };

        if (slot >= self.next_slot) {
            self.next_slot = slot + 1;
        }

        return self;
    }

    pub fn expect(self: *SlotBuilder, slot: c_int, expected: c.Type) !void {
        const actual: c.Type = @enumFromInt(c.wrenGetSlotType(self.vm, slot));
        if (actual != expected) {
            return error.InvalidType;
        }
    }

    pub fn lookup(self: *SlotBuilder, slot: c_int, name: []const u8, comptime T: type) !T {
        const cstr = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(cstr);

        try self.ensureSlots(slot + 3);
        _ = self.set(slot + 1, cstr);
        c.wrenGetMapValue(self.vm, slot, slot + 1, slot + 2);
        return self.get(slot + 2, T);
    }

    pub fn mapSet(self: *SlotBuilder, slot: c_int, name: []const u8, value: anytype) !void {
        const cstr = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(cstr);
        try self.ensureSlots(slot + 3);
        _ = self.set(slot + 1, cstr);
        _ = self.set(slot + 2, value);
        c.wrenSetMapValue(self.vm, slot, slot + 1, slot + 2);
    }

    pub fn get(self: *SlotBuilder, slot: c_int, comptime T: type) !T {
        return switch (T) {
            bool => c.wrenGetSlotBool(self.vm, slot),
            f64 => c.wrenGetSlotDouble(self.vm, slot),
            u32 => @intFromFloat(c.wrenGetSlotDouble(self.vm, slot)),
            usize => @intFromFloat(c.wrenGetSlotDouble(self.vm, slot)),
            []const u8 => std.mem.span(c.wrenGetSlotString(self.vm, slot)),
            *c.Handle => c.wrenGetSlotHandle(self.vm, slot) orelse error.NullHandle,
            FiberID => FiberID.init(c.wrenGetSlotHandle(self.vm, slot).?),
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    pub fn variable(
        self: *SlotBuilder,
        module: [:0]const u8,
        name: [:0]const u8,
        slot: c_int,
    ) *SlotBuilder {
        self.ensureSlots(slot + 1) catch {
            self.has_error = true;
            return self;
        };

        c.wrenGetVariable(self.vm, module, name, slot);

        if (slot >= self.next_slot) {
            self.next_slot = slot + 1;
        }

        return self;
    }

    /// Set the next available slot to a value.
    pub fn push(self: *SlotBuilder, value: anytype) *SlotBuilder {
        const slot = self.next_slot;
        return self.set(slot, value);
    }

    const SlotMap = struct {
        slots: *SlotBuilder,
        slot: c_int,

        pub fn lookup(self: *SlotMap, name: []const u8, comptime T: type) !T {
            return self.slots.lookup(self.slot, name, T);
        }

        pub fn put(self: *SlotMap, name: []const u8, value: anytype) !void {
            return self.slots.mapSet(self.slot, name, value);
        }
    };

    pub fn slotMap(self: *SlotBuilder, slot: c_int) SlotMap {
        return SlotMap{ .slots = self, .slot = slot };
    }

    /// Make a method call with the current slot setup.
    pub fn call(self: *SlotBuilder, signature: []const u8) CallResult {
        if (self.has_error) {
            return CallResult.initError();
        }

        const cstr = self.allocator.dupeZ(u8, signature) catch {
            std.debug.panic("failed to dupe signature {s}", .{signature});
        };
        defer self.allocator.free(cstr);

        const handle = c.wrenMakeCallHandle(self.vm, cstr) orelse {
            self.has_error = true;
            return CallResult.initError();
        };

        defer c.wrenReleaseHandle(self.vm, handle);

        return self.callWithHandle(handle);
    }

    pub fn callWithHandle(self: *SlotBuilder, handle: *c.Handle) CallResult {
        if (self.has_error) {
            return CallResult.initError();
        }

        return CallResult.init(self.vm, handle);
    }

    /// Helper to ensure enough slots are available.
    fn ensureSlots(self: *SlotBuilder, count: c_int) !void {
        c.wrenEnsureSlots(self.vm, count);
    }

    /// Helper to set a slot value based on the SlotValue union.
    fn setSlotValue(self: *SlotBuilder, slot: c_int, value: anytype) !void {
        switch (@TypeOf(value)) {
            void => c.wrenSetSlotNull(self.vm, slot),
            bool => c.wrenSetSlotBool(self.vm, slot, value),
            f64 => c.wrenSetSlotDouble(self.vm, slot, value),
            comptime_int => c.wrenSetSlotDouble(self.vm, slot, @floatFromInt(value)),
            u8, i8, u16, i16, u32, i32, usize, isize => c.wrenSetSlotDouble(self.vm, slot, @floatFromInt(value)),
            ?usize => {
                if (value) |v| {
                    c.wrenSetSlotDouble(self.vm, slot, @floatFromInt(v));
                } else {
                    c.wrenSetSlotNull(self.vm, slot);
                }
            },
            []const u8 => {
                const cstr = try self.allocator.dupeZ(u8, value);
                defer self.allocator.free(cstr);
                c.wrenSetSlotString(self.vm, slot, cstr);
            },
            *c.Handle => c.wrenSetSlotHandle(self.vm, slot, value),
            FiberID => c.wrenSetSlotHandle(self.vm, slot, value.handle),
            syscalls.Pending => c.wrenSetSlotNull(self.vm, slot),
            else => |T| {
                const info = @typeInfo(T);
                if (info == .pointer and std.meta.Elem(@TypeOf(value)) == u8) {
                    const cstr = try self.allocator.dupeZ(u8, value);
                    defer self.allocator.free(cstr);
                    c.wrenSetSlotString(self.vm, slot, cstr);
                } else {
                    @compileError("Unsupported type: " ++ @typeName(T));
                }
            },
        }
    }
};

/// Result of a method call, providing type-safe value extraction.
pub const CallResult = struct {
    vm: *c.VM,
    result: c.InterpretResult,
    has_error: bool,

    pub fn init(vm: *c.VM, handle: *c.Handle) CallResult {
        const result = c.wrenCall(vm, handle);

        return CallResult{
            .vm = vm,
            .result = @enumFromInt(result),
            .has_error = false,
        };
    }

    pub fn initError() CallResult {
        return CallResult{
            .vm = undefined,
            .result = .runtime_error,
            .has_error = true,
        };
    }

    pub fn as(self: CallResult, comptime T: type) !T {
        if (self.has_error) {
            return error.InternalError;
        }

        c.wrenEnsureSlots(self.vm, 1);

        const ty = @typeInfo(T);
        if (ty == .optional) {
            const type_id = c.wrenGetSlotType(self.vm, 0);
            if (@as(c.Type, @enumFromInt(type_id)) == c.Type.null) {
                return null;
            }
            return try self.as(ty.optional.child);
        }

        return switch (T) {
            bool => c.wrenGetSlotBool(self.vm, 0),
            f64 => c.wrenGetSlotDouble(self.vm, 0),
            u32 => @intFromFloat(c.wrenGetSlotDouble(self.vm, 0)),
            usize => @intFromFloat(c.wrenGetSlotDouble(self.vm, 0)),
            []const u8 => std.mem.span(c.wrenGetSlotString(self.vm, 0)),
            *c.Handle => c.wrenGetSlotHandle(self.vm, 0) orelse error.NullHandle,
            FiberID => FiberID.init(c.wrenGetSlotHandle(self.vm, 0).?),
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    /// Check if the call was successful.
    pub fn isSuccess(self: CallResult) bool {
        return !self.has_error and self.result == .success;
    }

    /// Check success and return appropriate error.
    pub fn checkSuccess(self: CallResult) !void {
        if (self.has_error) return error.InternalError;
        switch (self.result) {
            .success => {},
            .compile_error => return error.CompileError,
            .runtime_error => return error.RuntimeError,
        }
    }
};
