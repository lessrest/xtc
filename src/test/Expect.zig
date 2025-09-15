const std = @import("std");
const miniflex = @import("../miniflex.zig");
const layout = miniflex.layout;
const Painter = miniflex.Painter;
const xml = @import("../xml.zig");
const xmlparse = @import("../xmlparse.zig");
const TreeNest = @import("ansi").nest;
const Dom = miniflex.Dom;
const BoxTree = miniflex.BoxTree;
const DomNodeId = miniflex.DomNodeId;
const Raster = miniflex.Raster;
const GlyphTable = miniflex.GlyphTable;
const GlyphId = GlyphTable.GlyphId;
const UnicodeData = miniflex.UnicodeData;

/// Helper for tests: pick the first top-level element as root and build a BoxTree.
pub fn makeDocumentBoxTree(
    alloc: std.mem.Allocator,
    document: *const Dom,
) !BoxTree {
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

pub fn expectAsciiEqual(want: []const u8, got: []const u8) !void {
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

pub fn renderMarkupToText(
    al: std.mem.Allocator,
    xml_input: []const u8,
    width: usize,
    height: usize,
) ![]u8 {
    var trace = TreeNest.silent(al);
    trace.info("Rendering XML to ASCII");
    trace.fields("render-params", .{
        .width = width,
        .height = height,
    });

    var unicode = try UnicodeData.init(al);
    defer unicode.deinit(al);

    var r = try Raster.init(al, width, height);
    defer r.deinit(al);

    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();

    var painter = Painter.init(al, &unicode, &trace);
    defer painter.deinit();

    var fbs = std.io.fixedBufferStream(xml_input);
    var xdoc = try xmlparse.parse(al, "<stdin>", fbs.reader());
    defer xdoc.deinit();

    var document = try xml.loadDocumentFromMarkup(al, &xdoc);
    defer document.deinit();

    var tree = try makeDocumentBoxTree(al, document);
    defer tree.deinit();

    var layout_engine = layout.init(al, &unicode, &trace);
    try layout_engine.layoutSubtree(
        &tree,
        document,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = width, .h = height },
    );

    try painter.computePaintCommands(document, &tree, glyphs);
    try r.rasterizeDisplayList(al, glyphs, &painter);

    return try r.plainTextDump(al, glyphs);
}

pub fn layoutExample(xml_input: []const u8, want: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const want_trim = std.mem.trim(u8, want, "\n");
    var want_lines = std.ArrayList([]const u8){};
    var itw = std.mem.splitScalar(u8, want_trim, '\n');
    while (itw.next()) |line| {
        try want_lines.append(al, line);
    }

    try std.testing.expect(want_lines.items.len > 0);

    const width: usize = want_lines.items[0].len;

    var i: usize = 0;
    while (i < want_lines.items.len) : (i += 1) {
        try std.testing.expectEqual(@as(usize, width), want_lines.items[i].len);
    }

    const height: usize = want_lines.items.len;

    const got = try renderMarkupToText(al, xml_input, width, height);
    const got_trim = std.mem.trim(u8, got, "\n");
    var got_lines = std.ArrayList([]const u8){};
    var itg = std.mem.splitScalar(u8, got_trim, '\n');
    while (itg.next()) |line| try got_lines.append(al, line);

    try std.testing.expectEqual(@as(usize, height), got_lines.items.len);

    var j: usize = 0;
    while (j < got_lines.items.len) : (j += 1) {
        try std.testing.expectEqual(@as(usize, width), got_lines.items[j].len);
    }

    if (std.mem.eql(u8, want_trim, got_trim)) return;

    var nest = TreeNest.stderr(al);
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
