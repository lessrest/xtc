const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");
const Words = @import("Words");
const tailwind = @import("tailwind.zig");
const tty = @import("tty.zig");
const StyleRow = @import("style.zig").StyleRow;
const BorderStyle = @import("style.zig").BorderStyle;
const StyleJustify = @import("style.zig").StyleJustify;

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

pub const PaintBorderStyle = enum { line_light, line_double, line_heavy, line_dashed };

pub const PaintOpTag = enum { FillRect, StrokeRect, GlyphRun, FillGlyphRect };
pub const PaintOp = union(PaintOpTag) {
    FillRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8 },
    StrokeRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8, style: PaintBorderStyle, bg_color: ?Rgba8 = null },
    GlyphRun: struct { x: usize, y: usize, glyphs: []const tty.GlyphId, color: Rgba8 },
    FillGlyphRect: struct { x: usize, y: usize, w: usize, h: usize, glyph: tty.GlyphId, color: Rgba8 },
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

// No global rendering toggles here; the TTY backend chooses glyphs and fallbacks.
/// Resolve effective foreground/background color along DOM ancestry, per CSS color inheritance.
/// Nearest ancestor with an explicit value wins; returns null when no explicit color was found.
fn resolveEffectiveFgBg(dref: *const dom.Dom, node_id: dom.DomNodeId) struct { fg: ?Rgba8, bg: ?Rgba8 } {
    var items = dref.headers.slice();
    var cur: dom.DomNodeId = node_id;
    var eff_fg: ?Rgba8 = null;
    var eff_bg: ?Rgba8 = null;
    while (true) {
        const sid = items.items(.style_id)[@as(usize, @intCast(cur))];
        const row = dref.styles.cols.items[@intCast(sid)];
        if (eff_fg == null and row.fg.use_default == 0) {
            eff_fg = .{ .r = row.fg.r, .g = row.fg.g, .b = row.fg.b, .a = 255 };
        }
        if (eff_bg == null and row.bg.use_default == 0) {
            eff_bg = .{ .r = row.bg.r, .g = row.bg.g, .b = row.bg.b, .a = 255 };
        }
        const p = items.items(.parent)[@as(usize, @intCast(cur))];
        if (p == dom.Dom.NullId) break;
        cur = p;
    }
    return .{ .fg = eff_fg, .bg = eff_bg };
}

/// Helper: emit a uniform glyph tile fill across the box rect (testing/demo aid).
fn emitGlyphTileFill(list: *PaintCommandBatch, glyphs: *tty.GlyphTable, rect: layout.Rect, row: StyleRow) !void {
    if (!(row.fill_glyph != 0 and rect.w > 0 and rect.h > 0)) return;
    const gid: tty.GlyphId = if (row.fill_glyph <= 0xFF)
        @intCast(row.fill_glyph)
    else blk: {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(row.fill_glyph), &tmp) catch 0;
        break :blk if (n == 0) @as(tty.GlyphId, 32) else try glyphs.intern(list.ops.allocator, tmp[0..n]);
    };
    try list.push(PaintOp{ .FillGlyphRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .glyph = gid, .color = .{ .r = row.fg.r, .g = row.fg.g, .b = row.fg.b, .a = 255 } } });
}

/// Helper: background painting step per CSS painting order (backgrounds behind borders and content).
fn emitBackgroundFillIfAny(list: *PaintCommandBatch, rect: layout.Rect, row: StyleRow) !void {
    if (row.bg.use_default == 0 and rect.w > 0 and rect.h > 0) {
        try list.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = .{ .r = row.bg.r, .g = row.bg.g, .b = row.bg.b, .a = 255 } } });
    }
}

/// Helper: border painting step. Color falls back to border_color, then fg, then white.
fn emitBorderBlock(list: *PaintCommandBatch, rect: layout.Rect, color: Rgba8, thickness: usize) !void {
    if (rect.w == 0 or rect.h == 0 or thickness == 0) return;
    const t = @min(thickness, @min(rect.w, rect.h));
    // Top band
    try list.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t, .color = color } });
    // Bottom band
    if (rect.h > t) {
        try list.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t, .color = color } });
    }
    // Side bands (avoid double-filling corners if height <= 2*t, harmless otherwise)
    const inner_h = if (rect.h > 2 * t) rect.h - 2 * t else 0;
    if (inner_h > 0) {
        try list.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
        if (rect.w > t) {
            try list.push(PaintOp{ .FillRect = .{ .x = rect.x + rect.w - t, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
        }
    }
}

fn emitBorderStrokeIfAny(list: *PaintCommandBatch, rect: layout.Rect, row: StyleRow) !void {
    if (!(row.border.width > 0 and rect.w > 0 and rect.h > 0)) return;
    const col: Rgba8 = blk: {
        if (row.border_color.use_default == 0) break :blk .{ .r = row.border_color.r, .g = row.border_color.g, .b = row.border_color.b, .a = 255 };
        if (row.fg.use_default == 0) break :blk .{ .r = row.fg.r, .g = row.fg.g, .b = row.fg.b, .a = 255 };
        break :blk .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    };
    const bg_for_border: ?Rgba8 = if (row.bg.use_default == 0)
        .{ .r = row.bg.r, .g = row.bg.g, .b = row.bg.b, .a = 255 }
    else
        null;
    switch (row.border.style) {
        .block => try emitBorderBlock(list, rect, col, row.border.width),
        .solid => try list.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_light, .bg_color = bg_for_border } }),
        .double => try list.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_double, .bg_color = bg_for_border } }),
        .dashed => try list.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_dashed, .bg_color = bg_for_border } }),
        .none => {},
    }
}

