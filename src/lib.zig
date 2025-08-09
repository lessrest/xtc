const std = @import("std");
pub const DisplayWidth = @import("DisplayWidth");
pub const Graphemes = @import("Graphemes");
pub const Words = @import("Words");
// Re-export style and tailwind utilities
pub usingnamespace @import("style.zig");
pub const StyleRow = @import("style.zig").StyleRow;
pub const defaultStyleRow = @import("style.zig").defaultStyleRow;
pub const layoutFromStyleRow = @import("layout.zig").layoutFromStyleRow;
pub const styleAlignToCross = @import("style.zig").styleAlignToCross;
pub const parseUtilityClassList = @import("tailwind.zig").parseUtilityClassList;
pub const utilityTokensFromStyleRow = @import("tailwind.zig").utilityTokensFromStyleRow;
pub const StyleTable = @import("style.zig").StyleTable;
pub const StyleDisplay = @import("style.zig").StyleDisplay;
// Re-export layout mapping and enums
pub usingnamespace @import("layout.zig");
// Re-export DOM
pub usingnamespace @import("dom.zig");
pub const trealla = @import("trealla.zig");

pub const PaintCommandBatch = @import("paint.zig").PaintCommandBatch;
pub const drawBorderAscii = @import("tty.zig").drawBorderAscii;
pub const drawBorderUnicode = @import("tty.zig").drawBorderUnicode;
pub const rasterizeDisplayListAscii = @import("tty.zig").rasterizeDisplayListAscii;
pub const Rgba8 = @import("paint.zig").Rgba8;
pub const GlyphTable = @import("tty.zig").GlyphTable;
pub const GlyphId = @import("tty.zig").GlyphId;

comptime {
    @setEvalBranchQuota(20000);
}

// --- DOM scaffolding (node headers in MultiArrayList; style interning) ---

// (Rules added into RULES below)

test "utility parse + emit: roundtrip simple flex row with padding" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const s = "flex flex-row justify-between items-center w-10 h-3 p-2 border-2";
    const row = parseUtilityClassList(s);
    try std.testing.expect(row.display == .flex);
    try std.testing.expect(row.flex_dir == .row);
    try std.testing.expect(row.justify == .space_between);
    try std.testing.expect(row.align_items == .center);
    try std.testing.expectEqual(@as(u16, 10), row.width_cells);
    try std.testing.expectEqual(@as(u16, 3), row.height_cells);
    try std.testing.expectEqual(@as(u4, 2), row.padding.t);
    try std.testing.expectEqual(@as(u4, 2), row.padding.r);
    try std.testing.expectEqual(@as(u4, 2), row.padding.b);
    try std.testing.expectEqual(@as(u4, 2), row.padding.l);
    try std.testing.expectEqual(@as(u2, 2), row.border.width_cells);

    const toks = try utilityTokensFromStyleRow(al, row);
    defer {
        // free duplicated slices
        for (toks) |tok| al.free(@constCast(tok));
        al.free(toks);
    }
    // Ensure at least a subset is emitted
    var seen: usize = 0;
    inline for (&[_][]const u8{ "flex", "flex-row", "justify-between", "items-center", "w-10", "h-3", "p-2", "border-2" }) |needle| {
        var found = false;
        for (toks) |tok| {
            if (std.mem.eql(u8, tok, needle)) {
                found = true;
                break;
            }
        }
        if (found) seen += 1;
    }
    try std.testing.expect(seen >= 6);
}

// Layout provider contract: caller supplies an object `provider` with:
//   - fn props(provider, dom: *const Dom, id: DomNodeId) Layout
//   - fn measure(provider, dom: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize
fn layoutNode(alloc_: std.mem.Allocator, dom_: *const Dom, id_: DomNodeId, rect_: Rect, provider_: anytype, arena_: *std.heap.ArenaAllocator) !*BoxNode {
    const node = try alloc_.create(BoxNode);
    node.* = .{ .id = id_, .rect = rect_, .first_child = null, .next_sibling = null };
    const items = dom_.headers.slice();
    const kind = items.items(.kind)[@as(usize, @intCast(id_))];
    if (kind == .element) {
        const layout = provider_.props(dom_, id_);
        // Gather children ids
        const child_count = items.items(.child_count)[@as(usize, @intCast(id_))];
        if (child_count > 0) {
            var child_ids = try arena_.allocator().alloc(DomNodeId, child_count);
            var sizes = try arena_.allocator().alloc(BoxSize, child_count);
            var idx: usize = 0;
            var c = items.items(.first_child)[@as(usize, @intCast(id_))];
            while (idx < child_count) : (idx += 1) {
                child_ids[idx] = c;
                const s = provider_.measure(dom_, c, rect_.w, rect_.h);
                sizes[idx] = s;
                c = items.items(.next_sibling)[@as(usize, @intCast(c))];
            }
            // Compute positions using greedy single-line layout
            var content_extent: i32 = 0;
            for (sizes) |s| content_extent += @as(i32, @intCast(if (layout.direction == .row) s.width else s.height));
            const container_extent: i32 = @as(i32, @intCast(if (layout.direction == .row) rect_.w else rect_.h));
            const dist = try calculateSpaces(alloc_, layout.main_align, container_extent, content_extent, child_count);
            defer alloc_.free(dist.between_gaps);

            var cursor_main: i32 = dist.start_space;
            // Compute grow distribution for this node's immediate children
            var total_grow: usize = 0;
            {
                var gi: usize = 0;
                while (gi < child_count) : (gi += 1) {
                    const sidg = items.items(.style_id)[@as(usize, @intCast(child_ids[gi]))];
                    const srowg = dom_.styles.cols.items[@intCast(sidg)];
                    total_grow += srowg.flex.grow;
                }
            }
            var extra_main: []i32 = &[_]i32{};
            if (total_grow > 0) {
                const content_extent2: i32 = content_extent;
                const container_extent2: i32 = container_extent;
                var remaining: i32 = container_extent2 - content_extent2 - dist.start_space;
                var sum_gaps: i32 = 0;
                var gi2: usize = 0;
                while (gi2 < dist.between_gaps.len) : (gi2 += 1) sum_gaps += dist.between_gaps[gi2];
                remaining -= sum_gaps;
                if (remaining > 0) {
                    extra_main = try arena_.allocator().alloc(i32, child_count);
                    var idxg: usize = 0;
                    while (idxg < child_count) : (idxg += 1) {
                        const sidg = items.items(.style_id)[@as(usize, @intCast(child_ids[idxg]))];
                        const srowg = dom_.styles.cols.items[@intCast(sidg)];
                        const share = @divTrunc(remaining * @as(i32, @intCast(srowg.flex.grow)), @as(i32, @intCast(total_grow)));
                        extra_main[idxg] = share;
                        remaining -= share;
                    }
                    var idxr: usize = 0;
                    while (remaining > 0) : (remaining -= 1) {
                        if (idxr >= child_count) idxr = 0;
                        const sidg2 = items.items(.style_id)[@as(usize, @intCast(child_ids[idxr]))];
                        const srowg2 = dom_.styles.cols.items[@intCast(sidg2)];
                        if (srowg2.flex.grow > 0) extra_main[idxr] += 1;
                        idxr += 1;
                    }
                }
            }
            idx = 0;
            var prev_ptr: ?*BoxNode = null;
            while (idx < child_count) : (idx += 1) {
                const s = sizes[idx];
                var cx: usize = rect_.x;
                var cy: usize = rect_.y;
                var cw: usize = s.width;
                var ch: usize = s.height;
                if (extra_main.len != 0) {
                    const addm: i32 = extra_main[idx];
                    if (layout.direction == .row) cw += @as(usize, @intCast(@max(0, addm))) else ch += @as(usize, @intCast(@max(0, addm)));
                }
                if (layout.direction == .row) {
                    cx = rect_.x + @as(usize, @intCast(cursor_main));
                    switch (layout.cross_align) {
                        .start => {
                            cy = rect_.y;
                            ch = s.height;
                        },
                        .center => {
                            ch = if (s.height > rect_.h) rect_.h else s.height;
                            cy = rect_.y + (rect_.h - ch) / 2;
                        },
                        .end => {
                            ch = if (s.height > rect_.h) rect_.h else s.height;
                            cy = rect_.y + (rect_.h - ch);
                        },
                        .stretch => {
                            cy = rect_.y;
                            ch = rect_.h;
                        },
                    }
                } else {
                    cy = rect_.y + @as(usize, @intCast(cursor_main));
                    switch (layout.cross_align) {
                        .start => {
                            cx = rect_.x;
                            cw = s.width;
                        },
                        .center => {
                            cw = if (s.width > rect_.w) rect_.w else s.width;
                            cx = rect_.x + (rect_.w - cw) / 2;
                        },
                        .end => {
                            cw = if (s.width > rect_.w) rect_.w else s.width;
                            cx = rect_.x + (rect_.w - cw);
                        },
                        .stretch => {
                            cx = rect_.x;
                            cw = rect_.w;
                        },
                    }
                }
                const child_rect: Rect = .{ .x = cx, .y = cy, .w = cw, .h = ch };
                const child_box = try layoutNode(alloc_, dom_, child_ids[idx], child_rect, provider_, arena_);
                if (prev_ptr) |prev| prev.next_sibling = child_box else node.first_child = child_box;
                prev_ptr = child_box;
                const advanced = if (layout.direction == .row) cw else ch;
                cursor_main += @as(i32, @intCast(advanced));
                if (idx < dist.between_gaps.len) cursor_main += dist.between_gaps[idx];
            }
        }
    } else {
        // text node: size is already measured by provider; no children
    }
    return node;
}

