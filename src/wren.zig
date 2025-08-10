const std = @import("std");

// Wren C API bindings
pub const c = @cImport({
    @cInclude("wren.h");
});

// Zig-friendly wrapper around Wren VM
pub const VM = struct {
    ptr: *c.WrenVM,
    allocator: std.mem.Allocator,
    user_data: *UserData,
    
    // User data struct to pass allocator to callbacks
    const UserData = struct {
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
    };
    
    pub fn init(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !VM {
        var config: c.WrenConfiguration = undefined;
        c.wrenInitConfiguration(&config);
        
        // Set up callbacks
        config.writeFn = writeFn;
        config.errorFn = errorFn;
        config.loadModuleFn = null;
        config.bindForeignMethodFn = null;
        config.bindForeignClassFn = null;
        
        // Store user data (allocator and output buffer)
        const user_data = try allocator.create(UserData);
        user_data.* = .{
            .allocator = allocator,
            .output = output,
        };
        config.userData = user_data;
        
        const vm_ptr = c.wrenNewVM(&config) orelse return error.VMCreationFailed;
        
        return VM{
            .ptr = vm_ptr,
            .allocator = allocator,
            .user_data = user_data,
        };
    }
    
    pub fn deinit(self: *VM) void {
        self.allocator.destroy(self.user_data);
        c.wrenFreeVM(self.ptr);
    }
    
    pub fn interpret(self: *VM, module_name: []const u8, source: []const u8) !void {
        // Null-terminate strings for C API
        const module_z = try self.allocator.dupeZ(u8, module_name);
        defer self.allocator.free(module_z);
        
        const source_z = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(source_z);
        
        const result = c.wrenInterpret(self.ptr, module_z, source_z);
        
        switch (result) {
            c.WREN_RESULT_SUCCESS => {},
            c.WREN_RESULT_COMPILE_ERROR => return error.CompileError,
            c.WREN_RESULT_RUNTIME_ERROR => return error.RuntimeError,
            else => return error.UnknownError,
        }
    }
    
    // Callback functions for Wren VM
    fn writeFn(vm: ?*c.WrenVM, text: [*c]const u8) callconv(.C) void {
        if (vm) |vm_ptr| {
            const user_data_ptr = c.wrenGetUserData(vm_ptr);
            if (user_data_ptr) |ptr| {
                const user_data: *UserData = @ptrCast(@alignCast(ptr));
                const str = std.mem.span(text);
                user_data.output.appendSlice(str) catch {};
            }
        }
    }
    
    fn errorFn(
        vm: ?*c.WrenVM,
        error_type: c.WrenErrorType,
        module: [*c]const u8,
        line: c_int,
        message: [*c]const u8,
    ) callconv(.C) void {
        if (vm) |vm_ptr| {
            const user_data_ptr = c.wrenGetUserData(vm_ptr);
            if (user_data_ptr) |ptr| {
                const user_data: *UserData = @ptrCast(@alignCast(ptr));
                const module_str = std.mem.span(module);
                const msg_str = std.mem.span(message);
                
                switch (error_type) {
                    c.WREN_ERROR_COMPILE => {
                        const err_msg = std.fmt.allocPrint(
                            user_data.allocator,
                            "[{s} line {d}] Compile error: {s}\n",
                            .{ module_str, line, msg_str },
                        ) catch return;
                        defer user_data.allocator.free(err_msg);
                        user_data.output.appendSlice(err_msg) catch {};
                    },
                    c.WREN_ERROR_RUNTIME => {
                        const err_msg = std.fmt.allocPrint(
                            user_data.allocator,
                            "Runtime error: {s}\n",
                            .{msg_str},
                        ) catch return;
                        defer user_data.allocator.free(err_msg);
                        user_data.output.appendSlice(err_msg) catch {};
                    },
                    c.WREN_ERROR_STACK_TRACE => {
                        const err_msg = std.fmt.allocPrint(
                            user_data.allocator,
                            "  [{s} line {d}] in {s}\n",
                            .{ module_str, line, msg_str },
                        ) catch return;
                        defer user_data.allocator.free(err_msg);
                        user_data.output.appendSlice(err_msg) catch {};
                    },
                    else => {},
                }
            }
        }
    }
};

// Simple wrapper for one-shot evaluation
pub fn eval(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    var vm = try VM.init(allocator, &output);
    defer vm.deinit();
    
    try vm.interpret("main", source);
    
    return output.toOwnedSlice();
}