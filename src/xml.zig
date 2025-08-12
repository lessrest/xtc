const std = @import("std");
const Dom = @import("dom.zig").Dom;
const DomNodeId = @import("dom.zig").DomNodeId;

// --- XML -> DOM mapping ---
pub const XmlDom = struct { dom: Dom, root: DomNodeId };

fn xmlAddElementRecursive(dom: *Dom, el: @import("xmlparse.zig").Element) !DomNodeId {
    const class_attr = el.attr("class") orelse "";
    const id = try dom.addElement(class_attr);

    // Set debug ID if present
    if (el.attr("id")) |id_attr| {
        try dom.setDebugId(id, id_attr);
    }
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

pub fn loadDocumentFromMarkup(alloc: std.mem.Allocator, doc: *const @import("xmlparse.zig").Document) !*Dom {
    var dom = try Dom.init(alloc);
    errdefer dom.deinit();

    doc.acquire();
    defer doc.release();

    const root = doc.root;
    const tag_name = root.tag_name.slice();

    // Special handling for top-level <root> element:
    // Instead of creating a new node, reuse the document root (node 0)
    if (std.mem.eql(u8, tag_name, "root")) {
        // Apply the root element's attributes to the document root
        if (root.attr("id")) |id_attr| {
            try dom.setDebugId(0, id_attr);
        }

        if (root.attr("class")) |class_attr| {
            try dom.updateClass(0, class_attr);
        }

        // Process children of <root> and attach them to the document root
        if (root.content) |_| {
            const kids = root.children();
            var i: usize = 0;
            while (i < kids.len) : (i += 1) {
                const n = kids[i].v();
                switch (n) {
                    .element => |child_el| {
                        const cid = try xmlAddElementRecursive(dom, child_el);
                        dom.appendChild(0, cid);
                    },
                    .text => |sidx| {
                        const tid = try dom.addText(sidx.slice());
                        dom.appendChild(0, tid);
                    },
                    .pi => |_| {},
                }
            }
        }
    } else {
        // Normal case: create a new element and attach to document root
        const root_id = try xmlAddElementRecursive(dom, root);
        dom.appendChild(0, root_id);
    }

    return dom;
}

test "top-level <root> element becomes document root" {
    const xmlparse = @import("xmlparse.zig");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const xml_src =
        \\<root id="foo">
        \\</root>
    ;

    var fbs = std.io.fixedBufferStream(xml_src);
    var xdoc = try xmlparse.parse(al, "<stdin>", fbs.reader());
    defer xdoc.deinit();

    var document = try loadDocumentFromMarkup(al, &xdoc);
    defer document.deinit();

    const root_id = document.getDebugId(0);
    try std.testing.expect(root_id != null);
    try std.testing.expectEqualStrings("foo", root_id.?);
}
