const std = @import("std");
const wren = @import("vm.zig");
const dom = @import("../dom.zig");
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;
const events = @import("../events.zig");
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
    viewport_width: usize = 80,
    viewport_height: usize = 24,

    pub const Modules = struct {
        pub const dom = struct {
            pub const DOM = struct {
                pub fn root(_: *wren.c.WrenVM, _: *ScriptContext) DomNodeId {
                    return 0;
                }

                pub fn viewportWidth(_: *wren.c.WrenVM, ctx: *ScriptContext) u32 {
                    return @intCast(ctx.viewport_width);
                }

                pub fn viewportHeight(_: *wren.c.WrenVM, ctx: *ScriptContext) u32 {
                    return @intCast(ctx.viewport_height);
                }

                pub fn createElement(_: *wren.c.WrenVM, ctx: *ScriptContext, style: []const u8) DomNodeId {
                    return ctx.document.addElement(style) catch @panic("createElement");
                }

                pub fn createText(_: *wren.c.WrenVM, ctx: *ScriptContext, text: []const u8) DomNodeId {
                    return ctx.document.addText(text) catch @panic("createText");
                }

                pub fn createClock(_: *wren.c.WrenVM, ctx: *ScriptContext, style: []const u8) DomNodeId {
                    // Create a clock node with the specified style
                    const node_id = ctx.document.addClock(style) catch @panic("createClock");
                    return node_id;
                }

                pub fn appendChild(_: *wren.c.WrenVM, ctx: *ScriptContext, parent: DomNodeId, child: DomNodeId) void {
                    ctx.document.appendChild(parent, child);
                }

                pub fn setDebugId(_: *wren.c.WrenVM, ctx: *ScriptContext, id: DomNodeId, label: []const u8) void {
                    ctx.document.setDebugId(id, label) catch @panic("setDebugId");
                }

                pub fn updateText(_: *wren.c.WrenVM, ctx: *ScriptContext, id: DomNodeId, text: []const u8) void {
                    ctx.document.updateText(id, text) catch @panic("updateText");
                }

                pub fn updateClass(_: *wren.c.WrenVM, ctx: *ScriptContext, id: DomNodeId, class: []const u8) void {
                    ctx.document.updateClass(id, class) catch @panic("updateClass");
                }

                pub fn getElementById(_: *wren.c.WrenVM, ctx: *ScriptContext, idStr: []const u8) DomNodeId {
                    // Search through debug_ids HashMap to find matching ID
                    var it = ctx.document.debug_ids.iterator();
                    while (it.next()) |entry| {
                        if (std.mem.eql(u8, entry.value_ptr.*, idStr)) {
                            return entry.key_ptr.*;
                        }
                    }
                    return std.math.maxInt(DomNodeId); // Return invalid ID if not found
                }

                pub fn removeChild(_: *wren.c.WrenVM, ctx: *ScriptContext, parent: DomNodeId, child: DomNodeId) void {
                    ctx.document.removeChild(parent, child);
                }

                pub fn getChildCount(_: *wren.c.WrenVM, ctx: *ScriptContext, id: DomNodeId) u32 {
                    const items = ctx.document.headers.slice();
                    return items.items(.child_count)[@intCast(id)];
                }

                pub fn getFirstChild(_: *wren.c.WrenVM, ctx: *ScriptContext, id: DomNodeId) DomNodeId {
                    const items = ctx.document.headers.slice();
                    return items.items(.first_child)[@intCast(id)];
                }

                // Event handling methods with callback parameters
                pub fn addEventListener(vm: *wren.c.WrenVM, ctx: *ScriptContext, node_id: DomNodeId, event_type_str: []const u8, handler: *wren.c.WrenHandle) u32 {
                    const event_type = EventType.fromString(event_type_str) orelse {
                        wren.c.wrenSetSlotString(vm, 0, "Unknown event type");
                        wren.c.wrenAbortFiber(vm, 0);
                        return 0;
                    };

                    const handler_id = ctx.document.event_registry.addEventListener(
                        node_id,
                        event_type,
                        handler,
                    ) catch {
                        wren.c.wrenSetSlotString(vm, 0, "Failed to add event listener");
                        wren.c.wrenAbortFiber(vm, 0);
                        return 0;
                    };

                    // Store handle to prevent GC
                    ctx.event_handles.append(handler) catch {
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
    try this.vm.interpret("dom", @embedFile("modules/dom.wren"));

    // Load editor module
    try this.vm.interpret("editor", @embedFile("modules/editor.wren"));

    // Import dom classes into main so scripts can use them
    try this.vm.interpret("main", "import \"dom\" for Document, Element");
    return this;
}

pub fn deinit(self: *@This()) void {
    // Release all event handles before destroying VM
    for (self.event_handles.items) |handle| {
        wren.c.wrenReleaseHandle(self.vm.ptr, handle);
    }
    self.event_handles.deinit();
    self.vm.deinit();
    self.document.deinit();
    self.output.deinit();
    self.allocator.destroy(self);
}

pub fn runScript(self: *@This(), script_id: []const u8, script: []const u8) !void {
    try self.vm.interpret(script_id, script);
}

pub fn getOutput(self: *const @This()) []const u8 {
    return self.output.items;
}

pub fn getDom(self: *@This()) *Dom {
    return self.document;
}