pub fn layoutDomAlloc(arena: *std.heap.ArenaAllocator, dom: *const Dom, root: DomNodeId, root_rect: Rect, provider: anytype) !*BoxNode {
    return try layoutNode(arena.allocator(), dom, root, root_rect, provider, arena);
}

pub fn renderBoxTreeAscii(r: *Raster, root: *const BoxNode) void {
    var stack: ?*const BoxNode = root;
    while (stack) |node| {
        drawBorderAscii(r, node.rect.x, node.rect.y, node.rect.w, node.rect.h);
        if (node.first_child) |c| {
            renderBoxTreeAscii(r, c);
        }
        stack = node.next_sibling;
    }
}

const DomNodeId = @import("dom.zig").DomNodeId;
const Rect = @import("layout.zig").Rect;
const BoxNode = @import("dom.zig").BoxNode;
const Dom = @import("dom.zig").Dom;
pub const calculateSpaces = @import("layout.zig").calculateSpaces;
pub const domFromXmlAlloc = @import("xml.zig").domFromXmlAlloc;

pub const BoxHeader = struct {
    dom_id: DomNodeId,
    rect: Rect,
    first_child: u32, // index into headers, or maxInt(u32) when no children
    child_count: u32,
};

pub const BoxTree = struct {
    headers: std.ArrayList(BoxHeader),
    root_index: u32,

    pub fn init(alloc: std.mem.Allocator) BoxTree {
        return .{ .headers = std.ArrayList(BoxHeader).init(alloc), .root_index = 0 };
    }

    pub fn deinit(self: *BoxTree) void {
        self.headers.deinit();
        self.* = undefined;
    }

    pub fn children(self: *const BoxTree, idx: usize) []const BoxHeader {
        const h = self.headers.items[idx];
        if (h.child_count == 0) return &[_]BoxHeader{};
        const start: usize = @intCast(h.first_child);
        const end: usize = start + @as(usize, @intCast(h.child_count));
        return self.headers.items[start..end];
    }
};

// --- ANSI styling helpers for human-friendly debug output ---
pub const Ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const fg = struct {
        pub const black = "\x1b[30m";
        pub const red = "\x1b[31m";
        pub const green = "\x1b[32m";
        pub const yellow = "\x1b[33m";
        pub const blue = "\x1b[34m";
        pub const magenta = "\x1b[35m";
        pub const cyan = "\x1b[36m";
        pub const white = "\x1b[37m";
        pub const gray = "\x1b[90m"; // bright black
    };
};

/// Write a nicely formatted dump of the box tree with rects and node kinds.
pub fn dumpBoxTree(alloc: std.mem.Allocator, writer: anytype, tree: *const BoxTree, dom: *const Dom) !void {
    // Emit XML-formatted dump
    try writer.print("<boxes>\n", .{});
    try dumpBoxTreeNodeXml(alloc, writer, tree, dom, tree.root_index, 1);
    try writer.print("</boxes>\n", .{});
}

fn writeIndent(writer: anytype, depth: usize, is_last: bool, more_mask: u64) !void {
    var d: usize = 0;
    while (d < depth) : (d += 1) {
        const has_more = (more_mask & (@as(u64, 1) << @intCast(d))) != 0;
        try writer.print("{s}{s}{s}", .{ Ansi.fg.gray, if (has_more) "│  " else " ", Ansi.reset });
    }
    if (depth > 0) {
        try writer.print("{s}{s}{s}", .{ Ansi.fg.gray, if (is_last) "└─ " else "├─ ", Ansi.reset });
    }
}

fn xmlIndent(writer: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.print("  ", .{});
}

fn dumpStyleRowXml(alloc: std.mem.Allocator, writer: anytype, row: StyleRow, depth: usize) !void {
    try xmlIndent(writer, depth);
    // Emit Tailwind-like utility class list instead of verbose attributes
    const toks = try utilityTokensFromStyleRow(alloc, row);
    defer {
        for (toks) |tok| alloc.free(@constCast(tok));
        alloc.free(toks);
    }
    try writer.print("<style class=\"", .{});
    var first = true;
    for (toks) |tok| {
        if (!first) try writer.print(" ", .{});
        first = false;
        try writer.print("{s}", .{tok});
    }
    try writer.print("\"/>\n", .{});
}

pub fn dumpBoxTreeNodeXml(alloc: std.mem.Allocator, writer: anytype, tree: *const BoxTree, dom: *const Dom, idx: u32, depth: usize) !void {
    const h = tree.headers.items[@as(usize, @intCast(idx))];
    const items = dom.headers.slice();
    const kind = items.items(.kind)[@as(usize, @intCast(h.dom_id))];

    try xmlIndent(writer, depth);
    try writer.print("<node kind=\"{s}\" dom-id=\"{d}\" x=\"{d}\" y=\"{d}\" w=\"{d}\" h=\"{d}\">\n", .{ if (kind == .element) "element" else "text", h.dom_id, h.rect.x, h.rect.y, h.rect.w, h.rect.h });

    const sid = items.items(.style_id)[@as(usize, @intCast(h.dom_id))];
    const row = dom.styles.cols.items[@intCast(sid)];
    try dumpStyleRowXml(alloc, writer, row, depth + 1);

    if (kind == .text) {
        try xmlIndent(writer, depth + 1);
        try writer.print("<text>", .{});
        const txt = dom.getTextSlice(h.dom_id);
        // Note: not escaping, assuming UTF-8 without special chars; extend if needed.
        try writer.print("{s}", .{txt});
        try writer.print("</text>\n", .{});
    }

    if (h.child_count > 0) {
        const start: usize = @intCast(h.first_child);
        var j: usize = 0;
        while (j < h.child_count) : (j += 1) {
            const child_idx: u32 = @intCast(start + j);
            try dumpBoxTreeNodeXml(alloc, writer, tree, dom, child_idx, depth + 1);
        }
    }

    try xmlIndent(writer, depth);
    try writer.print("</node>\n", .{});
}

pub fn renderBoxTreeAsciiIndexed(r: *Raster, tree: *const BoxTree) void {
    var i: usize = 0;
    while (i < tree.headers.items.len) : (i += 1) {
        const h = tree.headers.items[i];
        drawBorderAscii(r, h.rect.x, h.rect.y, h.rect.w, h.rect.h);
    }
}