/// Helper: compute text content box (padding + 1-cell inset if border present) and emit wrapped glyph runs.
const ContentBox = struct {
    rect: layout.Rect,
    inset_left: usize,
    inset_top: usize,
};

fn computeContentBox(rect: layout.Rect, row: StyleRow) ContentBox {
    const border_w: usize = @as(usize, @intCast(row.border.width));
    const pad_l: usize = @as(usize, @intCast(row.padding.l));
    const pad_r: usize = @as(usize, @intCast(row.padding.r));
    const pad_t: usize = @as(usize, @intCast(row.padding.t));
    const pad_b: usize = @as(usize, @intCast(row.padding.b));
    const base_inset: usize = if (border_w > 0) 1 else 0;
    const inset_left = base_inset + pad_l;
    const inset_right = base_inset + pad_r;
    const inset_top = base_inset + pad_t;
    const inset_bottom = base_inset + pad_b;
    const content_w: usize = if (rect.w > inset_left + inset_right) rect.w - (inset_left + inset_right) else 0;
    const content_h: usize = if (rect.h > inset_top + inset_bottom) rect.h - (inset_top + inset_bottom) else 0;
    return .{
        .rect = .{ .x = rect.x, .y = rect.y, .w = content_w, .h = content_h },
        .inset_left = inset_left,
        .inset_top = inset_top,
    };
}

fn computeTextColor(document: *const dom.Dom, node_id: dom.DomNodeId, row: StyleRow) Rgba8 {
    const eff = resolveEffectiveFgBg(document, node_id);
    const base_fg: Rgba8 = eff.fg orelse .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const base_bg: Rgba8 = eff.bg orelse .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    return if (row.text_flags.inverse == 1) base_bg else base_fg;
}

fn computeJustifyOffset(content_w: usize, line_w_cols: usize, justify: StyleJustify) usize {
    if (line_w_cols >= content_w) return 0;
    return switch (justify) {
        .start => 0,
        .center => (content_w - line_w_cols) / 2,
        .end => content_w - line_w_cols,
        else => 0,
    };
}

fn buildGlyphRun(
    allocator: std.mem.Allocator,
    g: *Graphemes,
    dw: *DisplayWidth,
    glyphs: *tty.GlyphTable,
    bytes: []const u8,
    content_w: usize,
    truncate_to_fit: bool,
) !struct { run: []tty.GlyphId, width_cols: usize } {
    var gids = std.ArrayList(tty.GlyphId).init(allocator);
    defer gids.deinit();
    var it = g.iterator(bytes);
    var acc_w: usize = 0;
    while (it.next()) |gc| {
        const gb = gc.bytes(bytes);
        const w = dw.strWidth(gb);
        if (truncate_to_fit and acc_w + w > content_w) break;
        acc_w += w;
        const gid = try glyphs.intern(allocator, gb);
        try gids.append(gid);
    }
    if (gids.items.len == 0) return .{ .run = &[_]tty.GlyphId{}, .width_cols = 0 };
    const run = try allocator.alloc(tty.GlyphId, gids.items.len);
    std.mem.copyForwards(tty.GlyphId, run, gids.items);
    const width_cols: usize = if (truncate_to_fit) acc_w else dw.strWidth(bytes);
    return .{ .run = run, .width_cols = width_cols };
}

