const std = @import("std");
const dom = @import("dom.zig");
const xmlparse = @import("xmlparse.zig");
const WrenRunner = @import("wren/runtime.zig");
const ticket = @import("ticket.zig");

allocator: std.mem.Allocator,
document: *dom.Dom,
wren_runner: *WrenRunner,

pub const LoadResult = struct {
    root_id: dom.DomNodeId,
};

pub const ScriptInfo = struct {
    source: []const u8,
    module_name: ?[]const u8,
    is_external: bool,
};

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    document: *dom.Dom,
    wren_runner: *WrenRunner,
) Self {
    return .{
        .allocator = allocator,
        .document = document,
        .wren_runner = wren_runner,
    };
}

/// Load from XML file with optional embedded scripts
pub fn loadXmlFile(self: *Self, path: []const u8) !LoadResult {
    const xml_content = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
    defer self.allocator.free(xml_content);

    return try self.loadXmlString(xml_content, path);
}

/// Load from XML string with optional embedded scripts
pub fn loadXmlString(self: *Self, xml_content: []const u8, source_name: []const u8) !LoadResult {
    var reader = std.io.fixedBufferStream(xml_content);
    var xml_doc = try xmlparse.parse(self.allocator, source_name, reader.reader());
    defer xml_doc.deinit();

    // Build DOM from XML
    xml_doc.acquire();
    defer xml_doc.release();

    const root_id = try self.buildDomFromXml(xml_doc.root, null);

    // Execute any scripts that were found
    try self.executeGatheredScripts();

    return .{ .root_id = root_id };
}

/// Recursively build DOM from XML and gather scripts
fn buildDomFromXml(self: *Self, element: xmlparse.Element, parent: ?dom.DomNodeId) !dom.DomNodeId {
    const class_attr = element.attr("class") orelse "";
    const node_id = try self.document.addElement(class_attr);

    if (element.attr("id")) |id_attr| {
        try self.document.setDebugId(node_id, id_attr);
    }

    const parent_id = parent orelse 0;
    self.document.appendChild(parent_id, node_id);

    const tag_name = element.tag_name.slice();

    // If this is a script element, gather it for later execution
    if (std.mem.eql(u8, tag_name, "script")) {
        try self.gatherScriptElement(element);
    }

    // Process children
    if (element.content) |_| {
        const children = element.children();
        for (children) |child| {
            switch (child.v()) {
                .element => |child_elem| {
                    _ = try self.buildDomFromXml(child_elem, node_id);
                },
                .text => |text| {
                    // Don't add text nodes inside script elements
                    if (!std.mem.eql(u8, tag_name, "script")) {
                        const text_id = try self.document.addText(text.slice());
                        self.document.appendChild(node_id, text_id);
                    }
                },
                .pi => {},
            }
        }
    }

    return node_id;
}

/// Gather script content from a script element
fn gatherScriptElement(self: *Self, element: xmlparse.Element) !void {
    var scripts = std.ArrayList(ScriptInfo).init(self.allocator);
    defer scripts.deinit();

    if (element.attr("src")) |src_path| {
        // External script
        const file = std.fs.cwd().openFile(src_path, .{}) catch |err| {
            std.debug.print("Warning: Failed to load script '{s}': {}\n", .{ src_path, err });
            return;
        };
        defer file.close();

        const file_content = try file.readToEndAlloc(self.allocator, 1024 * 1024);

        // Extract module name from filename
        const basename = std.fs.path.basename(src_path);
        const module_name = if (std.mem.endsWith(u8, basename, ".wren"))
            basename[0 .. basename.len - 5]
        else
            basename;

        try scripts.append(.{
            .source = file_content,
            .module_name = module_name,
            .is_external = true,
        });
    } else {
        // Inline script
        var source_buf = std.ArrayList(u8).init(self.allocator);
        try self.collectScriptText(element, &source_buf);

        if (source_buf.items.len > 0) {
            try scripts.append(.{
                .source = try source_buf.toOwnedSlice(),
                .module_name = element.attr("module"),
                .is_external = false,
            });
        }
    }

    // Execute the gathered scripts
    for (scripts.items) |script| {
        try self.wren_runner.executeScript(script.source, script.module_name, !script.is_external);
        if (script.is_external) {
            self.allocator.free(script.source);
        }
    }
}

