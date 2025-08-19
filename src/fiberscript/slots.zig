const std = @import("std");
const c = @import("wren.zig");
const Request = @import("vm.zig").Request;

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

        try self.ensureSlots(slot + 2);
        _ = self.set(slot + 1, cstr);
        c.wrenGetMapValue(self.vm, slot, slot + 1, slot + 2);
        return self.get(slot + 2, T);
    }

    pub fn get(self: *SlotBuilder, slot: c_int, comptime T: type) !T {
        return switch (T) {
            bool => c.wrenGetSlotBool(self.vm, slot),
            f64 => c.wrenGetSlotDouble(self.vm, slot),
            u32 => @intFromFloat(c.wrenGetSlotDouble(self.vm, slot)),
            usize => @intFromFloat(c.wrenGetSlotDouble(self.vm, slot)),
            []const u8 => std.mem.span(c.wrenGetSlotString(self.vm, slot)),
            *c.Handle => c.wrenGetSlotHandle(self.vm, slot) orelse error.NullHandle,
            Request => {
                try self.expect(slot, c.Type.map);
                const operation = try self.lookup(slot, "operation", []const u8);
                
                if (std.mem.eql(u8, operation, "Ring.flush")) {
                    const ring = try self.lookup(slot, "ring", *c.Handle);
                    const count = try self.lookup(slot, "count", u32);
                    return Request{
                        .@"Ring.flush" = .{
                            .ring = ring,
                            .count = count,
                        },
                    };
                }

                if (std.mem.eql(u8, operation, "Ring.wait")) {
                    const ring = try self.lookup(slot, "ring", *c.Handle);
                    const minComplete = try self.lookup(slot, "minComplete", u32);
                    return Request{
                        .@"Ring.wait" = .{
                            .ring = ring,
                            .minComplete = minComplete,
                        },
                    };
                }

                if (std.mem.eql(u8, operation, "Core.print")) {
                    const message = try self.lookup(slot, "message", []const u8);
                    return Request{
                        .@"Core.print" = .{
                            .message = message,
                        },
                    };
                }

                return error.InvalidOperation;
            },
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

    /// Make a method call with the current slot setup.
    pub fn call(self: *SlotBuilder, signature: []const u8) CallResult {
        if (self.has_error) {
            return CallResult.initError();
        }

        return CallResult.init(self.vm, self.allocator, signature);
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
            u32 => c.wrenSetSlotDouble(self.vm, slot, @floatFromInt(value)),
            []const u8 => {
                const cstr = try self.allocator.dupeZ(u8, value);
                defer self.allocator.free(cstr);
                c.wrenSetSlotString(self.vm, slot, cstr);
            },
            *c.Handle => c.wrenSetSlotHandle(self.vm, slot, value),
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
    allocator: std.mem.Allocator,
    result: c.InterpretResult,
    has_error: bool,

    pub fn init(vm: *c.VM, allocator: std.mem.Allocator, signature: []const u8) CallResult {
        const sig_cstr = allocator.dupeZ(u8, signature) catch {
            return CallResult.initError();
        };
        defer allocator.free(sig_cstr);

        const handle = c.wrenMakeCallHandle(vm, sig_cstr) orelse {
            return CallResult.initError();
        };
        defer c.wrenReleaseHandle(vm, handle);

        const result = c.wrenCall(vm, handle);

        return CallResult{
            .vm = vm,
            .allocator = allocator,
            .result = @enumFromInt(result),
            .has_error = false,
        };
    }

    pub fn initError() CallResult {
        return CallResult{
            .vm = undefined,
            .allocator = undefined,
            .result = .runtime_error,
            .has_error = true,
        };
    }

    pub fn as(self: CallResult, comptime T: type) !T {
        if (self.has_error) {
            return error.InternalError;
        }

        c.wrenEnsureSlots(self.vm, 1);

        return switch (T) {
            bool => c.wrenGetSlotBool(self.vm, 0),
            f64 => c.wrenGetSlotDouble(self.vm, 0),
            u32 => @intFromFloat(c.wrenGetSlotDouble(self.vm, 0)),
            usize => @intFromFloat(c.wrenGetSlotDouble(self.vm, 0)),
            []const u8 => std.mem.span(c.wrenGetSlotString(self.vm, 0)),
            *c.Handle => c.wrenGetSlotHandle(self.vm, 0) orelse error.NullHandle,
            Request => {
                var slot_builder = SlotBuilder.init(self.vm, self.allocator);
                return try slot_builder.get(0, Request);
            },

            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    /// Check if the call was successful.
    pub fn isSuccess(self: CallResult) bool {
        return !self.has_error and self.result == .success;
    }

    /// Check success and return appropriate error.
    fn checkSuccess(self: CallResult) !void {
        if (self.has_error) return error.InternalError;
        switch (self.result) {
            .success => {},
            .compile_error => return error.CompileError,
            .runtime_error => return error.RuntimeError,
        }
    }
};