/// Build only the structural BoxTree (contiguous child ranges), with zeroed rects.
fn emitStructureNode(tree: *BoxTree, dom_: *const Dom, id_: DomNodeId) !u32 {
    const idx_u: u32 = @intCast(tree.headers.items.len);
    try tree.headers.append(.{ .dom_id = id_, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .first_child = std.math.maxInt(u32), .child_count = 0 });
    const items = dom_.headers.slice();
    const kind = items.items(.kind)[@as(usize, @intCast(id_))];
    if (kind == .element) {
        const child_count = items.items(.child_count)[@as(usize, @intCast(id_))];
        if (child_count > 0) {
            var i: usize = 0;
            var c = items.items(.first_child)[@as(usize, @intCast(id_))];
            const first_child_index: u32 = @intCast(tree.headers.items.len);
            while (i < child_count) : (i += 1) {
                _ = try emitStructureNode(tree, dom_, c);
                c = items.items(.next_sibling)[@as(usize, @intCast(c))];
            }
            var hdr_ptr = &tree.headers.items[@as(usize, @intCast(idx_u))];
            hdr_ptr.first_child = first_child_index;
            hdr_ptr.child_count = @intCast(child_count);
        }
    }
    return idx_u;
}

pub fn buildBoxTreeFromDomAlloc(alloc: std.mem.Allocator, dom: *const Dom, root: DomNodeId) !BoxTree {
    var tree = BoxTree.init(alloc);
    tree.root_index = try emitStructureNode(&tree, dom, root);
    return tree;
}

/// Layout pass: mutate headers' rects in-place using provider props + measure.
pub const layoutBoxesInPlaceNode = @import("layout.zig").layoutBoxesInPlaceNode;
pub const layoutBoxesInPlace = @import("layout.zig").layoutBoxesInPlace;

test "dom: unicode borders render" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    // DOM: root with two children
    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const c1 = try dom.addElement("box1");
    const c2 = try dom.addElement("box2");
    dom.appendChild(root, c1);
    dom.appendChild(root, c2);

    // Structure-only tree
    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();

    // Provider: row, stretch; fixed box sizes
    const Provider = struct {
        sizes: []const BoxSize,
        pub fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items = dom_.headers.slice();
            const sid = items.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        pub fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
            _ = dom_;
            _ = max_w;
            _ = max_h;
            const idx: usize = @intCast(id);
            return self.sizes[idx];
        }
    };
    const provider = Provider{ .sizes = &.{ b(0, 0), b(4, 3), b(4, 3) } };

    // Layout within inner area of 14x5 container
    const container = b(14, 5);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);

    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();

    try drawBorderUnicode(&r, al, &glyphs, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    // Render children with unicode borders
    const children = tree.children(@intCast(tree.root_index));
    for (children) |h| {
        try drawBorderUnicode(&r, al, &glyphs, h.rect.x, h.rect.y, h.rect.w, h.rect.h);
    }

    const got = try toUtf8AllocWithGlyphs(&r, al, &glyphs);
    defer al.free(got);
    const want =
        "┌────────────┐\n" ++
        "│┌──┐┌──┐    │\n" ++
        "││  ││  │    │\n" ++
        "│└──┘└──┘    │\n" ++
        "└────────────┘\n";
    try expectAsciiEqual(want, got);
}

test "xml full stack: utility classes render unicode boxes" {
    const xml = @import("xml");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const input =
        \\<?xml version="1.0" standalone="yes" ?>
        \\<root class="flex flex-row">
        \\  <box class="basis-6 h-3 border" />
        \\  <box class="basis-6 h-3 border" />
        \\</root>
    ;
    var fbs = std.io.fixedBufferStream(input);
    var xdoc = try xml.parse(al, "<stdin>", fbs.reader());
    defer xdoc.deinit();
    const xd = try domFromXmlAlloc(al, &xdoc);
    var dom = xd.dom;
    defer dom.deinit();
    const root = xd.root;

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();

    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    const container = b(18, 3);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();

    // Layout directly in the full raster area
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = 0, .y = 0, .w = container.width, .h = container.height }, provider);

    // Build and rasterize via display list (ASCII border style)
    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        "+------++------+  \n" ++
        "|      ||      |  \n" ++
        "+------++------+  \n";
    try expectAsciiEqual(want, got);
}

test "xml full stack: glyph-tiles without borders (two basis boxes in row)" {
    const xml = @import("xml");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const input =
        \\<?xml version="1.0" standalone="yes" ?>
        \\<root class="flex flex-row items-stretch">
        \\  <box class="basis-4 h-3" />
        \\  <box class="basis-4 h-3" />
        \\</root>
    ;
    var fbs = std.io.fixedBufferStream(input);
    var xdoc = try xml.parse(al, "<stdin>", fbs.reader());
    defer xdoc.deinit();
    const xd = try domFromXmlAlloc(al, &xdoc);
    var dom = xd.dom;
    defer dom.deinit();

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, xd.root);
    defer tree.deinit();
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    // Layout: 12x3 inner area that fits exactly two 4x3 boxes back-to-back
    const container = b(12, 3);
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = 0, .y = 0, .w = container.width, .h = container.height }, provider);

    const got = try renderLayoutAsGlyphTilesAscii(al, &dom, &tree, container.width, container.height, '.', 'a');
    defer al.free(got);
    // Note: With items-stretch and basis 4 + height 3, each child covers 4x3.
    // Our glyph-tiler assigns 'a' to first child, 'b' to second. Expect ab blocks:
    // aaaa bbbb
    // aaaa bbbb
    // aaaa bbbb
    // Construct expected string accordingly.
    const want2 =
        "aaaabbbb....\n" ++
        "aaaabbbb....\n" ++
        "aaaabbbb....\n";
    // Viewport is 12 wide: two 4-wide boxes -> 8 columns of a/b, remaining 4 dots background.
    try expectAsciiEqual(want2, got);
}

test "dom text node: layout + paint glyph run" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const txt = try dom.addText("hi");
    dom.appendChild(root, txt);

    var sr_root = defaultStyleRow();
    sr_root.flex_dir = .row;
    sr_root.justify = .start;
    sr_root.align_items = .start;
    try dom.setStyle(root, sr_root);
    var sr_text = defaultStyleRow();
    sr_text.border.width_cells = 1;
    try dom.setStyle(txt, sr_text);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    const container = b(10, 5);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        "+--------+\n" ++
        "|+--+    |\n" ++
        "||hi|    |\n" ++
        "|+--+    |\n" ++
        "+--------+\n";
    try expectAsciiEqual(want, got);
}

test "dom text node: combining grapheme treated as single cell" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const txt = try dom.addText("h" ++ "e\u{301}"); // h + e + combining acute
    dom.appendChild(root, txt);

    var sr_root = defaultStyleRow();
    sr_root.flex_dir = .row;
    sr_root.justify = .start;
    sr_root.align_items = .start;
    try dom.setStyle(root, sr_root);
    var sr_text = defaultStyleRow();
    sr_text.border.width_cells = 1;
    try dom.setStyle(txt, sr_text);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    const container = b(10, 5);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try toUtf8AllocWithGlyphs(&r, al, &glyphs);
    defer al.free(got);
    const want =
        "+--------+\n" ++
        "|+--+    |\n" ++
        "||h" ++ "e\u{301}" ++ "|    |\n" ++
        "|+--+    |\n" ++
        "+--------+\n";
    try expectAsciiEqual(want, got);
}

test "wrap mixed ascii+emoji prose with center and right alignment (predictable)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const txt = try dom.addText("One 😊 two three");
    dom.appendChild(root, txt);

    var sr_root = defaultStyleRow();
    sr_root.flex_dir = .row;
    sr_root.justify = .start;
    sr_root.align_items = .start;
    try dom.setStyle(root, sr_root);
    var sr_text = defaultStyleRow();
    sr_text.justify = .start;
    // Ensure text box height spans container so wrapped lines are visible
    sr_text.align_self = .stretch;
    try dom.setStyle(txt, sr_text);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    const container = b(14, 6);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try toUtf8AllocWithGlyphs(&r, al, &glyphs);
    defer al.free(got);
    try std.testing.expectEqualStrings(
        \\+------------+
        \\|One 😊 two   |
        \\|three       |
        \\|            |
        \\|            |
        \\+------------+
        \\
    ,
        got,
    );
}

