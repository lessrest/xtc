const std = @import("std");
const BoxTree = @import("lib.zig").BoxTree;
const Dom = @import("dom.zig").Dom;
const Layout = @import("lib.zig").Layout;
const Rect = @import("lib.zig").Rect;
const StyleAlign = @import("lib.zig").StyleAlign;
const BoxSize = @import("lib.zig").BoxSize;
const CrossAxisAlignment = @import("lib.zig").CrossAxisAlignment;
const _Alignment = @import("lib.zig")._Alignment;
const layoutFromStyleRow = @import("lib.zig").layoutFromStyleRow;
const styleAlignToCross = @import("lib.zig").styleAlignToCross;
const calculateSpaces = @import("lib.zig").calculateSpaces;
const GlyphTable = @import("lib.zig").GlyphTable;
const DomNodeId = @import("dom.zig").DomNodeId;
const Graphemes = @import("lib.zig").Graphemes;
const DisplayWidth = @import("lib.zig").DisplayWidth;
const Words = @import("lib.zig").Words;
const GlyphId = @import("lib.zig").GlyphId;
const Raster = @import("lib.zig").Raster;
const expectAsciiEqual = @import("lib.zig").expectAsciiEqual;
const buildBoxTreeFromDomAlloc = @import("lib.zig").buildBoxTreeFromDomAlloc;
const layoutBoxesInPlace = @import("layout.zig").layoutBoxesInPlace;
const StyleProvider = @import("lib.zig").StyleProvider;
const parseUtilityClassList = @import("tailwind.zig").parseUtilityClassList;
const get_fg_rgb = @import("tailwind.zig").get_fg_rgb;
const rasterizeDisplayListAscii = @import("lib.zig").rasterizeDisplayListAscii;

// --- Paint stage: device-independent display list ---

pub const Rgba8 = struct { r: u8, g: u8, b: u8, a: u8 };

fn mul255(x: u32, y: u32) u8 {
    // (x*y)/255 with rounding, inputs 0..255
    const prod: u32 = x * y + 127;
    return @intCast((prod + (prod >> 8)) >> 8);
}

pub fn blendOver(dst: *Rgba8, src: Rgba8) void {
    // Porter-Duff SrcOver for straight (non-premultiplied) 8-bit RGBA
    const as: u8 = src.a;
    const ad: u8 = dst.a;
    const one_minus_as: u8 = 255 - as;
    const out_a: u8 = as + mul255(ad, one_minus_as);
    if (out_a == 0) {
        dst.* = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return;
    }
    // Premultiplied channel blend
    const dst_scale: u8 = mul255(ad, one_minus_as);
    const cp_r: u16 = @as(u16, mul255(src.r, as)) + @as(u16, mul255(dst.r, dst_scale));
    const cp_g: u16 = @as(u16, mul255(src.g, as)) + @as(u16, mul255(dst.g, dst_scale));
    const cp_b: u16 = @as(u16, mul255(src.b, as)) + @as(u16, mul255(dst.b, dst_scale));
    // Un-premultiply
    const oa: u16 = out_a;
    dst.r = @intCast((cp_r * 255 + oa / 2) / oa);
    dst.g = @intCast((cp_g * 255 + oa / 2) / oa);
    dst.b = @intCast((cp_b * 255 + oa / 2) / oa);
    dst.a = out_a;
}

pub const PaintBorderStyle = enum { ascii, unicode };

pub const PaintOpTag = enum { FillRect, StrokeRect, GlyphRun, FillGlyphRect };
pub const PaintOp = union(PaintOpTag) {
    FillRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8 },
    StrokeRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8, style: PaintBorderStyle },
    GlyphRun: struct { x: usize, y: usize, glyphs: []const GlyphId, color: Rgba8 },
    // Test-friendly fill: tile a rectangle with a single glyph id (e.g. '.' or 'a')
    FillGlyphRect: struct { x: usize, y: usize, w: usize, h: usize, glyph: GlyphId },
};

