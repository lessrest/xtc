const std = @import("std");
const dom_mod = @import("dom.zig");
const xmlparse = @import("xmlparse.zig");
const wren = @import("wren.zig");

const Dom = dom_mod.Dom;
const DomNodeId = dom_mod.DomNodeId;

fn collectScriptText(el: xmlparse.Element, out: *std.ArrayList(u8)) !void {
    if (el.content) |_| {
        const kids = el.children();
        var i: usize = 0;
        while (i < kids.len) : (i += 1) {
            const n = kids[i].v();
            switch (n) {
                .text => |sidx| {
                    try out.appendSlice(sidx.slice());
                },
                .element => |child_el| {
                    // ignore nested elements inside <script>
                    _ = child_el;
                },
                .pi => |_| {},
            }
        }
    }
}

pub fn buildDomIntoAndRunScripts(comptime UserData: type, allocator: std.mem.Allocator, doc: *const xmlparse.Document, vm: *wren.VM(UserData), document: *Dom) !void {
    doc.acquire();
    defer doc.release();

    const recurse = struct {
        fn go(d: *Dom, el: xmlparse.Element, a: std.mem.Allocator, the_vm: *wren.VM(UserData)) !DomNodeId {
            const class_attr = el.attr("class") orelse "";
            const id = try d.addElement(class_attr);

            const tag = el.tag_name.slice();
            const is_script = std.mem.eql(u8, tag, "script");

            if (is_script) {
                var buf = std.ArrayList(u8).init(a);
                defer buf.deinit();
                try collectScriptText(el, &buf);
                try the_vm.callStatic("dom", "ScriptRunner", "run(_,_)", .{ id, buf.items });
            }

            if (el.content) |_| {
                const kids = el.children();
                var i: usize = 0;
                while (i < kids.len) : (i += 1) {
                    const n = kids[i].v();
                    switch (n) {
                        .element => |child_el| {
                            const cid = try go(d, child_el, a, the_vm);
                            d.appendChild(id, cid);
                        },
                        .text => |sidx| {
                            if (!is_script) {
                                const tid = try d.addText(sidx.slice());
                                d.appendChild(id, tid);
                            }
                        },
                        .pi => |_| {},
                    }
                }
            }
            return id;
        }
    };

    _ = try recurse.go(document, doc.root, allocator, vm);
}

pub fn buildDomAndRunScripts(comptime UserData: type, allocator: std.mem.Allocator, doc: *const xmlparse.Document, vm: *wren.VM(UserData)) !Dom {
    var document = Dom.init(allocator);
    try buildDomIntoAndRunScripts(UserData, allocator, doc, vm, &document);
    return document;
}