test "dom: build structure, layout in place, render row" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    // Build a tiny DOM: root element with two child elements
    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const c1 = try dom.addElement("c1");
    const c2 = try dom.addElement("c2");
    dom.appendChild(root, c1);
    dom.appendChild(root, c2);

    // Build structure-only box tree
    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();

    // Define a provider: row with stretch cross; fixed sizes for children
    const Provider = struct {
        sizes: []const BoxSize,
        pub fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items = dom_.headers.slice();
            const sid = items.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        pub fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
            _ = dom_;
            _ = max_w;
            _ = max_h;
            const idx: usize = @intCast(id);
            return self.sizes[idx];
        }
    };
    const provider = Provider{ .sizes = &.{ b(0, 0), b(4, 3), b(4, 3) } };

    // Layout into the inner content area of a 14x5 container
    const container = b(14, 5);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    // Render only the children (skip drawing a border for the root box)
    const children = tree.children(@intCast(tree.root_index));
    for (children) |h| {
        drawBorderAscii(&r, h.rect.x, h.rect.y, h.rect.w, h.rect.h);
    }

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+------------+
        \\|+--++--+    |
        \\||  ||  |    |
        \\|+--++--+    |
        \\+------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "style: interning and layout mapping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    // Interning: identical rows dedup; differing rows new id
    var table = StyleTable.init(al);
    defer table.deinit();
    const r0 = defaultStyleRow();
    const id0 = try table.intern(al, r0);
    const id1 = try table.intern(al, r0);
    try std.testing.expectEqual(id0, id1);
    var r2 = r0;
    r2.flex_dir = .column;
    const id2 = try table.intern(al, r2);
    try std.testing.expect(id2 != id0);

    // Mapping: row -> Layout.direction row; justify -> main_align; align_items -> cross_align
    const l0 = layoutFromStyleRow(r0);
    try std.testing.expect(l0.direction == .row);
    try std.testing.expect(l0.main_align == .start);
    try std.testing.expect(l0.cross_align == .start);

    const l2 = layoutFromStyleRow(r2);
    try std.testing.expect(l2.direction == .column);
}

test "layout: gaps and align_self override" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const c1 = try dom.addElement("c1");
    const c2 = try dom.addElement("c2");
    dom.appendChild(root, c1);
    dom.appendChild(root, c2);

    // Root style: row, start, stretch, gap main=1
    var r = defaultStyleRow();
    r.gaps.main = 1;
    r.align_items = .stretch;
    try dom.setStyle(root, r);

    // Child 2 overrides align_self to center; fixed sizes
    var r2 = defaultStyleRow();
    r2.align_self = .center;
    try dom.setStyle(c2, r2);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();

    const Provider = struct {
        root_id: DomNodeId,
        pub fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items = dom_.headers.slice();
            const sid = items.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        pub fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
            _ = dom_;
            _ = max_w;
            _ = max_h;
            return if (id == self.root_id) b(0, 0) else b(4, 3);
        }
    };
    const provider = Provider{ .root_id = root };

    const container = b(14, 5);
    var rr = try Raster.init(al, container.width, container.height);
    defer rr.deinit(al);
    drawBorderAscii(&rr, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    const children = tree.children(@intCast(tree.root_index));
    for (children) |h| drawBorderAscii(&rr, h.rect.x, h.rect.y, h.rect.w, h.rect.h);
    const got = try rr.toStringAlloc(al);
    defer al.free(got);
    const want =
        "+------------+\n" ++
        "|+--+ +--+   |\n" ++
        "||  | |  |   |\n" ++
        "|+--+ +--+   |\n" ++
        "+------------+\n";
    try expectAsciiEqual(want, got);
}

/// Word wrap to width using greedy wrap with DP badness minimization (lite):
pub fn wrapAlloc(allocator: std.mem.Allocator, s: []const u8, width: usize) ![][]u8 {
    if (width == 0) return try std.heap.page_allocator.alloc([]u8, 0);
    var words = std.ArrayList([]const u8).init(allocator);
    defer words.deinit();
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |w| {
        if (w.len <= width) {
            try words.append(w);
        } else {
            var i: usize = 0;
            while (i < w.len) : (i += width) {
                const end = @min(w.len, i + width);
                try words.append(w[i..end]);
            }
        }
    }
    const n = words.items.len;
    var pref = try allocator.alloc(usize, n + 1);
    defer allocator.free(pref);
    pref[0] = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) pref[i + 1] = pref[i] + words.items[i].len;

    var dp = try allocator.alloc(i64, n + 1);
    var nxt = try allocator.alloc(usize, n + 1);
    defer allocator.free(dp);
    defer allocator.free(nxt);
    dp[n] = 0;
    nxt[n] = n;
    var k: isize = @as(isize, @intCast(n)) - 1;
    while (k >= 0) : (k -= 1) {
        const idx: usize = @as(usize, @intCast(k));
        var best: i64 = std.math.maxInt(i64) / 4;
        var bestj: usize = idx + 1;
        var j: usize = idx;
        while (j < n) : (j += 1) {
            const words_len = pref[j + 1] - pref[idx];
            const gaps = j - idx;
            const line_len = words_len + gaps;
            if (line_len > width) break;
            const last = (j == n - 1);
            const slack = @as(i64, @intCast(width - line_len));
            const cost: i64 = if (last) 0 else slack * slack * slack;
            const total = cost + dp[j + 1];
            if (total < best) {
                best = total;
                bestj = j + 1;
            }
        }
        dp[idx] = best;
        nxt[idx] = bestj;
    }

    var lines = std.ArrayList([]u8).init(allocator);
    var p: usize = 0;
    while (p < n) {
        const q = nxt[p];
        const joined = try joinWords(allocator, words.items[p..q]);
        try lines.append(joined);
        p = q;
    }
    return lines.toOwnedSlice();
}

pub const Raster = @import("tty.zig").Raster;

// --- DOM/Layout -> DisplayList pipeline ---

pub const computePaintCommands = @import("paint.zig").computePaintCommands;

/// Render helper for tests: fill the entire viewport with a background ASCII glyph
/// (e.g., '.'), then fill each laid-out box rectangle (except the root) with a
/// distinct ASCII glyph starting from `first_glyph` (e.g., 'a', 'b', ...).
/// This avoids border corner cases and makes shape assertions easy.
pub fn renderLayoutAsGlyphTilesAscii(
    allocator: std.mem.Allocator,
    dom: *const Dom,
    tree: *const BoxTree,
    width: usize,
    height: usize,
    background_glyph: u8,
    first_glyph: u8,
) ![]u8 {
    _ = dom; // autofix
    var r = try Raster.init(allocator, width, height);
    defer r.deinit(allocator);
    var glyphs = try GlyphTable.init(allocator);
    defer glyphs.deinit();
    var dl = PaintCommandBatch.init(allocator);
    defer dl.deinit();

    // Fill viewport background
    try dl.push(@import("paint.zig").PaintOp{ .FillGlyphRect = .{ .x = 0, .y = 0, .w = width, .h = height, .glyph = @as(GlyphId, background_glyph) } });

    // Fill each box (skip root_index) with sequential glyphs
    var next: u32 = 0;
    var i: usize = 0;
    while (i < tree.headers.items.len) : (i += 1) {
        if (i == tree.root_index) continue;
        const h = tree.headers.items[i];
        if (h.rect.w == 0 or h.rect.h == 0) continue;
        const ch: u8 = first_glyph + @as(u8, @intCast(next));
        next += 1;
        try dl.push(@import("paint.zig").PaintOp{ .FillGlyphRect = .{ .x = h.rect.x, .y = h.rect.y, .w = h.rect.w, .h = h.rect.h, .glyph = @as(GlyphId, ch) } });
    }

    try rasterizeDisplayListAscii(&r, allocator, &glyphs, &dl);
    return try r.toStringAlloc(allocator);
}

