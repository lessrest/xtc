const std = @import("std");
const Dom = @import("dom.zig").Dom;
const DomNodeId = @import("dom.zig").DomNodeId;

// --- XML -> DOM mapping ---
pub const XmlDom = struct { dom: Dom, root: DomNodeId };

fn xmlAddElementRecursive(dom: *Dom, el: @import("xmlparse.zig").Element) !DomNodeId {
    const class_attr = el.attr("class") orelse "";
    const id = try dom.addElement(class_attr);
    if (el.content) |_| {
        const kids = el.children();
        var i: usize = 0;
        while (i < kids.len) : (i += 1) {
            const n = kids[i].v();
            switch (n) {
                .element => |child_el| {
                    const cid = try xmlAddElementRecursive(dom, child_el);
                    dom.appendChild(id, cid);
                },
                .text => |sidx| {
                    const tid = try dom.addText(sidx.slice());
                    dom.appendChild(id, tid);
                },
                .pi => |_| {},
            }
        }
    }
    return id;
}

pub fn loadDocumentFromMarkup(alloc: std.mem.Allocator, doc: *const @import("xml").Document) !Dom {
    var dom = Dom.init(alloc);
    doc.acquire();
    defer doc.release();
    _ = try xmlAddElementRecursive(&dom, doc.root);
    return dom;
}
