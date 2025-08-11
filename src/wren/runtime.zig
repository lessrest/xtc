const std = @import("std");
const wren = @import("vm.zig");
const dom = @import("../dom.zig");
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;
const events = @import("../events.zig");
const EventType = events.EventType;

vm: wren.ScriptEngine(ScriptContext),
script_context: ScriptContext,
event_handles: std.ArrayList(*wren.c.Handle),
output: std.ArrayList(u8),

document: *Dom,

allocator: std.mem.Allocator,

pub const ScriptContext = struct {
    allocator: std.mem.Allocator,
    document: *Dom,
    output: *std.ArrayList(u8),
    event_handles: *std.ArrayList(*wren.c.Handle),
    viewport_width: usize = 80,
    viewport_height: usize = 24,

    pub const Modules = struct {
        pub const dom = struct {
            pub const DOM = @import("platform/DOM.zig");
        };
    };

    pub fn write(self: *@This(), text: []const u8) void {
        self.output.appendSlice(text) catch {};
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
        .event_handles = std.ArrayList(*wren.c.Handle).init(allocator),
    };

    this.script_context = .{
        .allocator = allocator,
        .document = this.document,
        .output = &this.output,
        .event_handles = &this.event_handles,
    };

    this.vm = try wren.create(ScriptContext, &this.script_context);

    try this.vm.registerForeignModules();

    try this.vm.interpret("dom", @embedFile("modules/dom.wren"));
    try this.vm.interpret("editor", @embedFile("modules/editor.wren"));
    try this.vm.interpret("main", "import \"dom\" for Document, Element");

    return this;
}

pub fn deinit(self: *@This()) void {
    for (self.event_handles.items) |handle| {
        wren.c.wrenReleaseHandle(self.vm.vm, handle);
    }

    self.event_handles.deinit();
    self.vm.deinit();
    self.document.deinit();
    self.output.deinit();
    self.allocator.destroy(self);
}
