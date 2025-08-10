pub usingnamespace @import("style.zig");
pub usingnamespace @import("layout.zig");
pub usingnamespace @import("dom.zig");

const std = @import("std");
const builtin = @import("builtin");

pub const DisplayWidth = @import("DisplayWidth");
pub const Graphemes = @import("Graphemes");
pub const Words = @import("Words");
pub const StyleRow = @import("style.zig").StyleRow;
pub const defaultStyleRow = @import("style.zig").defaultStyleRow;
pub const layoutFromStyleRow = @import("layout.zig").layoutFromStyleRow;
pub const styleAlignToCross = @import("style.zig").styleAlignToCross;
pub const parseUtilityClassList = @import("tailwind.zig").parseUtilityClassList;
pub const utilityTokensFromStyleRow = @import("tailwind.zig").utilityTokensFromStyleRow;
pub const StyleTable = @import("style.zig").StyleTable;
pub const StyleDisplay = @import("style.zig").StyleDisplay;
pub const trealla = @import("trealla.zig");
pub const PaintCommandBatch = @import("paint.zig").PaintCommandBatch;
pub const drawBorderAscii = @import("tty.zig").drawBorderAscii;
pub const rasterizeDisplayList = @import("tty.zig").rasterizeDisplayList;
pub const Rgba8 = @import("paint.zig").Rgba8;
pub const GlyphTable = @import("tty.zig").GlyphTable;
pub const GlyphId = @import("tty.zig").GlyphId;
pub const Raster = @import("tty.zig").Raster;

const DomNodeId = @import("dom.zig").DomNodeId;
const Rect = @import("layout.zig").Rect;
const BoxNode = @import("dom.zig").BoxNode;
const Dom = @import("dom.zig").Dom;
const BoxTree = @import("layout.zig").BoxTree;
pub const calculateSpaces = @import("layout.zig").calculateSpaces;
pub const loadDocumentFromMarkup = @import("xml.zig").loadDocumentFromMarkup;
pub const allocateBoxTreeFromDOM = @import("layout.zig").allocateBoxTreeFromDOM;

/// Helper for tests: pick the first top-level element as root and build a BoxTree.
pub fn allocateBoxTreeFromDOMAutoRoot(alloc: std.mem.Allocator, dom: *const Dom) !BoxTree {
    const items = dom.headers.slice();
    var i: usize = 0;
    while (i < dom.headers.len) : (i += 1) {
        if (items.items(.parent)[i] == Dom.NullId and items.items(.kind)[i] == .element) {
            const root: DomNodeId = @intCast(i);
            return try allocateBoxTreeFromDOM(alloc, dom, root);
        }
    }
    // Fallback: empty tree with root 0 if no element found
    return allocateBoxTreeFromDOM(alloc, dom, 0);
}
pub const layoutBoxesInPlace = @import("layout.zig").layoutBoxesInPlace;
pub const computePaintCommands = @import("paint.zig").computePaintCommands;

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
    const xml = @import("xmlparse.zig");
    var fbs = std.io.fixedBufferStream(xml_input);
    var xdoc = try xml.parse(al, "<stdin>", fbs.reader());
    defer xdoc.deinit();

    var dom = try loadDocumentFromMarkup(al, &xdoc);
    defer dom.deinit();

    var tree = try allocateBoxTreeFromDOMAutoRoot(al, &dom);
    defer tree.deinit();

    var dw = try DisplayWidth.init(al);
    defer dw.deinit(al);

    try layoutBoxesInPlace(
        al,
        &tree,
        &dom,
        0,
        .{ .x = 0, .y = 0, .w = width, .h = height },
        &dw,
    );

    var r = try Raster.init(al, width, height);
    defer r.deinit(al);
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayList(&r, al, &glyphs, &dl);
    return try r.toStringAlloc(al, &glyphs);
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
