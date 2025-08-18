pub usingnamespace @import("style.zig");
pub usingnamespace @import("layout.zig");
pub usingnamespace @import("dom.zig");
pub usingnamespace @import("tailwind.zig");
pub usingnamespace @import("paint.zig");
pub usingnamespace @import("tty.zig");
pub usingnamespace @import("xml.zig");

pub const TreeNest = @import("ansi").nest;

comptime {
    _ = @import("pageload.zig");
    _ = @import("xml.zig");
}

const std = @import("std");
const builtin = @import("builtin");

const style = @import("style.zig");
const layout = @import("layout.zig");
const dom = @import("dom.zig");
const tailwind = @import("tailwind.zig");
const paint = @import("paint.zig");
const tty = @import("tty.zig");
const xml = @import("xml.zig");
const xmlparse = @import("xmlparse.zig");
const Trace = @import("Trace.zig");

pub const DisplayWidth = @import("DisplayWidth");
pub const Graphemes = @import("Graphemes");
pub const Words = @import("Words");

// pub const trealla = @import("trealla.zig"); // Replaced with Wren
pub const wren = @import("wren/vm.zig");

const DomNodeId = dom.DomNodeId;

const Rect = layout.Rect;
const BoxNode = dom.BoxNode;
const Dom = dom.Dom;
const BoxTree = layout.BoxTree;

/// Helper for tests: pick the first top-level element as root and build a BoxTree.
pub fn allocateBoxTreeFromDOMAutoRoot(alloc: std.mem.Allocator, document: *const Dom) !BoxTree {
    const items = document.headers.slice();
    var i: usize = 0;
    while (i < document.headers.len) : (i += 1) {
        if (items.items(.parent)[i] == Dom.NullId and switch (items.items(.content)[i]) {
            .element => true,
            else => false,
        }) {
            const root: DomNodeId = @intCast(i);
            return try layout.allocateBoxTreeFromDOM(alloc, document, root);
        }
    }
    // Fallback: empty tree with root 0 if no element found
    return layout.allocateBoxTreeFromDOM(alloc, document, 0);
}
// Functions are already exported via usingnamespace above

// --- Test helpers (compact and integration-focused) ---
fn expectAsciiEqual(want: []const u8, got: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        var itw = std.mem.splitScalar(u8, want, '\n');
        while (itw.next()) |line| {
            std.debug.print("yay: \"{s}\"\n", .{line});
        }
        std.debug.print("\n", .{});
        var itg = std.mem.splitScalar(u8, got, '\n');
        while (itg.next()) |line| {
            std.debug.print("nay: \"{s}\"\n", .{line});
        }
        return error.AsciiMismatch;
    }
}

pub fn renderXmlAscii(
    al: std.mem.Allocator,
    xml_input: []const u8,
    width: usize,
    height: usize,
) ![]u8 {
    var fbs = std.io.fixedBufferStream(xml_input);
    var xdoc = try xmlparse.parse(al, "<stdin>", fbs.reader());
    defer xdoc.deinit();

    var document = try xml.loadDocumentFromMarkup(al, &xdoc);
    defer document.deinit();

    var tree = try allocateBoxTreeFromDOMAutoRoot(al, document);
    defer tree.deinit();

    var unicode = try paint.UnicodeData.init(al);
    defer unicode.deinit(al);

    // Initialize root tracer for the entire rendering pipeline
    var trace = Trace.file(std.io.getStdErr(), .{});
    trace.info("Rendering XML to ASCII");
    trace.fields("render-params", .{
        .width = width,
        .height = height,
    });

    var layout_engine = layout.init(al, &unicode, &trace);
    try layout_engine.computeFlexLayout(
        &tree,
        document,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = width, .h = height },
    );

    var r = try tty.Raster.init(al, width, height);
    defer r.deinit(al);
    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();
    var ctx = paint.PaintContext.init(al, &unicode, &trace);
    defer ctx.deinit();
    try paint.computePaintCommands(&ctx, document, &tree, glyphs);

    // Paint commands are now logged via the tracing system

    try tty.rasterizeDisplayList(&r, al, glyphs, &ctx);
    return try r.toStringAlloc(al, glyphs);
}

