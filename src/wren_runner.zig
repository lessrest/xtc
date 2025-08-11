const std = @import("std");
const wren = @import("wren.zig");
const dom = @import("dom.zig");
const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;

vm: wren.VM(ScriptContext),
allocator: std.mem.Allocator,
document: Dom,
output: std.ArrayList(u8),
script_context: ScriptContext,

pub const ScriptContext = struct {
    allocator: std.mem.Allocator,
    document: *Dom,
    output: *std.ArrayList(u8),

    pub const Modules = struct {
        pub const dom = struct {
            pub const DOM = struct {
                pub fn hello(ctx: *ScriptContext) !void {
                    try ctx.output.writer().print("hello world\n", .{});
                }

                pub fn say(ctx: *ScriptContext, x: []const u8) !void {
                    try ctx.output.writer().writeAll(x);
                }

                // pub fn createElement(ctx: *ScriptContext, style: []const u8) !void {
                //     _ = try ctx.document.addElement(style);
                // }

                // pub fn createText(ctx: *ScriptContext, text: []const u8) !void {
                //     _ = try ctx.document.addText(text);
                // }
            };
        };
    };

    pub fn write(self: *@This(), text: []const u8) void {
        self.output.appendSlice(text) catch {};
    }

    pub fn onError(self: *@This(), error_type: wren.WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
        switch (error_type) {
            wren.WREN_ERROR_COMPILE => {
                std.fmt.format(self.output.writer(), "[{s} line {d}] Compile error: {s}\n", .{ module, line, message }) catch {};
            },
            wren.WREN_ERROR_RUNTIME => {
                std.fmt.format(self.output.writer(), "[{s} line {d}] Runtime error: {s}\n", .{ module, line, message }) catch {};
            },
            wren.WREN_ERROR_STACK_TRACE => {
                std.fmt.format(self.output.writer(), "  [{s} line {d}] in {s}\n", .{ module, line, message }) catch {};
            },
            else => {},
        }
    }
};

pub fn init(allocator: std.mem.Allocator) !*@This() {
    var this = try allocator.create(@This());
    this.* = .{
        .allocator = allocator,
        .document = Dom.init(allocator),
        .output = std.ArrayList(u8).init(allocator),
        .vm = undefined,
        .script_context = undefined,
    };
    this.script_context = .{
        .allocator = allocator,
        .document = &this.document,
        .output = &this.output,
    };

    _ = try this.document.addElement("");

    this.vm = try wren.create(ScriptContext, &this.script_context);
    try this.vm.interpret("dom",
        \\class DOM {
        \\    foreign static hello()
        \\    foreign static say(text)
        \\}
        \\
        \\DOM.hello()
        \\DOM.say("uhh")
    );
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
    return &self.document;
}
