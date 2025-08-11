const std = @import("std");
const wren = @import("wren.zig");
const dom = @import("dom.zig");
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;
const events = @import("events.zig");
const EventType = events.EventType;

vm: wren.VM(ScriptContext),
allocator: std.mem.Allocator,
document: *Dom,
output: std.ArrayList(u8),
script_context: ScriptContext,
// Store handles to prevent Wren GC
event_handles: std.ArrayList(*wren.c.WrenHandle),

pub const ScriptContext = struct {
    allocator: std.mem.Allocator,
    document: *Dom,
    output: *std.ArrayList(u8),
    event_handles: *std.ArrayList(*wren.c.WrenHandle),

    pub const Modules = struct {
        pub const dom = struct {
            pub const DOM = struct {
                pub fn root(_: *wren.c.WrenVM, _: *ScriptContext) DomNodeId {
                    return 0;
                }

                pub fn createElement(_: *wren.c.WrenVM, ctx: *ScriptContext, style: []const u8) DomNodeId {
                    return ctx.document.addElement(style) catch @panic("createElement");
                }

                pub fn createText(_: *wren.c.WrenVM, ctx: *ScriptContext, text: []const u8) DomNodeId {
                    return ctx.document.addText(text) catch @panic("createText");
                }

                pub fn appendChild(_: *wren.c.WrenVM, ctx: *ScriptContext, parent: DomNodeId, child: DomNodeId) void {
                    ctx.document.appendChild(parent, child);
                }

                pub fn setDebugId(_: *wren.c.WrenVM, ctx: *ScriptContext, id: DomNodeId, label: []const u8) void {
                    ctx.document.setDebugId(id, label) catch @panic("setDebugId");
                }

                // Event handling methods
                pub fn addEventListener(vm: *wren.c.WrenVM, ctx: *ScriptContext, node_id: DomNodeId, event_type_str: []const u8) u32 {
                    // Get the callback handle from slot 3 (the next slot after the arguments)
                    const handle = wren.c.wrenGetSlotHandle(vm, 3) orelse {
                        wren.c.wrenSetSlotString(vm, 0, "Invalid callback function");
                        wren.c.wrenAbortFiber(vm, 0);
                        return 0;
                    };
                    
                    const event_type = EventType.fromString(event_type_str) orelse {
                        wren.c.wrenSetSlotString(vm, 0, "Unknown event type");
                        wren.c.wrenAbortFiber(vm, 0);
                        return 0;
                    };
                    
                    const handler_id = ctx.document.event_registry.addEventListener(
                        node_id,
                        event_type,
                        handle,
                    ) catch {
                        wren.c.wrenSetSlotString(vm, 0, "Failed to add event listener");
                        wren.c.wrenAbortFiber(vm, 0);
                        return 0;
                    };
                    
                    // Store handle to prevent GC
                    ctx.event_handles.append(handle) catch {
                        wren.c.wrenSetSlotString(vm, 0, "Failed to store event handle");
                        wren.c.wrenAbortFiber(vm, 0);
                        return 0;
                    };
                    
                    return handler_id;
                }

                pub fn removeEventListener(_: *wren.c.WrenVM, ctx: *ScriptContext, node_id: DomNodeId, event_type_str: []const u8, handler_id: u32) bool {
                    const event_type = EventType.fromString(event_type_str) orelse return false;
                    return ctx.document.event_registry.removeEventListener(node_id, event_type, handler_id);
                }
            };
        };
    };

    pub fn write(self: *@This(), text: []const u8) void {
        self.output.appendSlice(text) catch {};
    }

    pub fn onError(self: *@This(), error_type: wren.c.ErrorType, module: []const u8, line: c_int, message: []const u8) void {
        switch (error_type) {
            .compile => {
                std.fmt.format(self.output.writer(), "[{s} line {d}] Compile error: {s}\n", .{ module, line, message }) catch {};
            },
            .runtime => {
                std.fmt.format(self.output.writer(), "[{s} line {d}] Runtime error: {s}\n", .{ module, line, message }) catch {};
            },
            .stack_trace => {
                std.fmt.format(self.output.writer(), "  [{s} line {d}] in {s}\n", .{ module, line, message }) catch {};
            },
        }
    }
};

pub fn init(allocator: std.mem.Allocator, document: *Dom) !*@This() {
    var this = try allocator.create(@This());
    this.* = .{
        .allocator = allocator,
        .document = document,
        .output = std.ArrayList(u8).init(allocator),
        .vm = undefined,
        .script_context = undefined,
        .event_handles = std.ArrayList(*wren.c.WrenHandle).init(allocator),
    };
    this.script_context = .{
        .allocator = allocator,
        .document = this.document,
        .output = &this.output,
        .event_handles = &this.event_handles,
    };

    this.vm = try wren.create(ScriptContext, &this.script_context);
    // Auto-generate foreign classes from ScriptContext.Modules
    try this.vm.registerForeignModules();
    // Provide Wren convenience wrappers around DOM ids via embedded file
    try this.vm.interpret("dom", @embedFile("wren_wrappers/dom.wren"));
    return this;
}

pub fn deinit(self: *@This()) void {
    // Release all event handles before destroying VM
    for (self.event_handles.items) |handle| {
        wren.c.wrenReleaseHandle(self.vm.ptr, handle);
    }
    self.event_handles.deinit();
    self.vm.deinit();
    self.allocator.destroy(self);
    self.document.deinit();
    self.output.deinit();
}

pub fn runScript(self: *@This(), script: []const u8) !void {
    try self.vm.interpret("main", script);
}

pub fn getOutput(self: *const @This()) []const u8 {
    return self.output.items;
}

pub fn getDom(self: *@This()) *Dom {
    return self.document;
}