pub fn renderDocumentToWriter(
    al: std.mem.Allocator,
    document: *const Dom,
    writer: anytype,
    width: usize,
    height: usize,
) !void {
    var r = try tty.Raster.init(al, width, height);
    defer r.deinit(al);
    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();
    var unicode = try paint.UnicodeData.init(al);
    defer unicode.deinit(al);
    var trace = Trace.file(std.io.getStdErr(), .{});
    trace.info("Rendering DOM");
    trace.fields("render-params", .{
        .width = width,
        .height = height,
    });
    var ctx = paint.PaintContext.init(al, &unicode, &trace);
    defer ctx.deinit();
    var tree = try allocateBoxTreeFromDOMAutoRoot(al, document);
    defer tree.deinit();

    // Compute layout
    var layout_engine = layout.init(al, &unicode, &trace);
    const root_node = tree.getNodeMut(0);
    try layout_engine.computeFlexLayout(
        &tree,
        document,
        root_node,
        .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) },
    );

    try paint.computePaintCommands(&ctx, document, &tree, &glyphs);
    try tty.rasterizeDisplayList(&r, al, &glyphs, &ctx);
    try r.writeAnsiToWriter(writer, &glyphs);
}

fn expectXmlAscii(xml_input: []const u8, width: usize, height: usize, want: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();
    const got = try renderXmlAscii(al, xml_input, width, height);
    defer al.free(got);
    try expectAsciiEqual(want, got);
}

fn expectLayout(xml_input: []const u8, want: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();
    const want_trim = std.mem.trim(u8, want, "\n");
    // Parse expected into rectangular lines and assert exact rectangle
    var want_lines = std.ArrayList([]const u8).init(al);
    defer want_lines.deinit();
    var itw = std.mem.splitScalar(u8, want_trim, '\n');
    while (itw.next()) |line| {
        try want_lines.append(line);
    }
    try std.testing.expect(want_lines.items.len > 0);
    const width: usize = want_lines.items[0].len;
    var i: usize = 0;
    while (i < want_lines.items.len) : (i += 1) {
        try std.testing.expectEqual(@as(usize, width), want_lines.items[i].len);
    }
    const height: usize = want_lines.items.len;

    const got = try renderXmlAscii(al, xml_input, width, height);
    defer al.free(got);
    const got_trim = std.mem.trim(u8, got, "\n");
    var got_lines = std.ArrayList([]const u8).init(al);
    defer got_lines.deinit();
    var itg = std.mem.splitScalar(u8, got_trim, '\n');
    while (itg.next()) |line| try got_lines.append(line);
    try std.testing.expectEqual(@as(usize, height), got_lines.items.len);
    var j: usize = 0;
    while (j < got_lines.items.len) : (j += 1) {
        try std.testing.expectEqual(@as(usize, width), got_lines.items[j].len);
    }

    if (std.mem.eql(u8, want_trim, got_trim)) return;

    var nest = TreeNest.testNest(al);
    defer nest.deinit();
    var dk = nest.dk();

    try dk.errorMsg("Rendered document violated expectations.");
    try dk.info("Document source:");
    try dk.sourceBlock(xml_input, null, null, 0);
    try dk.info("Expected:");
    try dk.sourceBlock(want_trim, null, null, 0);
    try dk.info("Actual:");
    try dk.sourceBlock(got_trim, null, null, 0);

    return error.UnexpectedRendering;
}

test "flex row with justify-start places two boxes at the beginning of the container" {
    try expectLayout(
        \\<?xml version="1.0" standalone="yes" ?>
        \\<root class="flex flex-row bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
    );
}

test "flex row with items-stretch makes children fill the container's cross axis" {
    try expectLayout(
        \\<?xml version="1.0" standalone="yes" ?>
        \\<root class="h-5 bg-glyph-[.]">
        \\  <box class="h-3 flex flex-row items-stretch">
        \\    <box class="w-4 bg-glyph-[a]" />
        \\    <box class="w-4 bg-glyph-[b]" />
        \\  </box>
        \\</root>
    ,
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
    );
}