pub const PaintCommandBatch = struct {
    ops: std.ArrayList(PaintOp),
    pub fn init(alloc: std.mem.Allocator) PaintCommandBatch {
        return .{ .ops = std.ArrayList(PaintOp).init(alloc) };
    }
    pub fn deinit(self: *PaintCommandBatch) void {
        self.ops.deinit();
        self.* = undefined;
    }
    pub fn push(self: *PaintCommandBatch, op: PaintOp) !void {
        try self.ops.append(op);
    }
};
pub fn computePaintCommands(list: *PaintCommandBatch, dom: *const Dom, tree: *const BoxTree, glyphs: *GlyphTable) !void {
    // Resolve inherited fg/bg along DOM ancestry (nearest ancestor wins)
    const resolveEffectiveFgBg = struct {
        fn go(d: *const Dom, node_id: DomNodeId) struct { fg: ?Rgba8, bg: ?Rgba8 } {
            var items = d.headers.slice();
            var cur: DomNodeId = node_id;
            var eff_fg: ?Rgba8 = null;
            var eff_bg: ?Rgba8 = null;
            while (true) {
                const sid = items.items(.style_id)[@as(usize, @intCast(cur))];
                const row = d.styles.cols.items[@intCast(sid)];
                if (eff_fg == null and row.fg.use_default == 0) {
                    eff_fg = .{ .r = row.fg.r, .g = row.fg.g, .b = row.fg.b, .a = 255 };
                }
                if (eff_bg == null and row.bg.use_default == 0) {
                    eff_bg = .{ .r = row.bg.r, .g = row.bg.g, .b = row.bg.b, .a = 255 };
                }
                const p = items.items(.parent)[@as(usize, @intCast(cur))];
                if (p == Dom.NullId) break;
                cur = p;
            }
            return .{ .fg = eff_fg, .bg = eff_bg };
        }
    }.go;
    const items = dom.headers.slice();
    var g = try Graphemes.init(list.ops.allocator);
    defer g.deinit(list.ops.allocator);
    var dw = try DisplayWidth.init(list.ops.allocator);
    defer dw.deinit(list.ops.allocator);
    var i: usize = 0;
    while (i < tree.headers.items.len) : (i += 1) {
        const h = tree.headers.items[i];
        // Skip drawing the root box; outer frame (terminal viewport) is handled by caller
        if (i == tree.root_index) continue;
        const sid = items.items(.style_id)[@as(usize, @intCast(h.dom_id))];
        const row = dom.styles.cols.items[@intCast(sid)];
        // Background fill (ignored in ASCII raster for now)
        if (row.bg.use_default == 0 and h.rect.w > 0 and h.rect.h > 0) {
            try list.push(PaintOp{ .FillRect = .{ .x = h.rect.x, .y = h.rect.y, .w = h.rect.w, .h = h.rect.h, .color = .{ .r = row.bg.r, .g = row.bg.g, .b = row.bg.b, .a = 255 } } });
        }
        // Border stroke (draw when width_cells > 0)
        if (row.border.width_cells > 0 and h.rect.w > 0 and h.rect.h > 0) {
            try list.push(PaintOp{ .StrokeRect = .{ .x = h.rect.x, .y = h.rect.y, .w = h.rect.w, .h = h.rect.h, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .style = .ascii } });
        }
        // Text nodes: emit grapheme-cluster glyph run with word-wrapped lines
        const kind = items.items(.kind)[@as(usize, @intCast(h.dom_id))];
        if (kind == .text and h.rect.w > 0 and h.rect.h > 0) {
            const slice = dom.getTextSlice(h.dom_id);
            // Compute content area from style.
            // We reserve a 1-cell inset only when a border is drawn for this node.
            const border_w: usize = @as(usize, @intCast(row.border.width_cells));
            const pad_l: usize = @as(usize, @intCast(row.padding.l));
            const pad_r: usize = @as(usize, @intCast(row.padding.r));
            const pad_t: usize = @as(usize, @intCast(row.padding.t));
            const pad_b: usize = @as(usize, @intCast(row.padding.b));
            const base_inset: usize = if (border_w > 0) 1 else 0;
            const inset_left = base_inset + pad_l;
            const inset_right = base_inset + pad_r;
            const inset_top = base_inset + pad_t;
            const inset_bottom = base_inset + pad_b;
            const content_w: usize = if (h.rect.w > inset_left + inset_right)
                h.rect.w - (inset_left + inset_right)
            else
                0;
            const content_h: usize = if (h.rect.h > inset_top + inset_bottom)
                h.rect.h - (inset_top + inset_bottom)
            else
                0;

            var y_offset: usize = 0;
            var line_start: usize = 0;
            var line_width: usize = 0;
            var last_break_bytes: ?usize = null;
            var word_iter = Words.init(list.ops.allocator) catch unreachable; // simple lifetime; deinit at end
            defer word_iter.deinit(list.ops.allocator);
            var witer = word_iter.iterator(slice);
            while (witer.next()) |seg| {
                const bytes = seg.bytes(slice);
                const seg_w = dw.strWidth(bytes);
                if (line_width + seg_w > content_w and line_width > 0) {
                    const line_bytes_end = last_break_bytes orelse seg.offset;
                    const line_bytes = slice[line_start..line_bytes_end];
                    // emit line
                    var gids = std.ArrayList(GlyphId).init(list.ops.allocator);
                    defer gids.deinit();
                    var it = g.iterator(line_bytes);
                    while (it.next()) |gc| {
                        const gb = gc.bytes(line_bytes);
                        const gid = try glyphs.intern(list.ops.allocator, gb);
                        try gids.append(gid);
                    }
                    if (gids.items.len > 0) {
                        const run = try list.ops.allocator.alloc(GlyphId, gids.items.len);
                        std.mem.copyForwards(GlyphId, run, gids.items);
                        const line_w_cols = dw.strWidth(line_bytes);
                        const extra = if (line_w_cols >= content_w) 0 else switch (row.justify) {
                            .start => 0,
                            .center => (content_w - line_w_cols) / 2,
                            .end => content_w - line_w_cols,
                            else => 0,
                        };
                        const eff = resolveEffectiveFgBg(dom, h.dom_id);
                        const base_fg: Rgba8 = eff.fg orelse .{ .r = 255, .g = 255, .b = 255, .a = 255 };
                        const base_bg: Rgba8 = eff.bg orelse .{ .r = 255, .g = 255, .b = 255, .a = 255 };
                        const fg: Rgba8 = if (row.text_flags.inverse == 1) base_bg else base_fg;
                        try list.push(PaintOp{ .GlyphRun = .{ .x = h.rect.x + inset_left + extra, .y = h.rect.y + inset_top + y_offset, .glyphs = run, .color = fg } });
                    }
                    // next line
                    y_offset += 1;
                    line_start = seg.offset;
                    line_width = seg_w;
                    last_break_bytes = seg.offset + seg.len;
                    continue;
                }
                line_width += seg_w;
                last_break_bytes = seg.offset + seg.len;
            }
            // flush last line
            if (line_start < slice.len and y_offset < content_h) {
                const line_bytes = slice[line_start..];
                var gids = std.ArrayList(GlyphId).init(list.ops.allocator);
                defer gids.deinit();
                var it2 = g.iterator(line_bytes);
                var w2: usize = 0;
                while (it2.next()) |gc| {
                    const gb = gc.bytes(line_bytes);
                    const w = dw.strWidth(gb);
                    if (w2 + w > content_w) break;
                    w2 += w;
                    const gid = try glyphs.intern(list.ops.allocator, gb);
                    try gids.append(gid);
                }
                if (gids.items.len > 0) {
                    const run = try list.ops.allocator.alloc(GlyphId, gids.items.len);
                    std.mem.copyForwards(GlyphId, run, gids.items);
                    const line_w_cols = dw.strWidth(line_bytes);
                    const extra = if (line_w_cols >= content_w) 0 else switch (row.justify) {
                        .start => 0,
                        .center => (content_w - line_w_cols) / 2,
                        .end => content_w - line_w_cols,
                        else => 0,
                    };
                    const eff2 = resolveEffectiveFgBg(dom, h.dom_id);
                    const base_fg2: Rgba8 = eff2.fg orelse .{ .r = 255, .g = 255, .b = 255, .a = 255 };
                    const base_bg2: Rgba8 = eff2.bg orelse .{ .r = 255, .g = 255, .b = 255, .a = 255 };
                    const fg2: Rgba8 = if (row.text_flags.inverse == 1) base_bg2 else base_fg2;
                    try list.push(PaintOp{ .GlyphRun = .{ .x = h.rect.x + inset_left + extra, .y = h.rect.y + inset_top + y_offset, .glyphs = run, .color = fg2 } });
                }
            }
        }
    }
}

