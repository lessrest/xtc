const std = @import("std");
const wren = @import("wren.zig");
const dom = @import("dom.zig");
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;

vm: wren.VM(ScriptContext),
allocator: std.mem.Allocator,
document: *Dom,
output: std.ArrayList(u8),
script_context: ScriptContext,

pub const ScriptContext = struct {
    allocator: std.mem.Allocator,
    document: *Dom,
    output: *std.ArrayList(u8),

    pub const Modules = struct {
        pub const dom = struct {
            pub const DOM = struct {
                pub fn root(_: *ScriptContext) DomNodeId {
                    return 0;
                }

                pub fn createElement(ctx: *ScriptContext, style: []const u8) DomNodeId {
                    return ctx.document.addElement(style) catch @panic("createElement");
                }

                pub fn createText(ctx: *ScriptContext, text: []const u8) DomNodeId {
                    return ctx.document.addText(text) catch @panic("createText");
                }

                pub fn appendChild(ctx: *ScriptContext, parent: DomNodeId, child: DomNodeId) void {
                    ctx.document.appendChild(parent, child);
                }

                pub fn setDebugId(ctx: *ScriptContext, id: DomNodeId, label: []const u8) void {
                    ctx.document.setDebugId(id, label) catch @panic("setDebugId");
                }
            };
        };
    };

    pub fn write(self: *@This(), text: []const u8) void {
        self.output.appendSlice(text) catch {};
    }

    pub fn onError(self: *@This(), error_type: wren.WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
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
    };
    this.script_context = .{
        .allocator = allocator,
        .document = this.document,
        .output = &this.output,
    };

    this.vm = try wren.create(ScriptContext, &this.script_context);
    // Auto-generate foreign classes from ScriptContext.Modules
    try this.vm.registerForeignModules();
    // Provide Wren convenience wrappers around DOM ids via embedded file
    try this.vm.interpret("dom", @embedFile("wren_wrappers/dom.wren"));
    // Example: call into Wren instead of interpreting adhoc code
    _ = try this.vm.callStaticGetNumber("main", "Num", "from(_)", .{1.0}); // no-op placeholder call
    return this;
}

pub fn deinit(self: *@This()) void {
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