test "flex row with justify-center centers boxes horizontally in the container" {
    try expectLayout(
        \\<root class="flex flex-row justify-center bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\
    );
}

test "flex row with justify-between places first and last items at container edges" {
    try expectLayout(
        \\<root class="flex flex-row justify-between bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\
    );
}

test "flex-grow distributes available space proportionally among growing children" {
    try expectLayout(
        \\<root class="flex flex-row bg-glyph-[.]">
        \\  <box class="w-2 h-2 grow-1 bg-glyph-[a]" />
        \\  <box class="w-2 h-2 grow-2 bg-glyph-[b]" />
        \\  <box class="w-2 h-2 grow-1 bg-glyph-[c]" />
        \\</root>
    ,
        \\aaaabbbbbccc
        \\aaaabbbbbccc
        \\aaaabbbbbccc
        \\aaaabbbbbccc
        \\
    );
}

test "flex row with justify-around creates equal space around each item" {
    try expectLayout(
        \\<root class="flex flex-row justify-around bg-glyph-[.]">
        \\  <box class="w-2 h-2 bg-glyph-[a]" />
        \\  <box class="w-2 h-2 bg-glyph-[b]" />
        \\  <box class="w-2 h-2 bg-glyph-[c]" />
        \\</root>
    ,
        \\.aa..bb..cc.
        \\.aa..bb..cc.
        \\.aa..bb..cc.
        \\.aa..bb..cc.
        \\
    );
}

test "align-self property overrides the container's align-items for individual children" {
    try expectLayout(
        \\<root class="flex flex-row items-start bg-glyph-[.] h-4">
        \\  <box class="w-4 h-2 self-center bg-glyph-[a]" />
        \\  <box class="w-4 h-2 bg-glyph-[b]" />
        \\</root>
    ,
        \\....bbbb....
        \\aaaabbbb....
        \\aaaa........
        \\............
        \\
    );
}

test "flex column with single growing child fills entire container height" {
    try expectLayout(
        \\<root class="flex flex-col bg-glyph-[.] h-16">
        \\  <box class="w-4 grow-1 bg-glyph-[a]" />
        \\</root>
    ,
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
    );
}

test "flex column with one growing and one fixed child distributes space correctly" {
    try expectLayout(
        \\<root class="flex flex-col bg-glyph-[.] h-16">
        \\  <box class="w-4 grow-1 bg-glyph-[a]" />
        \\  <box class="w-4 h-1 bg-glyph-[b]" />
        \\</root>
    ,
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\bbbb
    );
}

test "flex column with items-center aligns children horizontally while growing vertically" {
    try expectLayout(
        \\<root class="flex flex-col items-center bg-glyph-[.] w-8 h-16">
        \\  <box class="w-4 grow-1 bg-glyph-[a]" />
        \\  <box class="w-4 h-1 bg-glyph-[b]" />
        \\</root>
    ,
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..bbbb..
    );
}

test "text nodes render inside flex containers and respect their layout properties" {
    try expectLayout(
        \\<root class="flex flex-col bg-glyph-[.] h-4">
        \\  <box class="w-3 grow-1 bg-glyph-[a]">foo</box>
        \\  <box class="w-3 grow-1 bg-glyph-[b]">bar</box>
        \\</root>
    ,
        \\fooa
        \\aaaa
        \\barb
        \\bbbb
    );
}

test "text nodes containing newline characters render on multiple lines" {
    try expectLayout(
        \\<root class="w-5 h-5 bg-glyph-[.]">Line1
        \\Line2
        \\Line3</root>
    ,
        \\Line1
        \\Line2
        \\Line3
        \\.....
        \\.....
    );
}

test "overflow-y-scroll containers automatically scroll to show bottom content" {
    try expectLayout(
        \\<root class="flex flex-col w-6 h-5 bg-glyph-[.]">
        \\  <box class="h-1 w-6 bg-glyph-[.]"></box>
        \\  <box class="flex flex-col overflow-y-scroll h-4 w-6">
        \\    <box class="h-2 w-6 bg-glyph-[a]"></box>
        \\    <box class="h-2 w-6 bg-glyph-[b]"></box>
        \\    <box class="h-2 w-6 bg-glyph-[c]"></box>
        \\  </box>
        \\</root>
    ,
        \\......
        \\bbbbbb
        \\bbbbbb
        \\cccccc
        \\cccccc
    );
}
