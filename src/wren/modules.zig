// Wren module system integration for XTC
// Provides clean module loading and script execution

const std = @import("std");
const wren = @import("vm.zig");
const dom_mod = @import("../dom.zig");

const Dom = dom_mod.Dom;
const DomNodeId = dom_mod.DomNodeId;

// ============================================================================
// Module Registry - Manages script modules dynamically loaded from DOM
// ============================================================================

pub const ModuleRegistry = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap([]const u8),
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap([]const u8).init(allocator),
            .next_id = 0,
        };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.modules.deinit();
    }

    /// Register an anonymous script and get an auto-generated module name
    pub fn registerAnonymous(self: *ModuleRegistry, source: []const u8) ![]const u8 {
        const module_name = try std.fmt.allocPrint(self.allocator, "script_{}", .{self.next_id});
        self.next_id += 1;

        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);

        try self.modules.put(module_name, source_copy);
        return module_name;
    }

    /// Register a script with a specific module name
    pub fn registerNamed(self: *ModuleRegistry, name: []const u8, source: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);

        try self.modules.put(name_copy, source_copy);
    }

    /// Get the source code for a registered module
    pub fn getSource(self: *ModuleRegistry, name: []const u8) ?[]const u8 {
        return self.modules.get(name);
    }

    /// Check if a module is registered
    pub fn hasModule(self: *ModuleRegistry, name: []const u8) bool {
        return self.modules.contains(name);
    }
};

// ============================================================================
// Module Loader - Wren callback for loading modules
// ============================================================================

/// Create a module loader function for a specific UserData type
pub fn createModuleLoader(comptime UserData: type) wren.c.LoadModuleFn {
    return struct {
        fn load(vm: ?*wren.c.WrenVM, name: [*c]const u8) callconv(.C) wren.c.LoadModuleResult {
            std.debug.print("Module loader: Loading module '{s}'\n", .{std.mem.span(name)});
            const vm_ptr = vm orelse return .{
                .source = null,
                .onComplete = null,
                .userData = null,
            };
            const user_ptr = wren.c.wrenGetUserData(vm_ptr);

            const user_data = @as(*UserData, @ptrCast(@alignCast(user_ptr)));
            const module_name = std.mem.span(name);

            // First check script registry for dynamically registered modules
            if (@hasField(UserData, "module_registry")) {
                if (user_data.module_registry.getSource(module_name)) |source| {
                    std.debug.print("Module loader: Found module '{s}' in registry\n", .{module_name});
                    // Allocate a null-terminated copy for Wren
                    const source_copy = user_data.allocator.dupeZ(u8, source) catch return .{
                        .source = null,
                        .onComplete = null,
                        .userData = null,
                    };

                    return .{
                        .source = source_copy.ptr,
                        .onComplete = null, // Wren will free this
                        .userData = null,
                    };
                }
            }

            // For non-script modules, try loading from wren_wrappers directory
            if (!std.mem.startsWith(u8, module_name, "script_")) {
                const file_path = std.fmt.allocPrintZ(user_data.allocator, "src/wren_wrappers/{s}.wren", .{module_name}) catch return .{
                    .source = null,
                    .onComplete = null,
                    .userData = null,
                };
                defer user_data.allocator.free(file_path);
                defer std.debug.print("Module loader: uhdhhh file '{s}'\n", .{file_path});
                const file = std.fs.cwd().openFile(file_path, .{}) catch return .{
                    .source = null,
                    .onComplete = null,
                    .userData = null,
                };
                defer file.close();

                const file_size = file.getEndPos() catch return .{
                    .source = null,
                    .onComplete = null,
                    .userData = null,
                };

                const source = user_data.allocator.allocSentinel(u8, file_size, 0) catch return .{
                    .source = null,
                    .onComplete = null,
                    .userData = null,
                };

                _ = file.read(source) catch {
                    user_data.allocator.free(source);
                    return .{
                        .source = null,
                        .onComplete = null,
                        .userData = null,
                    };
                };

                return .{
                    .source = source.ptr,
                    .onComplete = null,
                    .userData = null,
                };
            }

            // Module not found
            return .{
                .source = null,
                .onComplete = null,
                .userData = null,
            };
        }
    }.load;
}

// ============================================================================
// Script Execution - Clean interface for running script modules
// ============================================================================

pub const ScriptExecutor = struct {
    /// Check if source code defines a Script class (module convention)
    pub fn hasScriptClass(source: []const u8) bool {
        return std.mem.indexOf(u8, source, "class Script") != null;
    }

    /// Execute a script module 
    pub fn executeModule(
        comptime UserData: type,
        vm: *wren.VM(UserData),
        module_name: []const u8,
        self_id: DomNodeId,
    ) !void {
        _ = self_id; // Scripts use getElementById instead
        std.debug.print("Executing module '{s}'\n", .{module_name});
        
        // Get the module source from registry
        const registry = vm.user_data.module_registry;
        const source = registry.getSource(module_name) orelse {
            std.debug.print("Module '{s}' not found in registry\n", .{module_name});
            return error.ModuleNotFound;
        };
        
        // Just run the script directly
        vm.interpret("main", source) catch |err| {
            std.debug.print("Failed to interpret module: {}\n", .{err});
            if (vm.user_data.output.items.len > 0) {
                std.debug.print("Wren output: {s}\n", .{vm.user_data.output.items});
            }
            return err;
        };
    }

    /// Execute inline script (backward compatibility)
    pub fn executeInline(
        comptime UserData: type,
        vm: *wren.VM(UserData),
        source: []const u8,
        self_id: DomNodeId,
    ) !void {
        vm.callStatic("dom", "ScriptRunner", "executeInline(_,_)", .{
            self_id,
            source,
        }) catch |err| {
            std.debug.print("Failed to execute inline script: {}\n", .{err});
            return err;
        };
    }

    /// Process a script element - register and execute appropriately
    pub fn processScript(
        comptime UserData: type,
        vm: *wren.VM(UserData),
        source: []const u8,
        self_id: DomNodeId,
        name: ?[]const u8,
    ) !void {
        if (!@hasField(UserData, "module_registry")) {
            return error.NoModuleRegistry;
        }

        const registry = vm.user_data.module_registry;

        // Check if this follows the module convention
        if (hasScriptClass(source)) {
            // Register as a module
            const module_name = if (name) |n| blk: {
                try registry.registerNamed(n, source);
                break :blk n;
            } else try registry.registerAnonymous(source);

            // Execute the module
            try executeModule(UserData, vm, module_name, self_id);
        } else {
            // Execute as inline script (backward compatibility)
            try executeInline(UserData, vm, source, self_id);
        }
    }
};
