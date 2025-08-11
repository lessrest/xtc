// Clean implementation of XML to DOM with Wren script execution
// Uses the module system for proper scope isolation

const std = @import("std");
const dom_mod = @import("dom.zig");
const xmlparse = @import("xmlparse.zig");
const wren = @import("wren.zig");

const Dom = dom_mod.Dom;
const DomNodeId = dom_mod.DomNodeId;

/// Build DOM from XML and execute embedded scripts
pub fn buildDomAndRunScripts(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    xml_doc: *const xmlparse.Document,
    vm: *wren.VM(UserData),
    dom: *Dom,
) !void {
    xml_doc.acquire();
    defer xml_doc.release();

    _ = try buildElement(UserData, allocator, xml_doc.root, vm, dom, null);
}

/// Recursively build DOM elements and handle scripts
fn buildElement(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    element: xmlparse.Element,
    vm: *wren.VM(UserData),
    dom: *Dom,
    parent: ?DomNodeId,
) !DomNodeId {
    // Create DOM node for this element
    const class_attr = element.attr("class") orelse "";
    const node_id = try dom.addElement(class_attr);

    // Set debug ID if id attribute is present
    if (element.attr("id")) |id_attr| {
        try dom.setDebugId(node_id, id_attr);
    }

    // Attach to parent if provided
    if (parent) |p| {
        dom.appendChild(p, node_id);
    }

    // Check if this is a script element
    const tag_name = element.tag_name.slice();
    if (std.mem.eql(u8, tag_name, "script")) {
        try processScriptElement(UserData, allocator, element, vm, node_id);
    }

    // Process children
    if (element.content) |_| {
        const children = element.children();
        for (children) |child| {
            switch (child.v()) {
                .element => |child_elem| {
                    _ = try buildElement(UserData, allocator, child_elem, vm, dom, node_id);
                },
                .text => |text| {
                    // Don't add text nodes inside script elements
                    if (!std.mem.eql(u8, tag_name, "script")) {
                        const text_id = try dom.addText(text.slice());
                        dom.appendChild(node_id, text_id);
                    }
                },
                .pi => {}, // Processing instructions ignored
            }
        }
    }

    return node_id;
}

/// Process a script element - load from file or inline
fn processScriptElement(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    element: xmlparse.Element,
    vm: *wren.VM(UserData),
    self_id: DomNodeId,
) !void {
    _ = self_id;
    var source_buf = std.ArrayList(u8).init(allocator);
    defer source_buf.deinit();

    var module_name: ?[]const u8 = null;

    // Check for external script via src attribute
    if (element.attr("src")) |src_path| {
        // Load from file
        const file = std.fs.cwd().openFile(src_path, .{}) catch |err| {
            std.debug.print("Warning: Failed to load script '{s}': {}\n", .{ src_path, err });
            return;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        try source_buf.ensureTotalCapacity(file_size);
        source_buf.items.len = try file.read(source_buf.unusedCapacitySlice());

        // Use filename (without extension) as module name
        const basename = std.fs.path.basename(src_path);
        if (std.mem.endsWith(u8, basename, ".wren")) {
            module_name = basename[0 .. basename.len - 5];
        } else {
            module_name = basename;
        }
    } else {
        // Collect inline script text
        try collectScriptText(element, &source_buf);

        // Check for module attribute to name inline scripts
        module_name = element.attr("module");
    }

    // Execute the script directly
    if (source_buf.items.len > 0) {
        vm.interpret(module_name orelse "global-script", source_buf.items) catch |err| {
            std.debug.print("Script error: {}\n", .{err});
            if (vm.user_data.output.items.len > 0) {
                std.debug.print("Wren output: {s}\n", .{vm.user_data.output.items});
            }
            return err;
        };
    }
}

/// Collect text content from script element
fn collectScriptText(element: xmlparse.Element, out: *std.ArrayList(u8)) !void {
    if (element.content) |_| {
        const children = element.children();
        for (children) |child| {
            switch (child.v()) {
                .text => |text| {
                    try out.appendSlice(text.slice());
                },
                .element => {}, // Ignore nested elements in scripts
                .pi => {},
            }
        }
    }
}
