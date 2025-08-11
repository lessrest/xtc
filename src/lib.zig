pub usingnamespace @import("style.zig");
pub usingnamespace @import("layout.zig");
pub usingnamespace @import("dom.zig");
pub usingnamespace @import("tailwind.zig");
pub usingnamespace @import("paint.zig");
pub usingnamespace @import("tty.zig");
pub usingnamespace @import("xml.zig");
pub usingnamespace @import("FormatTrace.zig");

comptime {
    _ = @import("test_wren_dom.zig");
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
pub const FormatTrace = @import("FormatTrace.zig");

pub const DisplayWidth = @import("DisplayWidth");
pub const Graphemes = @import("Graphemes");
pub const Words = @import("Words");

// pub const trealla = @import("trealla.zig"); // Replaced with Wren
pub const wren = @import("wren.zig");

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
        if (items.items(.parent)[i] == Dom.NullId and items.items(.kind)[i] == .element) {
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
    try std.testing.expectEqualStrings(want, got);
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

    var tree = try allocateBoxTreeFromDOMAutoRoot(al, &document);
    defer tree.deinit();

    var unicode = try paint.UnicodeData.init(al);
    defer unicode.deinit(al);

    // Initialize root tracer for the entire rendering pipeline
    const root_trace = Trace.init(true);
    const render_trace = root_trace.enter();
    defer render_trace.exit();
    render_trace.info("Rendering XML to ASCII");
    render_trace.data("render-params").put("width", width).put("height", height).end();

    var layout_engine = layout.init(al, &unicode, render_trace);
    try layout_engine.computeFlexLayout(
        &tree,
        &document,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = width, .h = height },
    );

    var r = try tty.Raster.init(al, width, height);
    defer r.deinit(al);
    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();
    var ctx = paint.PaintContext.init(al, &unicode, render_trace);
    defer ctx.deinit();
    try paint.computePaintCommands(&ctx, &document, &tree, &glyphs);

    // Paint commands are now logged via the tracing system

    try tty.rasterizeDisplayList(&r, al, &glyphs, &ctx);
    return try r.toStringAlloc(al, &glyphs);
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
    const root_trace = Trace.init(true);
    const render_trace = root_trace.enter();
    defer render_trace.exit();
    render_trace.info("Rendering DOM");
    render_trace.data("render-params").put("width", width).put("height", height).end();
    var ctx = paint.PaintContext.init(al, &unicode, render_trace);
    defer ctx.deinit();
    var tree = try allocateBoxTreeFromDOMAutoRoot(al, document);
    defer tree.deinit();

    // Compute layout
    var layout_engine = layout.init(al, &unicode, render_trace);
    const root_node = tree.getNodeMut(0);
    try layout_engine.computeFlexLayout(
        &tree,
        document,
        root_node,
        .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) },
    );

    try paint.computePaintCommands(&ctx, document, &tree, &glyphs);
    try tty.rasterizeDisplayList(&r, al, &glyphs, &ctx);
    try r.writeToWriter(writer, &glyphs);
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
    try expectAsciiEqual(want_trim, got_trim);
}

test "row start: two 4x3 tiles in 14x5 viewport" {
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
        \\...............
        \\...............
    );
}

test "flex row with stretch" {
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
        \\...............
        \\...............
    );
}

test "row center: centered 4x3 + 4x3 tiles in 14x5" {
    try expectLayout(
        \\<root class="flex flex-row justify-center bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\..............
        \\..............
        \\
    );
}

test "row space-between: separated 4x3 tiles in 14x5" {
    try expectLayout(
        \\<root class="flex flex-row justify-between bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\..............
        \\..............
        \\
    );
}

test "grow distribution: three tiles grow to fill main axis" {
    try expectLayout(
        \\<root class="flex flex-row bg-glyph-[.]">
        \\  <box class="w-2 h-2 grow-1 bg-glyph-[a]" />
        \\  <box class="w-2 h-2 grow-2 bg-glyph-[b]" />
        \\  <box class="w-2 h-2 grow-1 bg-glyph-[c]" />
        \\</root>
    ,
        \\aaaabbbbbccc
        \\aaaabbbbbccc
        \\............
        \\............
        \\
    );
}

test "justify-around: equal around gaps across three tiles" {
    try expectLayout(
        \\<root class="flex flex-row justify-around bg-glyph-[.]">
        \\  <box class="w-2 h-2 bg-glyph-[a]" />
        \\  <box class="w-2 h-2 bg-glyph-[b]" />
        \\  <box class="w-2 h-2 bg-glyph-[c]" />
        \\</root>
    ,
        \\.aa..bb..cc.
        \\.aa..bb..cc.
        \\............
        \\............
        \\
    );
}

test "align-self overrides align-items (center vs start)" {
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

test "column grow distribution: one tile grows to fill main axis" {
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

test "column grow distribution: *only* one tile grows to fill main axis" {
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

test "column grow distribution: only one tile grows to fill main axis, centered" {
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

test "flex with texts" {
    try expectLayout(
        \\<root class="flex flex-col bg-glyph-[.] h-4">
        \\  <box class="w-3 grow-1 bg-glyph-[a]">foo</box>
        \\  <box class="w-3 grow-1 bg-glyph-[b]">bar</box>
        \\</root>
    ,
        \\foo.
        \\aaa.
        \\bar.
        \\bbb.
    );
}

test "text with newlines" {
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

test "overflow-y-scroll with auto-scroll to bottom" {
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