/// Collect text content from script element
fn collectScriptText(self: *Self, element: xmlparse.Element, out: *std.ArrayList(u8)) !void {
    _ = self;
    if (element.content) |_| {
        const children = element.children();
        for (children) |child| {
            switch (child.v()) {
                .text => |text| {
                    try out.appendSlice(text.slice());
                },
                .element => {},
                .pi => {},
            }
        }
    }
}

/// Execute all gathered scripts (placeholder for now)
fn executeGatheredScripts(self: *Self) !void {
    _ = self;
    // Scripts are now executed immediately as they're gathered
}

/// Load from Wren script file
pub fn loadWrenFile(self: *Self, path: []const u8) !LoadResult {
    const wren_content = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
    defer self.allocator.free(wren_content);

    return try self.loadWrenString(wren_content, path);
}

/// Load from Wren script string
pub fn loadWrenString(self: *Self, script: []const u8, source_name: []const u8) !LoadResult {
    // Create a basic root element
    const root_id = try self.document.addElement("flex");
    try self.document.setDebugId(root_id, "root");

    // Run the Wren script which will populate the DOM
    const script_id = try ticket.from(source_name);
    try self.wren_runner.vm.interpret(&script_id, script);

    return .{ .root_id = root_id };
}

/// Create default demo UI
pub fn createDefault(self: *Self) !LoadResult {
    const root_id = try self.document.addElement("flex flex-col bg-slate-900 items-center justify-center");
    try self.document.setDebugId(root_id, "root");

    const text_id = try self.document.addText("No content provided. Use --xml <file> or --wren <file> to load content.");
    self.document.appendChild(root_id, text_id);

    return .{ .root_id = root_id };
}

// Tests for script execution in XML documents
test "script tags in XML documents execute wren code that can manipulate the DOM" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    var doc = try dom.Dom.init(al);
    defer doc.deinit();

    var runner = try WrenRunner.init(al, doc);
    defer runner.deinit();

    const xml_src =
        \\<root class="flex" id="test-root">
        \\  <script>
        \\    var root = Document.getElementById("test-root")
        \\    var el = Document.createElement("w-10")
        \\    root.append(el)
        \\    el.setDebugId("child")
        \\  </script>
        \\</root>
        \\
    ;

    var loader = init(al, doc, runner);
    _ = try loader.loadXmlString(xml_src, "inline");

    try std.testing.expect(doc.headers.len >= 2);

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

test "wren syntax errors in script tags return compile error without crashing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    var doc = try dom.Dom.init(al);
    defer doc.deinit();

    var runner = try WrenRunner.init(al, doc);
    defer runner.deinit();

    const xml_src =
        \\<root>
        \\  <script>
        \\    System.print("This should work")
        \\    invalid_syntax_here...
        \\  </script>
        \\</root>
    ;

    var loader = init(al, doc, runner);
    const result = loader.loadXmlString(xml_src, "inline");
    try std.testing.expectError(error.CompileError, result);
}

test "wren runtime errors in script tags return runtime error without crashing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    var doc = try dom.Dom.init(al);
    defer doc.deinit();

    var runner = try WrenRunner.init(al, doc);
    defer runner.deinit();

    const xml_src =
        \\<root>
        \\  <script>
        \\    var x = null
        \\    x.doesNotExist()
        \\  </script>
        \\</root>
    ;

    var loader = init(al, doc, runner);
    const result = loader.loadXmlString(xml_src, "inline");
    try std.testing.expectError(error.RuntimeError, result);
}