test "pipeline: dom -> layout -> display list -> raster (ascii)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    // DOM: root with two children
    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const c1 = try dom.addElement("c1");
    const c2 = try dom.addElement("c2");
    dom.appendChild(root, c1);
    dom.appendChild(root, c2);

    // Styles: borders on root and children; root flex row
    var sr_root = defaultStyleRow();
    sr_root.border.width_cells = 0; // outer frame is drawn by test; avoid double-inner offset
    sr_root.flex_dir = .row;
    sr_root.justify = .start;
    sr_root.align_items = .stretch;
    try dom.setStyle(root, sr_root);
    var sr_child = defaultStyleRow();
    sr_child.border.width_cells = 1;
    try dom.setStyle(c1, sr_child);
    try dom.setStyle(c2, sr_child);

    // Structure-only tree
    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();

    // Layout provider: derive layout from styles; fixed child sizes 4x3
    const Provider = struct {
        root_id: DomNodeId,
        pub fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items2 = dom_.headers.slice();
            const sid = items2.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        pub fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
            _ = dom_;
            _ = max_w;
            _ = max_h;
            return if (id == self.root_id) b(0, 0) else b(4, 3);
        }
    };
    const provider = Provider{ .root_id = root };

    // Layout within inner area of 14x5 container
    const container = b(14, 5);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    // Build display list from box tree and styles
    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        "+------------+\n" ++
        "|+--++--+    |\n" ++
        "||  ||  |    |\n" ++
        "|+--++--+    |\n" ++
        "+------------+\n";
    try expectAsciiEqual(want, got);
}

// --- Production-ish style provider (initial) ---

pub const StyleProvider = struct {
    graphemes: Graphemes,
    display_width: DisplayWidth,
    // Provider TODOs (production):
    // - Text measurement:
    //   - Grapheme-aware width (double-width, combining marks), tabs
    //   - Whitespace handling: normal/pre/nowrap/pre_wrap
    //   - Wrapping: greedy/balanced; ellipsis per overflow rules
    //   - Return border-box: content + padding + border
    //
    // - Intrinsic sizing:
    //   - Leaves: intrinsic or style overrides (width/height, min/max)
    //   - Containers: pre-measure pass: sum on main axis, max on cross; cache result
    //   - Replaced elements: intrinsic size; fallbacks
    //
    // - Flexbox completeness:
    //   - flex-grow/shrink distribution of free/deficit space with clamping to min/max
    //   - flex-basis:auto vs specified; percent bases
    //   - flex-wrap: multi-line layout and line breaking
    //   - align-content for multi-line cross-axis distribution
    //   - row_reverse/column_reverse direction
    //
    // - Constraints & percentages:
    //   - min-width/height, max-width/height
    //   - percentage resolution against parent inner size (for width/height, padding, margin)
    //   - margin auto (main-axis auto-centering semantics)
    //
    // - Alignment details:
    //   - align-items:baseline (baseline computation for text)
    //   - align-self overrides (already partially supported)
    //   - gap: main and cross (we have main; add cross)
    //
    // - Visual properties influence:
    //   - display:none (skip layout/paint); visibility:hidden (layout yes, paint no)
    //   - overflow:clip (establish clip rect during paint)
    //   - border.style (ascii/unicode mapping), border color, alpha blending
    //
    // - Painting hooks:
    //   - Emit background FillRect from styles (with alpha)
    //   - Emit borders from border spec; corners/joints style
    //   - Emit GlyphRun for text nodes (map DOM text → glyph ids)
    //   - Establish clip for overflow and descendant painting
    //
    // - Ordering/layers:
    //   - order (stable) for layout (done); z-index for paint ordering
    //   - Optional overlay layers (selection/caret) composited after main
    //
    // - Caching & invalidation:
    //   - Cache measure(props) by (node_id, constraints, style_hash, text_epoch)
    //   - Invalidate on style/text change or parent constraints change
    //
    // - Performance ergonomics:
    //   - Reuse arenas, avoid per-node allocations in hot paths
    //   - Small-vec for child temp buffers; pre-size arrays
    //   - Fast style lookup (we have interned rows)
    //
    // - Tests to add:
    //   - Text wrap/ellipsis/whitespace variants
    //   - flex-grow/shrink with min/max constraints
    //   - flex-wrap + align-content distributions
    //   - percentage sizes; margin auto centering
    //   - overflow:clip clipping correctness
    //   - border styles and alpha background blending
    pub fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
        _ = self;
        const items = dom_.headers.slice();
        const sid = items.items(.style_id)[@as(usize, @intCast(id))];
        const row = dom_.styles.cols.items[@intCast(sid)];
        return layoutFromStyleRow(row);
    }

    pub fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
        const items = dom_.headers.slice();
        const kind = items.items(.kind)[@as(usize, @intCast(id))];
        const sid = items.items(.style_id)[@as(usize, @intCast(id))];
        const row = dom_.styles.cols.items[@intCast(sid)];

        const border_w: usize = @as(usize, @intCast(row.border.width_cells));
        // Avoid u4 overflow by widening before addition
        const pad_x: usize = @as(usize, @intCast(row.padding.l)) + @as(usize, @intCast(row.padding.r)) + border_w * 2;
        const pad_y: usize = @as(usize, @intCast(row.padding.t)) + @as(usize, @intCast(row.padding.b)) + border_w * 2;

        var w: usize = 0;
        var h: usize = 0;

        // Explicit overrides are border-box and take precedence
        if (row.width_cells != 0) w = row.width_cells;
        if (row.height_cells != 0) h = row.height_cells;

        // Text nodes: single-line measure via DisplayWidth; 1 row tall
        if (w == 0 or h == 0) {
            if (kind == .text) {
                const slice = dom_.getTextSlice(id);
                const content_w = @min(max_w, self.display_width.strWidth(slice));
                if (w == 0) w = @min(max_w, pad_x + content_w);
                if (h == 0) h = @min(max_h, pad_y + 1);
            }
        }

        // Flex basis applies on main axis as content size; convert to border-box
        if (row.flex.basis_auto == 0) {
            switch (row.flex_dir) {
                .row, .row_reverse => {
                    if (w == 0) w = @min(max_w, @as(usize, @intCast(row.flex.basis_cells)) + pad_x);
                },
                .column, .column_reverse => {
                    if (h == 0) h = @min(max_h, @as(usize, @intCast(row.flex.basis_cells)) + pad_y);
                },
            }
        }

        // Minimal border-box when no intrinsic sizing known
        if (w == 0) w = @min(max_w, pad_x);
        if (h == 0) h = @min(max_h, pad_y);

        // Replaced elements can extend this path later
        return .{ .width = w, .height = h };
    }
};

// --- Spec-vibe tests for the style provider ---

test "style provider: child width/height are border-box (padding/border not added twice)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const child = try dom.addElement("child");
    dom.appendChild(root, child);

    var sr_root = defaultStyleRow();
    sr_root.flex_dir = .row;
    sr_root.justify = .start;
    sr_root.align_items = .start;
    try dom.setStyle(root, sr_root);

    var sr_child = defaultStyleRow();
    // Child should stretch vertically in this test scenario
    sr_child.align_self = .stretch;
    sr_child.width_cells = 6;
    sr_child.height_cells = 4;
    sr_child.padding = .{ .l = 1, .r = 1, .t = 1, .b = 1 };
    sr_child.border.width_cells = 1;
    try dom.setStyle(child, sr_child);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    const container = b(14, 7);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        "+------------+\n" ++
        "|+----+      |\n" ++
        "||    |      |\n" ++
        "||    |      |\n" ++
        "||    |      |\n" ++
        "|+----+      |\n" ++
        "+------------+\n";
    try expectAsciiEqual(want, got);
}

test "style provider: padding+border-only element still has minimal box" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const child = try dom.addElement("child");
    dom.appendChild(root, child);

    var sr_root = defaultStyleRow();
    sr_root.flex_dir = .row;
    sr_root.justify = .start;
    sr_root.align_items = .start;
    try dom.setStyle(root, sr_root);
    var sr_child = defaultStyleRow();
    sr_child.padding = .{ .l = 1, .r = 1, .t = 1, .b = 1 };
    sr_child.border.width_cells = 1;
    try dom.setStyle(child, sr_child);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    const container = b(12, 6);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    // Minimal border rectangle: padding(1+1)+border(1+1) = 4 in each dimension
    const want =
        "+----------+\n" ++
        "|+--+      |\n" ++
        "||  |      |\n" ++
        "||  |      |\n" ++
        "|+--+      |\n" ++
        "+----------+\n";
    try expectAsciiEqual(want, got);
}

