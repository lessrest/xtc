const std = @import("std");
const wren = @import("wren.zig");
const dom = @import("dom.zig");
const xmlparse = @import("xmlparse.zig");
const wren_xml = @import("wren_xml.zig");

const Dom = dom.Dom;
const DomNodeId = dom.DomNodeId;

test "xml <script> executes and manipulates DOM" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    // ScriptContext that writes to a buffer and can see a DOM
    const ScriptContext = struct {
        const SC = @This();
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
        document: *Dom,

        pub const Modules = struct {
            pub const dom = struct {
                pub const DOM = struct {
                    pub fn root(_: *wren.c.WrenVM, _: *SC) DomNodeId {
                        return 0;
                    }
                    pub fn createElement(_: *wren.c.WrenVM, ctx: *SC, style: []const u8) DomNodeId {
                        return ctx.document.addElement(style) catch @panic("createElement");
                    }
                    pub fn createText(_: *wren.c.WrenVM, ctx: *SC, text: []const u8) DomNodeId {
                        return ctx.document.addText(text) catch @panic("createText");
                    }
                    pub fn appendChild(_: *wren.c.WrenVM, ctx: *SC, p: DomNodeId, c: DomNodeId) void {
                        ctx.document.appendChild(p, c);
                    }
                    pub fn setDebugId(_: *wren.c.WrenVM, ctx: *SC, id: DomNodeId, label: []const u8) void {
                        ctx.document.setDebugId(id, label) catch @panic("setDebugId");
                    }
                };
            };
        };

        pub fn write(self: *@This(), text: []const u8) void {
            self.output.appendSlice(text) catch {};
        }
        pub fn onError(self: *@This(), _: wren.c.ErrorType, module: []const u8, line: c_int, message: []const u8) void {
            _ = line;
            _ = module;
            std.debug.print("onError: {s}\n", .{message});
            self.output.appendSlice(message) catch {};
        }
    };

    var output = std.ArrayList(u8).init(al);
    defer output.deinit();

    var doc = Dom.init(al);
    defer doc.deinit();

    var ctx = ScriptContext{ .allocator = al, .output = &output, .document = &doc };
    var vm = try wren.create(ScriptContext, &ctx);
    defer vm.deinit();

    // Load wrappers
    try vm.registerForeignModules();
    try vm.interpret("dom", @embedFile("wren_wrappers/dom.wren"));

    // XML with a script that appends a child and sets a debug id
    const xml_src =
        \\<root class="flex">
        \\  <script>
        \\    var el = document.createElement("w-10")
        \\    self.append(el)
        \\    self.setDebugId("child")
        \\  </script>
        \\</root>
        \\
    ;

    var reader = std.io.fixedBufferStream(xml_src);
    var xml_doc = try xmlparse.parse(al, "inline", reader.reader());
    defer xml_doc.deinit();

    try wren_xml.buildDomIntoAndRunScripts(ScriptContext, al, &xml_doc, &vm, &doc);

    // root has one child with debug id "child"
    const items = doc.headers.slice();
    try std.testing.expectEqual(@as(u32, 1), items.items(.child_count)[0]);

    // There should be a node with debug id "child"
    var found = false;
    var it = doc.debug_ids.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.value_ptr.*, "child")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