fn emitTextGlyphRuns(
    list: *PaintCommandBatch,
    document: *const dom.Dom,
    node_id: dom.DomNodeId,
    rect: layout.Rect,
    row: StyleRow,
    glyphs: *tty.GlyphTable,
    g: *Graphemes,
    dw: *DisplayWidth,
) !void {
    if (!(rect.w > 0 and rect.h > 0)) return;
    const slice = document.getTextSlice(node_id);
    const cb = computeContentBox(rect, row);
    const color = computeTextColor(document, node_id, row);
    if (cb.rect.w == 0 or cb.rect.h == 0) return;

    var y_offset: usize = 0;
    var line_start: usize = 0;
    var line_width: usize = 0;
    var last_break_bytes: ?usize = null;
    var word_iter = Words.init(list.ops.allocator) catch unreachable;
    defer word_iter.deinit(list.ops.allocator);
    var witer = word_iter.iterator(slice);
    while (witer.next()) |seg| {
        const bytes = seg.bytes(slice);
        const seg_w = dw.strWidth(bytes);
        if (line_width + seg_w > cb.rect.w and line_width > 0) {
            const line_bytes_end = last_break_bytes orelse seg.offset;
            const line_bytes = slice[line_start..line_bytes_end];
            const shaped = try buildGlyphRun(list.ops.allocator, g, dw, glyphs, line_bytes, cb.rect.w, false);
            if (shaped.run.len > 0) {
                const extra = computeJustifyOffset(cb.rect.w, shaped.width_cols, row.justify);
                try list.push(PaintOp{ .GlyphRun = .{ .x = rect.x + cb.inset_left + extra, .y = rect.y + cb.inset_top + y_offset, .glyphs = shaped.run, .color = color } });
            }
            y_offset += 1;
            line_start = seg.offset;
            line_width = seg_w;
            last_break_bytes = seg.offset + seg.len;
            continue;
        }
        line_width += seg_w;
        last_break_bytes = seg.offset + seg.len;
    }
    if (line_start < slice.len and y_offset < cb.rect.h) {
        const line_bytes = slice[line_start..];
        const shaped = try buildGlyphRun(list.ops.allocator, g, dw, glyphs, line_bytes, cb.rect.w, true);
        if (shaped.run.len > 0) {
            const extra = computeJustifyOffset(cb.rect.w, shaped.width_cols, row.justify);
            try list.push(PaintOp{ .GlyphRun = .{ .x = rect.x + cb.inset_left + extra, .y = rect.y + cb.inset_top + y_offset, .glyphs = shaped.run, .color = color } });
        }
    }
}

pub fn computePaintCommands(list: *PaintCommandBatch, document: *const dom.Dom, tree: *const layout.BoxTree, glyphs: *tty.GlyphTable) !void {
    // Painting order follows CSS background, borders, then content (text). Stacking contexts are out of scope here.
    const items = document.headers.slice();
    var g = try Graphemes.init(list.ops.allocator);
    defer g.deinit(list.ops.allocator);
    var dw = try DisplayWidth.init(list.ops.allocator);
    defer dw.deinit(list.ops.allocator);

    var i: usize = 0;
    while (i < tree.boxes.items.len) : (i += 1) {
        const h = tree.boxes.items[i];
        const sid = items.items(.style_id)[@as(usize, @intCast(h.dom_id))];
        const row: StyleRow = document.styles.cols.items[@intCast(sid)];

        try emitGlyphTileFill(list, glyphs, h.rect, row);
        try emitBackgroundFillIfAny(list, h.rect, row);
        try emitBorderStrokeIfAny(list, h.rect, row);

        const kind = items.items(.kind)[@as(usize, @intCast(h.dom_id))];
        if (kind == .text) {
            try emitTextGlyphRuns(list, document, h.dom_id, h.rect, row, glyphs, &g, &dw);
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
    var r = try tty.Raster.init(al, 10, 6);
    defer r.deinit(al);
    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();
    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    try dl.push(PaintOp{ .StrokeRect = .{ .x = 2, .y = 1, .w = 6, .h = 4, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .style = .line_light, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } } });
    // Force ASCII fallback for this test
    tty.setUseUnicodeBoxes(false);
    defer tty.setUseUnicodeBoxes(true);
    try tty.rasterizeDisplayList(&r, al, &glyphs, &dl);
    const got = try r.toStringAlloc(al, &glyphs);
    defer al.free(got);
    const want =
        "          \n" ++
        "  +----+  \n" ++
        "  |    |  \n" ++
        "  |    |  \n" ++
        "  +----+  \n" ++
        "          \n";
    try std.testing.expectEqualStrings(want, got);
}

test "text color inheritance: parent element color applies to child text glyph run" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var d = dom.Dom.init(al);
    defer d.deinit();
    const root = try d.addElement("text-blue-200");
    const txt = try d.addText("A");
    d.appendChild(root, txt);

    var tree = try layout.allocateBoxTreeFromDOM(al, &d, root);
    defer tree.deinit();
    // Perform layout so text node gets a non-zero rect
    var display_width = try @import("DisplayWidth").init(al);
    defer display_width.deinit(al);
    try layout.layoutBoxesInPlace(al, &tree, &d, 0, .{ .x = 0, .y = 0, .w = 10, .h = 3 }, &display_width);
    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();
    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    try computePaintCommands(&dl, &d, &tree, &glyphs);

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

    const sr = tailwind.parseUtilityClassList("text-blue-200");
    const rgb = tailwind.get_fg_rgb(sr) orelse return error.TestExpectedFg;
    const want: Rgba8 = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
    try std.testing.expectEqual(want, got);
}