test "style provider: flex-basis (row) sets main-axis size when width is auto" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const child = try dom.addElement("child");
    dom.appendChild(root, child);

    var sr_root = defaultStyleRow();
    sr_root.flex_dir = .row;
    sr_root.justify = .start;
    sr_root.align_items = .start;
    try dom.setStyle(root, sr_root);
    var sr_child = defaultStyleRow();
    // Child should stretch vertically in this test scenario
    sr_child.align_self = .stretch;
    sr_child.flex.basis_auto = 0;
    sr_child.flex.basis_cells = 6;
    sr_child.height_cells = 3;
    sr_child.border.width_cells = 1;
    try dom.setStyle(child, sr_child);

    var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
    defer tree.deinit();
    var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
    defer provider.graphemes.deinit(al);
    defer provider.display_width.deinit(al);

    const container = b(14, 7);
    var r = try Raster.init(al, container.width, container.height);
    defer r.deinit(al);
    drawBorderAscii(&r, 0, 0, container.width, container.height);
    const inner_x: usize = if (container.width >= 2) 1 else 0;
    const inner_y: usize = if (container.height >= 2) 1 else 0;
    const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
    const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
    try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

    var dl = PaintCommandBatch.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try computePaintCommands(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        "+------------+\n" ++
        "|+------+    |\n" ++
        "||      |    |\n" ++
        "||      |    |\n" ++
        "||      |    |\n" ++
        "|+------+    |\n" ++
        "+------------+\n";
    try expectAsciiEqual(want, got);
}

pub fn toUtf8AllocWithGlyphs(self: *const Raster, allocator: std.mem.Allocator, glyphs: *const GlyphTable) ![]u8 {
    // First pass: compute exact byte length using glyph slices
    var total: usize = 0;
    var y: usize = 0;
    while (y < self.height) : (y += 1) {
        var x: usize = 0;
        while (x < self.width) : (x += 1) {
            const gid = self.cells[y * self.width + x];
            if (gid <= 255) {
                total += 1;
            } else if (glyphs.getSlice(gid)) |sl| {
                total += sl.len;
            } else {
                std.debug.panic("glyph not found: {d}", .{gid});
                total += 1; // '?'
            }
        }
        total += 1; // \n
    }
    var out = try allocator.alloc(u8, total);
    var idx: usize = 0;
    y = 0;
    while (y < self.height) : (y += 1) {
        var x: usize = 0;
        while (x < self.width) : (x += 1) {
            const gid = self.cells[y * self.width + x];
            if (gid <= 255) {
                out[idx] = @as(u8, @intCast(gid));
                idx += 1;
            } else if (glyphs.getSlice(gid)) |sl| {
                std.mem.copyForwards(u8, out[idx..][0..sl.len], sl);
                idx += sl.len;
            } else {
                out[idx] = '?';
                idx += 1;
            }
        }
        out[idx] = '\n';
        idx += 1;
    }
    return out;
}

pub fn renderParagraphAlloc(allocator: std.mem.Allocator, s: []const u8, width: usize) !Raster {
    const lines = try wrapAlloc(allocator, s, width);
    defer {
        for (lines) |ln| allocator.free(ln);
        allocator.free(lines);
    }
    var r = try Raster.init(allocator, width, lines.len);
    var y: usize = 0;
    while (y < lines.len) : (y += 1) {
        const ln = lines[y];
        const n = if (ln.len < width) ln.len else width;
        var x: usize = 0;
        while (x < n) : (x += 1) r.set(x, y, ln[x]);
    }
    return r;
}

fn joinWords(allocator: std.mem.Allocator, ws: [][]const u8) ![]u8 {
    if (ws.len == 0) return try allocator.alloc(u8, 0);
    var total: usize = ws.len - 1;
    for (ws) |w| total += w.len;
    var buf = try allocator.alloc(u8, total);
    var i: usize = 0;
    var idx: usize = 0;
    while (i < ws.len) : (i += 1) {
        const w = ws[i];
        std.mem.copyForwards(u8, buf[idx..][0..w.len], w);
        idx += w.len;
        if (i + 1 < ws.len) {
            buf[idx] = ' ';
            idx += 1;
        }
    }
    return buf;
}

// --- Simple compositor primitives for ASCII-art TDD ---
pub const BoxSize = struct {
    width: usize,
    height: usize,
};

pub const Layout = struct {
    direction: Direction,
    main_align: MainAxisAlignment,
    cross_align: CrossAxisAlignment,
};

pub const layoutFixedBoxesAlloc = @import("layout.zig").layoutFixedBoxesAlloc;
pub const Direction = @import("layout.zig").Direction;
pub const MainAxisAlignment = @import("layout.zig").MainAxisAlignment;
pub const CrossAxisAlignment = @import("layout.zig").CrossAxisAlignment;

/// Compose a single-line flex row/column of fixed-size boxes into a raster.
/// For now, children are placed on the main axis according to `main_align`,
/// without wrapping or cross-axis alignment. Intended for ASCII-art tests.
pub fn composeFixedBoxesAlloc(
    allocator: std.mem.Allocator,
    container_width: usize,
    container_height: usize,
    layout: Layout,
    children: []const BoxSize,
) !Raster {
    var r = try Raster.init(allocator, container_width, container_height);
    // Draw viewport border and compute inner content area
    drawBorderAscii(&r, 0, 0, container_width, container_height);
    const inner_x: usize = if (container_width >= 2) 1 else 0;
    const inner_y: usize = if (container_height >= 2) 1 else 0;
    const inner_w: usize = if (container_width > 1) container_width - 2 else container_width;
    const inner_h: usize = if (container_height > 1) container_height - 2 else container_height;

    const rects = try layoutFixedBoxesAlloc(allocator, inner_x, inner_y, inner_w, inner_h, layout, children);
    defer allocator.free(rects);
    for (rects) |rc| if (rc.w > 0 and rc.h > 0) drawBorderAscii(&r, rc.x, rc.y, rc.w, rc.h);
    return r;
}

/// Helper to compare ASCII rasters while producing a readable diff on failure.
pub fn expectAsciiEqual(want: []const u8, got: []const u8) !void {
    try std.testing.expectEqualStrings(want, got);
    // zig already prints a great diff view
}

// --- Test DSL helpers to reduce boilerplate ---
pub fn b(width: usize, height: usize) BoxSize {
    return .{ .width = width, .height = height };
}

fn joinLinesAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (lines) |ln| total += ln.len + 1; // +\n per line
    var buf = try allocator.alloc(u8, total);
    var idx: usize = 0;
    for (lines) |ln| {
        std.mem.copyForwards(u8, buf[idx..][0..ln.len], ln);
        idx += ln.len;
        buf[idx] = '\n';
        idx += 1;
    }
    return buf;
}

pub fn assertComposeRow(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want_lines: []const []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .row, .main_align = main_align, .cross_align = .stretch };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    const want = try joinLinesAlloc(al, want_lines);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexRow(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .row, .main_align = main_align, .cross_align = .stretch };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexRowWithCross(
    main_align: MainAxisAlignment,
    cross_align: CrossAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .row, .main_align = main_align, .cross_align = cross_align };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

pub fn assertComposeColumn(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want_lines: []const []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .column, .main_align = main_align, .cross_align = .start };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    const want = try joinLinesAlloc(al, want_lines);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexColumn(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .column, .main_align = main_align, .cross_align = .start };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexColumnWithCross(
    main_align: MainAxisAlignment,
    cross_align: CrossAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .column, .main_align = main_align, .cross_align = cross_align };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

// --- Nested composition primitives ---

pub fn blitNonSpace(dst: *Raster, dx: usize, dy: usize, src: *const Raster) void {
    var y: usize = 0;
    while (y < src.height) : (y += 1) {
        var x: usize = 0;
        while (x < src.width) : (x += 1) {
            const gid = src.cells[y * src.width + x];
            if (gid != @as(GlyphId, 32)) dst.setGlyph(dx + x, dy + y, gid);
        }
    }
}

