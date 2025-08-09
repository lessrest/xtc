const std = @import("std");
const xml = @import("xml");
const lib = @import("lib.zig");
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const args = try std.process.argsAlloc(al);
    if (args.len < 2) {
        try std.io.getStdErr().writer().print("usage: xtc <file.xml> [--debug-boxes]\n", .{});
        std.process.exit(2);
    }
    const path = args[1];
    const debug_boxes = blk: {
        var db = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--debug-boxes")) db = true;
        }
        break :blk db;
    };

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var xdoc = try xml.parse(al, path, file.reader());
    defer xdoc.deinit();

    const xd = try lib.domFromXmlAlloc(al, &xdoc);
    var dom = xd.dom;
    defer dom.deinit();

    // Build tree and layout
    var tree = try lib.buildBoxTreeFromDomAlloc(al, &dom, xd.root);
    defer tree.deinit();

    var provider = lib.StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    // For now, size to a reasonable default terminal viewport
    const width: usize = 80;
    const height: usize = 24;
    try lib.layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = 0, .y = 0, .w = width, .h = height }, provider);

    if (debug_boxes) {
        try lib.dumpBoxTree(al, std.io.getStdOut().writer(), &tree, &dom);
        return;
    }

    // Build display list and rasterize
    var dl = lib.DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try lib.GlyphTable.init(al);
    defer glyphs.deinit();
    try lib.buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
    var r = try lib.Raster.init(al, width, height);
    defer r.deinit(al);
    try lib.rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const out = try r.toStringAlloc(al);
    defer al.free(out);
    try std.io.getStdOut().writer().print("{s}", .{out});
}