test "alpha: simple SrcOver blend" {
    var dst = Rgba8{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const src = Rgba8{ .r = 255, .g = 0, .b = 0, .a = 128 };
    blendOver(&dst, src);
    // Expect purple-ish, full alpha
    try std.testing.expect(dst.r > 120 and dst.r < 140);
    try std.testing.expect(dst.b > 120 and dst.b < 140);
    try std.testing.expectEqual(@as(u8, 255), dst.a);
}

test "paint: stroke rect via display list (ascii)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    var r = try Raster.init(al, 10, 6);
    defer r.deinit(al);
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    try dl.push(PaintOp{ .StrokeRect = .{ .x = 2, .y = 1, .w = 6, .h = 4, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .style = .ascii } });
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        "          \n" ++
        "  +----+  \n" ++
        "  |    |  \n" ++
        "  |    |  \n" ++
        "  +----+  \n" ++
        "          \n";
    try expectAsciiEqual(want, got);
}

test "text color inheritance: parent element color applies to child text glyph run" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("text-blue-200");
    const txt = try dom.addText("A");
    dom.appendChild(root, txt);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();
    // Perform layout so text node gets a non-zero rect
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = 0, .y = 0, .w = 10, .h = 3 }, provider);
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);

    var found = false;
    var got: Rgba8 = undefined;
    for (dl.ops.items) |op| switch (op) {
        .GlyphRun => |gr| {
            got = gr.color;
            found = true;
            break;
        },
        else => {},
    };
    try std.testing.expect(found);

    const sr = parseUtilityClassList("text-blue-200");
    const rgb = get_fg_rgb(sr) orelse return error.TestExpectedFg;
    const want: Rgba8 = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
    try std.testing.expectEqual(want, got);
}