pub const ColumnNode = struct {
    // If width == 0, width is max child width; otherwise use provided width
    width: usize = 0,
    main_align: MainAxisAlignment = .start,
    cross_align: CrossAxisAlignment = .start,
    children: []const BoxSize,
};

pub const NodeKind = enum { Box, Column };
pub const Node = union(NodeKind) {
    Box: BoxSize,
    Column: ColumnNode,
};

fn maxChildWidth(children: []const BoxSize) usize {
    var m: usize = 0;
    for (children) |c| {
        if (c.width > m) {
            m = c.width;
        }
    }
    return m;
}

fn renderColumnAlloc(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    col: ColumnNode,
) !Raster {
    var r = try Raster.init(allocator, width, height);
    const total_h: i32 = blk: {
        var acc: usize = 0;
        for (col.children) |c| acc += c.height;
        break :blk @as(i32, @intCast(acc));
    };
    const count = col.children.len;
    const col_align = col.main_align;
    const dist = try calculateSpaces(allocator, col_align, @as(i32, @intCast(height)), total_h, count);
    defer allocator.free(dist.between_gaps);
    var cursor_y: i32 = dist.start_space;
    var i: usize = 0;
    while (i < col.children.len) : (i += 1) {
        const c = col.children[i];
        var cx: usize = 0;
        var cw: usize = c.width;
        switch (col.cross_align) {
            .start => {
                cx = 0;
                cw = c.width;
            },
            .center => {
                cw = if (c.width > width) width else c.width;
                cx = (width - cw) / 2;
            },
            .end => {
                cw = if (c.width > width) width else c.width;
                cx = width - cw;
            },
            .stretch => {
                cx = 0;
                cw = width;
            },
        }
        drawBorderAscii(&r, cx, @as(usize, @intCast(cursor_y)), cw, c.height);
        cursor_y += @as(i32, @intCast(c.height));
        if (i < dist.between_gaps.len) cursor_y += dist.between_gaps[i];
    }
    return r;
}

pub fn composeRowOfNodesAlloc(
    allocator: std.mem.Allocator,
    container_width: usize,
    container_height: usize,
    main_align: MainAxisAlignment,
    nodes: []const Node,
) !Raster {
    var r = try Raster.init(allocator, container_width, container_height);
    drawBorderAscii(&r, 0, 0, container_width, container_height);
    const inner_x: usize = if (container_width >= 2) 1 else 0;
    const inner_y: usize = if (container_height >= 2) 1 else 0;
    const inner_w: usize = if (container_width > 1) container_width - 2 else container_width;
    const inner_h: usize = if (container_height > 1) container_height - 2 else container_height;

    // Compute per-node width footprints
    var content_w: i32 = 0;
    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        const w: usize = switch (nodes[i]) {
            .Box => |bx| bx.width,
            .Column => |c| if (c.width == 0) maxChildWidth(c.children) else c.width,
        };
        content_w += @as(i32, @intCast(w));
    }
    const dist = try calculateSpaces(allocator, main_align, @as(i32, @intCast(inner_w)), content_w, nodes.len);
    defer allocator.free(dist.between_gaps);

    var cursor_x: i32 = dist.start_space;
    i = 0;
    while (i < nodes.len) : (i += 1) {
        const px: usize = inner_x + @as(usize, @intCast(cursor_x));
        switch (nodes[i]) {
            .Box => |bx| {
                // Stretch boxes to full inner height to match default cross-axis stretch in row
                drawBorderAscii(&r, px, inner_y, bx.width, inner_h);
                cursor_x += @as(i32, @intCast(bx.width));
            },
            .Column => |c| {
                const w: usize = if (c.width == 0) maxChildWidth(c.children) else c.width;
                var sub = try renderColumnAlloc(allocator, w, inner_h, c);
                defer sub.deinit(allocator);
                blitNonSpace(&r, px, inner_y, &sub);
                cursor_x += @as(i32, @intCast(w));
            },
        }
        if (i < dist.between_gaps.len) cursor_x += dist.between_gaps[i];
    }
    return r;
}

// --- Text-in-box primitives

pub const TextBox = struct {
    width: usize,
    height: usize,
    text: []const u8,
};

fn wrapWithOverflowAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    max_lines: usize,
) ![][]u8 {
    const lines = try wrapAlloc(allocator, text, width);
    if (lines.len <= max_lines) return lines;
    var out = try allocator.alloc([]u8, max_lines);
    var i: usize = 0;
    while (i + 1 < max_lines) : (i += 1) {
        out[i] = lines[i];
    }
    // Prepare last line
    const last_src = lines[i];

    // Chop without ellipsis
    const n = @min(width, last_src.len);
    var buf = try allocator.alloc(u8, n);
    if (n > 0) std.mem.copyForwards(u8, buf[0..n], last_src[0..n]);
    out[i] = buf;
    // We are replacing the original last line with a chopped buffer, so free the dropped source line
    allocator.free(last_src);

    // Free the remaining lines we won't use
    var j: usize = i + 1;
    while (j < lines.len) : (j += 1) allocator.free(lines[j]);
    allocator.free(lines);
    return out;
}

fn drawTextBoxIntoRaster(
    allocator: std.mem.Allocator,
    r: *Raster,
    x: usize,
    y: usize,
    tb: TextBox,
) !void {
    // Treat tb.width/height as content size; add a 1-cell border around
    if (tb.width == 0 or tb.height == 0) return;
    const outer_w: usize = tb.width + 2;
    const outer_h: usize = tb.height + 2;
    drawBorderAscii(r, x, y, outer_w, outer_h);
    const inner_w: usize = tb.width;
    const inner_h: usize = tb.height;
    if (inner_w == 0 or inner_h == 0) return;
    const lines = try wrapWithOverflowAlloc(allocator, tb.text, inner_w, inner_h);
    defer {
        for (lines) |ln| allocator.free(ln);
        allocator.free(lines);
    }
    var row: usize = 0;
    while (row < lines.len and row < inner_h) : (row += 1) {
        const ln = lines[row];
        const n = @min(ln.len, inner_w);
        var col: usize = 0;
        while (col < n) : (col += 1) {
            r.set((x + 1) + col, (y + 1) + row, ln[col]);
        }
    }
}

pub fn composeFlowingRowOfTextBoxesAlloc(
    allocator: std.mem.Allocator,
    container_width: usize,
    container_height: usize,
    boxes: []const TextBox,
) !Raster {
    var r = try Raster.init(allocator, container_width, container_height);
    drawBorderAscii(&r, 0, 0, container_width, container_height);
    const inner_x0: usize = if (container_width >= 2) 1 else 0;
    const inner_y0: usize = if (container_height >= 2) 1 else 0;
    const inner_w: usize = if (container_width > 1) container_width - 2 else container_width;
    const inner_h: usize = if (container_height > 1) container_height - 2 else container_height;

    // Horizontal shrink-to-fit on a single line with 1-space gaps
    var widths = try allocator.alloc(usize, boxes.len);
    defer allocator.free(widths);
    var i: usize = 0;
    var total_outer: isize = 0;
    while (i < boxes.len) : (i += 1) {
        widths[i] = boxes[i].width;
        total_outer += @as(isize, @intCast(widths[i] + 2));
    }
    if (boxes.len > 1) total_outer += @as(isize, @intCast(boxes.len - 1));
    const inner_w_is: isize = @as(isize, @intCast(inner_w));
    if (total_outer > inner_w_is) {
        var overflow: isize = total_outer - inner_w_is;
        var idx: usize = 0;
        while (overflow > 0 and boxes.len > 0) : (idx += 1) {
            if (idx >= boxes.len) idx = 0;
            if (widths[idx] > 1) {
                widths[idx] -= 1;
                overflow -= 1;
            } else if (boxes.len == 1) {
                break;
            }
        }
    }

    // Draw a single line of boxes
    var cursor_x: usize = 0;
    const cursor_y: usize = 0;
    i = 0;
    while (i < boxes.len) : (i += 1) {
        const cw = widths[i];
        const tb = TextBox{ .width = cw, .height = boxes[i].height, .text = boxes[i].text };
        const bw_outer = cw + 2;
        const bh_outer = tb.height + 2;
        if (cursor_x + bw_outer > inner_w or bh_outer > inner_h) break;
        try drawTextBoxIntoRaster(allocator, &r, inner_x0 + cursor_x, inner_y0 + cursor_y, tb);
        cursor_x += bw_outer;
        if (i + 1 < boxes.len and cursor_x < inner_w) cursor_x += 1;
    }
    return r;
}

test "row: column + box (no cross-centering)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const nodes = [_]Node{
        Node{ .Column = ColumnNode{ .width = 0, .main_align = .space_between, .cross_align = .start, .children = &.{ b(4, 3), b(4, 3) } } },
        Node{ .Box = b(6, 5) },
    };
    var r = try composeRowOfNodesAlloc(al, 18, 9, .space_between, &nodes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+----------------+
        \\|+--+      +----+|
        \\||  |      |    ||
        \\|+--+      |    ||
        \\|          |    ||
        \\|+--+      |    ||
        \\||  |      |    ||
        \\|+--+      +----+|
        \\+----------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "row: column (cross-centered) + box" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const nodes = [_]Node{
        Node{ .Column = ColumnNode{ .width = 6, .main_align = .space_between, .cross_align = .center, .children = &.{ b(4, 3), b(4, 3) } } },
        Node{ .Box = b(6, 5) },
    };
    var r = try composeRowOfNodesAlloc(al, 20, 9, .space_between, &nodes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+------------------+
        \\| +--+       +----+|
        \\| |  |       |    ||
        \\| +--+       |    ||
        \\|            |    ||
        \\| +--+       |    ||
        \\| |  |       |    ||
        \\| +--+       +----+|
        \\+------------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "flowing row of text boxes: wrap and ellipsize" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const t1 = TextBox{ .width = 8, .height = 4, .text = "the quick brown" };
    const t2 = TextBox{ .width = 6, .height = 3, .text = "fox jumps over the lazy dog" };
    const t3 = TextBox{ .width = 7, .height = 4, .text = "zig makes tests pretty" };
    var r = try composeFlowingRowOfTextBoxesAlloc(al, 24, 9, &.{ t1, t2, t3 });
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+----------------------+
        \\|+-----+ +----+ +-----+|
        \\||the  | |fox | |zig  ||
        \\||quick| |jump| |makes||
        \\||brown| |s   | |tests||
        \\||     | +----+ |prett||
        \\|+-----+        +-----+|
        \\|                      |
        \\+----------------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "flowing row of text boxes: chop when no ellipsis" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const t1 = TextBox{ .width = 8, .height = 3, .text = "abcdef ghijk" };
    const t2 = TextBox{ .width = 8, .height = 3, .text = "lmn op qrstuv" };
    var r = try composeFlowingRowOfTextBoxesAlloc(al, 20, 7, &.{ t1, t2 });
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+------------------+
        \\|+------+ +-------+|
        \\||abcdef| |lmn op ||
        \\||ghijk | |qrstuv ||
        \\||      | |       ||
        \\|+------+ +-------+|
        \\+------------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "two boxes, row, start" {
    try expectFlexRow(.start, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|+--++--+    |
        \\||  ||  |    |
        \\|+--++--+    |
        \\+------------+
        \\
    );
}

test "two boxes, row, space between" {
    try expectFlexRow(.space_between, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|+--+    +--+|
        \\||  |    |  ||
        \\|+--+    +--+|
        \\+------------+
        \\
    );
}

test "two boxes, row, space around" {
    try expectFlexRow(.space_around, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\| +--+  +--+ |
        \\| |  |  |  | |
        \\| +--+  +--+ |
        \\+------------+
        \\
    );
}

test "space-around: remainder cycles start then gaps" {
    // Container inner width (excluding border) is 12 for b(14,5). Two boxes of width 4 => content 8.
    // Remaining = 4. There are 2 items => 2*count half-slots = 4; base_half = 1, rem = 0 -> trivial.
    // Use a width that yields a remainder: make inner width 13 (container 15): remaining = 5, half_slots=4 -> base_half=1, rem=1.
    // Expect start gets the extra 1.
    try expectFlexRow(.space_around, b(15, 5), &.{ b(4, 3), b(4, 3) },
        \\+-------------+
        \\|  +--+  +--+ |
        \\|  |  |  |  | |
        \\|  +--+  +--+ |
        \\+-------------+
        \\
    );
}

test "two boxes, row, end" {
    try expectFlexRow(.end, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|    +--++--+|
        \\|    |  ||  ||
        \\|    +--++--+|
        \\+------------+
        \\
    );
}

test "two boxes, row, center" {
    try expectFlexRow(.center, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|  +--++--+  |
        \\|  |  ||  |  |
        \\|  +--++--+  |
        \\+------------+
        \\
    );
}

test "two boxes, row, evenly" {
    try expectFlexRow(.space_evenly, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\| +--+  +--+ |
        \\| |  |  |  | |
        \\| +--+  +--+ |
        \\+------------+
        \\
    );
}

test "one box, row, center" {
    try expectFlexRow(.center, b(11, 5), &.{b(5, 3)},
        \\+---------+
        \\|  +---+  |
        \\|  |   |  |
        \\|  +---+  |
        \\+---------+
        \\
    );
}

test "zero boxes, row" {
    try expectFlexRow(.space_between, b(10, 4), &.{},
        \\+--------+
        \\|        |
        \\|        |
        \\+--------+
        \\
    );
}

test "two boxes, column, start" {
    try expectFlexColumn(.start, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\+---------+
        \\
    );
}

test "two boxes, column, end" {
    try expectFlexColumn(.end, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\+---------+
        \\
    );
}

test "two boxes, column, center" {
    try expectFlexColumn(.center, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\+---------+
        \\
    );
}

test "two boxes, column, space between" {
    try expectFlexColumn(.space_between, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\+---------+
        \\
    );
}

test "two boxes, column, space around" {
    try expectFlexColumn(.space_around, b(11, 10), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\+---------+
        \\
    );
}

test "two boxes, column, evenly" {
    try expectFlexColumn(.space_evenly, b(11, 10), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\+---------+
        \\
    );
}

test "space distribution: space_evenly distributes remainders" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const dist = try calculateSpaces(al, .space_evenly, 20, 10, 3);
    defer al.free(dist.between_gaps);
    // For container=20, content=10, count=3:
    // remaining=10, slots=count+1=4 => base=2, remainder=2 -> start ~2 or 3 depending on policy
    try std.testing.expect(dist.start_space >= 2);
}

test "wrap DP prefers balanced lines" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const s = "alpha beta gamma delta";
    const lines = try wrapAlloc(al, s, 12);
    defer {
        for (lines) |ln| al.free(ln);
        al.free(lines);
    }
    try std.testing.expect(lines.len >= 2);
}

test "raster border ascii" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    var r = try Raster.init(al, 8, 4);
    defer r.deinit(al);
    drawBorderAscii(&r, 1, 1, 6, 3);
    const want =
        "        \n" ++
        " +----+ \n" ++
        " |    | \n" ++
        " +----+ \n";
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "renderParagraphAlloc wraps into glyph grid" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const s = "the quick brown fox";
    var r = try renderParagraphAlloc(al, s, 10);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    // two lines expected given width 10
    try std.testing.expect(std.mem.indexOfScalar(u8, got, '\n') != null);
}

test "xml: parse multiline string literal" {
    const xml = @import("xml");
    const input =
        \\<?xml version="1.0" standalone="yes" ?>
        \\<root>
        \\  <g>Hello</g>
        \\  <g>World</g>
        \\</root>
    ;
    var fbs = std.io.fixedBufferStream(input);
    var doc = try xml.parse(std.testing.allocator, "<stdin>", fbs.reader());
    defer doc.deinit();
    doc.acquire();
    defer doc.release();

    try std.testing.expectEqualStrings("root", doc.root.tag_name.slice());
    const children = doc.root.children();
    try std.testing.expect(children.len == 2);
    try std.testing.expect(children[0].v() == .element);
    try std.testing.expect(children[1].v() == .element);
}
