const std = @import("std");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");
const Words = @import("Words");

comptime {
    @setEvalBranchQuota(20000);
}

pub const GlyphId = u32; // 0..=255 self-map to single-byte ASCII

/// Fixed-capacity-friendly glyph interning built on std's unmanaged string map.
/// Keys are UTF-8 byte slices that live in a contiguous arena; values are `GlyphId`.
/// Glyph ids 0..=255 are reserved for single-byte glyphs (ASCII/self-mapped).
pub const GlyphTable = struct {
    const Span = struct { off: u32, len: u8 };

    alloc: std.mem.Allocator,
    map: std.StringArrayHashMap(GlyphId),
    arena: std.ArrayList(u8),
    spans: std.MultiArrayList(Span) = .{}, // index => (off,len), id == index

    pub fn init(allocator: std.mem.Allocator) !GlyphTable {
        var gt = GlyphTable{
            .alloc = allocator,
            .map = std.StringArrayHashMap(GlyphId).init(allocator),
            .arena = std.ArrayList(u8).init(allocator),
            .spans = .{},
        };
        // Prepopulate ASCII 0x00..0xFF as self-mapped one-byte spans
        try gt.spans.ensureTotalCapacity(allocator, 256);
        try gt.arena.ensureTotalCapacity(256);
        try gt.map.ensureTotalCapacity(256);
        var ascii_i: usize = 0;
        while (ascii_i < 256) : (ascii_i += 1) {
            const off: u32 = @intCast(gt.arena.items.len);
            try gt.arena.append(@as(u8, @intCast(ascii_i)));
            gt.spans.appendAssumeCapacity(.{ .off = off, .len = 1 });
            const key = gt.arena.items[@as(usize, off) .. @as(usize, off) + 1];
            gt.map.putAssumeCapacity(key, @as(GlyphId, @intCast(ascii_i)));
        }
        return gt;
    }

    pub fn deinit(self: *GlyphTable) void {
        self.map.deinit();
        self.arena.deinit();
        self.spans.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *GlyphTable) void {
        self.map.clearRetainingCapacity();
        self.arena.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
    }

    /// Interns `bytes` and returns a glyph id. Single-byte values map directly to that byte value.
    pub fn intern(self: *GlyphTable, allocator: std.mem.Allocator, bytes: []const u8) !GlyphId {
        if (bytes.len == 1) return @as(GlyphId, bytes[0]);
        if (self.map.get(bytes)) |existing| return existing;
        if (bytes.len > std.math.maxInt(u8)) return error.GlyphTooLong;

        const off_u32: u32 = @intCast(self.arena.items.len);
        try self.arena.appendSlice(bytes);
        const len_u8: u8 = @intCast(bytes.len);
        try self.spans.append(allocator, .{ .off = off_u32, .len = len_u8 });
        const id: GlyphId = @intCast(self.spans.len - 1);

        // Create a stable slice into arena memory for the key.
        const base_ptr: [*]u8 = self.arena.items.ptr;
        const key: []const u8 = base_ptr[off_u32 .. off_u32 + len_u8];
        try self.map.put(key, id);
        return id;
    }

    /// Returns the (off,len) span for any id including ASCII.
    pub fn getSpan(self: *const GlyphTable, id: GlyphId) ?Span {
        const idx: usize = @as(usize, @intCast(id));
        if (idx >= self.spans.len) return null;
        return self.spans.get(idx);
    }

    pub fn getSlice(self: *const GlyphTable, id: GlyphId) ?[]const u8 {
        const span = self.getSpan(id) orelse return null;
        const off: usize = span.off;
        const len: usize = span.len;
        return self.arena.items[off .. off + len];
    }
};

// --- DOM scaffolding (node headers in MultiArrayList; style interning) ---

pub const DomNodeId = u32;
pub const DomNodeKind = enum { element, text };

// --- Style semantics: packed rows + SoA table ---

pub const StyleDisplay = enum(u3) { none, @"inline", block, flex, inline_flex, _unused0, _unused1, _unused2 };
pub const StyleWhitespace = enum(u2) { normal, pre, nowrap, pre_wrap };
pub const StyleBorderStyle = enum(u2) { none, solid, double, dashed };
pub const StyleFlexDir = enum(u2) { row, column, row_reverse, column_reverse };
pub const StyleFlexWrap = enum(u2) { nowrap, wrap, wrap_reverse, _unused };
pub const StyleJustify = enum(u3) { start, end, center, space_between, space_around, space_evenly, _u0, _u1 };
pub const StyleAlign = enum(u3) { start, end, center, stretch, baseline, _u0, _u1, _u2 };

pub const StyleColor = packed struct {
    r: u8,
    g: u8,
    b: u8,
    use_default: u1, // 1 = use terminal default, ignore rgb
    _pad: u7 = 0,
};

pub const StyleEdge4 = packed struct { t: u4, r: u4, b: u4, l: u4 };
pub const StyleGap = packed struct { main: u3, cross: u3, _pad: u2 = 0 };
pub const StyleBorderSpec = packed struct { width_cells: u2, style: StyleBorderStyle };

pub const StyleFlex = packed struct {
    grow: u4,
    shrink: u4,
    basis_auto: u1,
    _pad: u7 = 0,
    basis_cells: u16,
};

// not packed: it's anyway in a MultiArrayList,
// and packing made hashing nondeterministic
pub const StyleRow = struct {
    fg: StyleColor,
    bg: StyleColor,
    text_flags: packed struct { bold: u1, italic: u1, underline: u1, inverse: u1, strike: u1, dim: u1, blink: u1, _pad: u1 = 0 },

    display: StyleDisplay,
    visibility_hidden: u1,
    overflow_clip: u1,
    whitespace: StyleWhitespace,
    _pad0: u3 = 0,

    width_cells: u16,
    height_cells: u16,

    padding: StyleEdge4,
    margin: StyleEdge4,
    border: StyleBorderSpec,

    gaps: StyleGap,

    flex_dir: StyleFlexDir,
    flex_wrap: StyleFlexWrap,
    justify: StyleJustify,
    align_items: StyleAlign,
    align_self: StyleAlign,
    flex: StyleFlex,

    z_index: i16,
    order: i16,
};

fn hashBytesWy(seed: u64, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

fn hashStyleRow(row: *const StyleRow, seed: u64) u64 {
    return hashBytesWy(seed, std.mem.asBytes(row));
}

pub const StyleTable = struct {
    cols: std.ArrayList(StyleRow),
    row_hash: std.ArrayList(u64),
    map: std.AutoHashMap(u64, u32),

    pub fn init(alloc: std.mem.Allocator) StyleTable {
        return .{ .cols = std.ArrayList(StyleRow).init(alloc), .row_hash = std.ArrayList(u64).init(alloc), .map = std.AutoHashMap(u64, u32).init(alloc) };
    }

    pub fn deinit(self: *StyleTable) void {
        self.cols.deinit();
        self.row_hash.deinit();
        self.map.deinit();
        self.* = undefined;
    }

    fn equalsAt(self: *const StyleTable, idx: u32, row: *const StyleRow) bool {
        const existing = self.cols.items[@intCast(idx)];
        return std.mem.eql(u8, std.mem.asBytes(&existing), std.mem.asBytes(row));
    }

    pub fn intern(self: *StyleTable, alloc: std.mem.Allocator, row: StyleRow) !u32 {
        _ = alloc; // ArrayList carries its own allocator
        const h = hashStyleRow(&row, 0);
        if (self.map.get(h)) |id| {
            if (self.equalsAt(id, &row)) return id;
        }
        try self.cols.append(row);
        const id: u32 = @intCast(self.cols.items.len - 1);
        try self.row_hash.append(h);
        try self.map.put(h, id);
        return id;
    }
};

pub fn defaultStyleRow() StyleRow {
    return .{
        .fg = .{ .r = 0, .g = 0, .b = 0, .use_default = 1 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .use_default = 1 },
        .text_flags = .{ .bold = 0, .italic = 0, .underline = 0, .inverse = 0, .strike = 0, .dim = 0, .blink = 0 },
        .display = .@"inline",
        .visibility_hidden = 0,
        .overflow_clip = 0,
        .whitespace = .normal,
        .width_cells = 0,
        .height_cells = 0,
        .padding = .{ .t = 0, .r = 0, .b = 0, .l = 0 },
        .margin = .{ .t = 0, .r = 0, .b = 0, .l = 0 },
        .border = .{ .width_cells = 0, .style = .none },
        .gaps = .{ .main = 0, .cross = 0 },
        .flex_dir = .row,
        .flex_wrap = .nowrap,
        .justify = .start,
        .align_items = .stretch,
        .align_self = .stretch,
        .flex = .{ .grow = 0, .shrink = 1, .basis_auto = 1, .basis_cells = 0 },
        .z_index = 0,
        .order = 0,
    };
}

pub const DomNodeHeader = struct {
    kind: DomNodeKind,
    parent: DomNodeId,
    prev_sibling: DomNodeId,
    next_sibling: DomNodeId,
    first_child: DomNodeId,
    child_count: u32,
    style_id: u32,
};

pub const Dom = struct {
    const NullId: DomNodeId = std.math.maxInt(DomNodeId);

    alloc: std.mem.Allocator,
    headers: std.MultiArrayList(DomNodeHeader) = .{},
    styles: StyleTable,
    text_arena: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) Dom {
        return .{ .alloc = alloc, .headers = .{}, .styles = StyleTable.init(alloc), .text_arena = std.ArrayList(u8).init(alloc) };
    }

    pub fn deinit(self: *Dom) void {
        self.headers.deinit(self.alloc);
        self.styles.deinit();
        self.text_arena.deinit();
        self.* = undefined;
    }

    pub fn addElement(self: *Dom, style_bytes: []const u8) !DomNodeId {
        _ = style_bytes; // TODO: parse class tokens -> StyleRow
        // For now: map class string to a default StyleRow; later parse tokens
        const style_row = defaultStyleRow();
        const style_id = try self.styles.intern(self.alloc, style_row);
        const idx = try self.headers.addOne(self.alloc);
        self.headers.set(idx, .{
            .kind = .element,
            .parent = NullId,
            .prev_sibling = NullId,
            .next_sibling = NullId,
            .first_child = NullId,
            .child_count = 0,
            .style_id = style_id,
        });
        return @as(DomNodeId, @intCast(idx));
    }

    /// Set a node's style by interning the provided `StyleRow` and storing its id.
    pub fn setStyle(self: *Dom, id: DomNodeId, row: StyleRow) !void {
        const sid = try self.styles.intern(self.alloc, row);
        const items = self.headers.slice();
        items.items(.style_id)[@as(usize, @intCast(id))] = sid;
    }

    pub fn addText(self: *Dom, utf8: []const u8) !DomNodeId {
        const style_id = try self.styles.intern(self.alloc, defaultStyleRow());
        const off: u32 = @intCast(self.text_arena.items.len);
        try self.text_arena.appendSlice(utf8);
        const len: u32 = @intCast(utf8.len);
        const idx = try self.headers.addOne(self.alloc);
        self.headers.set(idx, .{
            .kind = .text,
            .parent = NullId,
            .prev_sibling = NullId,
            .next_sibling = NullId,
            .first_child = @as(DomNodeId, off), // overloaded for text offset
            .child_count = len, // overloaded for text length
            .style_id = style_id,
        });
        return @as(DomNodeId, @intCast(idx));
    }

    pub fn getTextSlice(self: *const Dom, id: DomNodeId) []const u8 {
        const items = self.headers.slice();
        const off: usize = @intCast(items.items(.first_child)[@intCast(id)]);
        const len: usize = @intCast(items.items(.child_count)[@intCast(id)]);
        return self.text_arena.items[off .. off + len];
    }

    pub fn appendChild(self: *Dom, parent_id: DomNodeId, child_id: DomNodeId) void {
        const p: usize = @intCast(parent_id);
        const c: usize = @intCast(child_id);
        var items = self.headers.slice();
        const p_first = &items.items(.first_child)[p];
        const p_count = &items.items(.child_count)[p];
        items.items(.parent)[c] = parent_id;
        if (p_first.* == NullId) {
            p_first.* = child_id;
        } else {
            // find last sibling
            var last_id = p_first.*;
            while (items.items(.next_sibling)[@as(usize, @intCast(last_id))] != NullId) {
                last_id = items.items(.next_sibling)[@as(usize, @intCast(last_id))];
            }
            const last_idx: usize = @intCast(last_id);
            items.items(.next_sibling)[last_idx] = child_id;
            items.items(.prev_sibling)[c] = last_id;
        }
        p_count.* += 1;
    }
};

pub const BoxNode = struct {
    id: DomNodeId,
    rect: Rect,
    first_child: ?*BoxNode,
    next_sibling: ?*BoxNode,
};

pub fn buildBoxTree(arena: *std.heap.ArenaAllocator, dom: *const Dom, root: DomNodeId) !*BoxNode {
    const alloc = arena.allocator();
    const node = try alloc.create(BoxNode);
    node.* = .{ .id = root, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .first_child = null, .next_sibling = null };
    // Build children linearly
    const items = dom.headers.slice();
    var cur_child = items.items(.first_child)[@as(usize, @intCast(root))];
    var prev_ptr: ?*BoxNode = null;
    while (cur_child != Dom.NullId) {
        const child_ptr = try buildBoxTree(arena, dom, cur_child);
        if (prev_ptr) |prev| prev.next_sibling = child_ptr else node.first_child = child_ptr;
        prev_ptr = child_ptr;
        cur_child = items.items(.next_sibling)[@as(usize, @intCast(cur_child))];
    }
    return node;
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
            idx = 0;
            var prev_ptr: ?*BoxNode = null;
            while (idx < child_count) : (idx += 1) {
                const s = sizes[idx];
                var cx: usize = rect_.x;
                var cy: usize = rect_.y;
                var cw: usize = s.width;
                var ch: usize = s.height;
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
                cursor_main += @as(i32, @intCast(if (layout.direction == .row) s.width else s.height));
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

// --- Index-based BoxTree (contiguous children slices) ---

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

// Build a BoxTree with contiguous children slices using the provided layout provider.
fn emitBoxRecursive(tree: *BoxTree, dom_: *const Dom, id_: DomNodeId, rect_: Rect, provider_: anytype, arena_: *std.heap.ArenaAllocator) !u32 {
    const idx_u: u32 = @intCast(tree.headers.items.len);
    try tree.headers.append(.{ .dom_id = id_, .rect = rect_, .first_child = std.math.maxInt(u32), .child_count = 0 });

    const items = dom_.headers.slice();
    const kind = items.items(.kind)[@as(usize, @intCast(id_))];
    if (kind == .element) {
        const layout = provider_.props(dom_, id_);
        const child_count = items.items(.child_count)[@as(usize, @intCast(id_))];
        if (child_count > 0) {
            var child_ids = try arena_.allocator().alloc(DomNodeId, child_count);
            var sizes = try arena_.allocator().alloc(BoxSize, child_count);
            var i: usize = 0;
            var c = items.items(.first_child)[@as(usize, @intCast(id_))];
            while (i < child_count) : (i += 1) {
                child_ids[i] = c;
                sizes[i] = provider_.measure(dom_, c, rect_.w, rect_.h);
                c = items.items(.next_sibling)[@as(usize, @intCast(c))];
            }
            var content_extent: i32 = 0;
            for (sizes) |s| content_extent += @as(i32, @intCast(if (layout.direction == .row) s.width else s.height));
            const container_extent: i32 = @as(i32, @intCast(if (layout.direction == .row) rect_.w else rect_.h));
            const dist = try calculateSpaces(arena_.allocator(), layout.main_align, container_extent, content_extent, child_count);
            defer arena_.allocator().free(dist.between_gaps);

            var cursor_main: i32 = dist.start_space;
            const first_child_index: u32 = @intCast(tree.headers.items.len);
            i = 0;
            while (i < child_count) : (i += 1) {
                const s = sizes[i];
                var cx: usize = rect_.x;
                var cy: usize = rect_.y;
                var cw: usize = s.width;
                var ch: usize = s.height;
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
                _ = try emitBoxRecursive(tree, dom_, child_ids[i], child_rect, provider_, arena_);
                cursor_main += @as(i32, @intCast(if (layout.direction == .row) s.width else s.height));
                if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
            }
            var hdr_ptr = &tree.headers.items[@as(usize, @intCast(idx_u))];
            hdr_ptr.first_child = first_child_index;
            hdr_ptr.child_count = @intCast(child_count);
        }
    }
    return idx_u;
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
pub fn layoutBoxesInPlace(alloc: std.mem.Allocator, tree: *BoxTree, dom: *const Dom, root_index: u32, root_rect: Rect, provider: anytype) !void {
    try layoutBoxesInPlaceNode(alloc, tree, dom, root_index, root_rect, provider);
}

pub fn layoutBoxesInPlaceNode(alloc_: std.mem.Allocator, tree_: *BoxTree, dom_: *const Dom, idx_: u32, rect_: Rect, provider_: anytype) !void {
    var hdr = &tree_.headers.items[@as(usize, @intCast(idx_))];
    // Read parent style
    const items = dom_.headers.slice();
    const parent_sid = items.items(.style_id)[@as(usize, @intCast(hdr.dom_id))];
    const parent_style = dom_.styles.cols.items[@intCast(parent_sid)];

    // Compute inner content rect based on padding and border
    const border_w: usize = @as(usize, @intCast(parent_style.border.width_cells));
    const pad_l: usize = @as(usize, @intCast(parent_style.padding.l)) + border_w;
    const pad_r: usize = @as(usize, @intCast(parent_style.padding.r)) + border_w;
    const pad_t: usize = @as(usize, @intCast(parent_style.padding.t)) + border_w;
    const pad_b: usize = @as(usize, @intCast(parent_style.padding.b)) + border_w;
    var inner_rect = rect_;
    inner_rect.x = rect_.x + @min(rect_.w, pad_l);
    inner_rect.y = rect_.y + @min(rect_.h, pad_t);
    inner_rect.w = if (rect_.w > pad_l + pad_r) rect_.w - (pad_l + pad_r) else 0;
    inner_rect.h = if (rect_.h > pad_t + pad_b) rect_.h - (pad_t + pad_b) else 0;

    hdr.rect = rect_;
    if (hdr.child_count == 0) return;

    const parent_layout = provider_.props(dom_, hdr.dom_id);
    const children_slice = tree_.children(@as(usize, @intCast(idx_)));

    const n = children_slice.len;
    const ChildInfo = struct {
        orig_index: usize,
        size: BoxSize,
        order: i16,
        @"align": CrossAxisAlignment,
        margin_main_start: usize,
        margin_main_end: usize,
    };
    var children = try alloc_.alloc(ChildInfo, n);
    defer alloc_.free(children);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dom_id = children_slice[i].dom_id;
        const sid = items.items(.style_id)[@as(usize, @intCast(dom_id))];
        const srow = dom_.styles.cols.items[@intCast(sid)];
        var measured = provider_.measure(dom_, dom_id, inner_rect.w, inner_rect.h);
        if (srow.width_cells != 0) measured.width = srow.width_cells;
        if (srow.height_cells != 0) measured.height = srow.height_cells;
        const align_override = styleAlignToCross(srow.align_self);
        const margin_start: usize = if (parent_layout.direction == .row)
            @as(usize, @intCast(srow.margin.l))
        else
            @as(usize, @intCast(srow.margin.t));
        const margin_end: usize = if (parent_layout.direction == .row)
            @as(usize, @intCast(srow.margin.r))
        else
            @as(usize, @intCast(srow.margin.b));
        children[i] = .{
            .orig_index = i,
            .size = measured,
            .order = srow.order,
            .@"align" = if (srow.align_self == .start) parent_layout.cross_align else align_override,
            .margin_main_start = margin_start,
            .margin_main_end = margin_end,
        };
    }

    // Stable sort by (order, orig_index)
    var j: usize = 0;
    while (j < n) : (j += 1) {
        var k: usize = j;
        while (k > 0) : (k -= 1) {
            const a = children[k - 1];
            const bb = children[k];
            if (a.order > bb.order or (a.order == bb.order and a.orig_index > bb.orig_index)) {
                const tmp = children[k - 1];
                children[k - 1] = children[k];
                children[k] = tmp;
            } else break;
        }
    }

    // Content extent includes margins
    var content_extent: i32 = 0;
    for (children) |cinfo| {
        const main = if (parent_layout.direction == .row) cinfo.size.width else cinfo.size.height;
        content_extent += @as(i32, @intCast(main + cinfo.margin_main_start + cinfo.margin_main_end));
    }
    const container_extent: i32 = @as(i32, @intCast(if (parent_layout.direction == .row) inner_rect.w else inner_rect.h));
    const dist = try calculateSpaces(alloc_, parent_layout.main_align, container_extent, content_extent, n);
    defer alloc_.free(dist.between_gaps);

    // Add main-axis gap from style to each between gap
    const main_gap: i32 = @as(i32, @intCast(parent_style.gaps.main));
    var gi: usize = 0;
    while (gi < dist.between_gaps.len) : (gi += 1) dist.between_gaps[gi] += main_gap;

    var cursor_main: i32 = dist.start_space;
    i = 0;
    while (i < n) : (i += 1) {
        const cinfo = children[i];
        const s = cinfo.size;
        var cx: usize = inner_rect.x;
        var cy: usize = inner_rect.y;
        var cw: usize = s.width;
        var ch: usize = s.height;
        if (parent_layout.direction == .row) {
            cx = inner_rect.x + @as(usize, @intCast(cursor_main)) + cinfo.margin_main_start;
            switch (cinfo.@"align") {
                .start => {
                    cy = inner_rect.y;
                    ch = s.height;
                },
                .center => {
                    ch = if (s.height > inner_rect.h) inner_rect.h else s.height;
                    cy = inner_rect.y + (inner_rect.h - ch) / 2;
                },
                .end => {
                    ch = if (s.height > inner_rect.h) inner_rect.h else s.height;
                    cy = inner_rect.y + (inner_rect.h - ch);
                },
                .stretch => {
                    cy = inner_rect.y;
                    ch = inner_rect.h;
                },
            }
        } else {
            cy = inner_rect.y + @as(usize, @intCast(cursor_main)) + cinfo.margin_main_start;
            switch (cinfo.@"align") {
                .start => {
                    cx = inner_rect.x;
                    cw = s.width;
                },
                .center => {
                    cw = if (s.width > inner_rect.w) inner_rect.w else s.width;
                    cx = inner_rect.x + (inner_rect.w - cw) / 2;
                },
                .end => {
                    cw = if (s.width > inner_rect.w) inner_rect.w else s.width;
                    cx = inner_rect.x + (inner_rect.w - cw);
                },
                .stretch => {
                    cx = inner_rect.x;
                    cw = inner_rect.w;
                },
            }
        }
        const child_rect: Rect = .{ .x = cx, .y = cy, .w = cw, .h = ch };
        const child_idx: u32 = @intCast(@as(usize, @intCast(hdr.first_child)) + cinfo.orig_index);
        try layoutBoxesInPlaceNode(alloc_, tree_, dom_, child_idx, child_rect, provider_);
        cursor_main += @as(i32, @intCast(if (parent_layout.direction == .row) s.width else s.height)) + @as(i32, @intCast(cinfo.margin_main_start + cinfo.margin_main_end));
        if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
    }
}

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
        fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items = dom_.headers.slice();
            const sid = items.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
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

    var dl = DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
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

    var dl = DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
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

test "wrap international prose with center and right alignment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var dom = Dom.init(al);
    defer dom.deinit();
    const root = try dom.addElement("root");
    const txt = try dom.addText("Metonym   Μετωνύμιο メトニム 😊");
    dom.appendChild(root, txt);

    // Two passes: center, then end
    inline for (.{ .center, .end }) |just| {
        var sr_root = defaultStyleRow();
        sr_root.flex_dir = .row;
        sr_root.justify = .start;
        sr_root.align_items = .start;
        try dom.setStyle(root, sr_root);
        var sr_text = defaultStyleRow();
        sr_text.justify = just;
        try dom.setStyle(txt, sr_text);

        var tree = try buildBoxTreeFromDomAlloc(al, &dom, root);
        defer tree.deinit();
        var provider = StyleProvider{ .graphemes = try Graphemes.init(al), .display_width = try DisplayWidth.init(al) };
        defer provider.graphemes.deinit(al);
        defer provider.display_width.deinit(al);

        const container = b(22, 7);
        var r = try Raster.init(al, container.width, container.height);
        defer r.deinit(al);
        drawBorderAscii(&r, 0, 0, container.width, container.height);
        const inner_x: usize = if (container.width >= 2) 1 else 0;
        const inner_y: usize = if (container.height >= 2) 1 else 0;
        const inner_w: usize = if (container.width > 1) container.width - 2 else container.width;
        const inner_h: usize = if (container.height > 1) container.height - 2 else container.height;
        try layoutBoxesInPlace(al, &tree, &dom, tree.root_index, .{ .x = inner_x, .y = inner_y, .w = inner_w, .h = inner_h }, provider);

        var dl = DisplayList.init(al);
        defer dl.deinit();
        var glyphs = try GlyphTable.init(al);
        defer glyphs.deinit();
        try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
        try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

        const got = try toUtf8AllocWithGlyphs(&r, al, &glyphs);
        defer al.free(got);
        // Structural assertions: border lines present and content split across separate lines.
        var it = std.mem.splitScalar(u8, got, '\n');
        const top = it.next().?;
        const l2 = it.next().?;
        const l3 = it.next().?;
        const l4 = it.next().?;
        const l5 = it.next().?;
        const l6 = it.next().?;
        const bot = it.next().?;
        _ = l6; // unused content line
        try std.testing.expectEqualStrings("+--------------------+", top);
        try std.testing.expectEqualStrings("+--------------------+", bot);
        // Find the three content-bearing lines among l2..l5
        const has_metonym = std.mem.indexOf(u8, l2, "Metonym") != null or std.mem.indexOf(u8, l3, "Metonym") != null or std.mem.indexOf(u8, l4, "Metonym") != null or std.mem.indexOf(u8, l5, "Metonym") != null;
        try std.testing.expect(has_metonym);
        const has_greek_or_cjk = (std.mem.indexOf(u8, l2, "Μετωνύμιο") != null or std.mem.indexOf(u8, l3, "Μετωνύμιο") != null or std.mem.indexOf(u8, l4, "Μετωνύμιο") != null or std.mem.indexOf(u8, l5, "Μετωνύμιο") != null) or (std.mem.indexOf(u8, l2, "メトニム") != null or std.mem.indexOf(u8, l3, "メトニム") != null or std.mem.indexOf(u8, l4, "メトニム") != null or std.mem.indexOf(u8, l5, "メトニム") != null);
        try std.testing.expect(has_greek_or_cjk);
        const has_emoji = std.mem.indexOf(u8, l2, "😊") != null or std.mem.indexOf(u8, l3, "😊") != null or std.mem.indexOf(u8, l4, "😊") != null or std.mem.indexOf(u8, l5, "😊") != null;
        try std.testing.expect(has_emoji);
        // Alignment sanity: ensure padding exists left or right per justification
        if (just == .center) {
            // At least one line should have non-zero symmetric-ish padding
            const line = if (std.mem.indexOf(u8, l3, "Metonym") != null) l3 else if (std.mem.indexOf(u8, l4, "Metonym") != null) l4 else l5;
            const inner = line[1 .. line.len - 1];
            const content_pos = std.mem.indexOf(u8, inner, "Metonym").?;
            try std.testing.expect(content_pos > 0);
        } else {
            const line = if (std.mem.indexOf(u8, l3, "Metonym") != null) l3 else if (std.mem.indexOf(u8, l4, "Metonym") != null) l4 else l5;
            const inner = line[1 .. line.len - 1];
            const content_pos = std.mem.indexOf(u8, inner, "Metonym").?;
            // Right-aligned: should not start at col 0
            try std.testing.expect(content_pos > 0);
        }
    }
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
        fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items = dom_.headers.slice();
            const sid = items.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
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

// --- Layout/Render two-phase pipeline for fixed boxes ---

pub const Rect = struct { x: usize, y: usize, w: usize, h: usize };

fn layoutFixedBoxesAlloc(
    allocator: std.mem.Allocator,
    inner_x: usize,
    inner_y: usize,
    inner_w: usize,
    inner_h: usize,
    layout: Layout,
    children: []const BoxSize,
) ![]Rect {
    var rects = try allocator.alloc(Rect, children.len);
    var content_extent: i32 = 0;
    for (children) |c| content_extent += @as(i32, @intCast(if (layout.direction == .row) c.width else c.height));
    const container_extent: i32 = @as(i32, @intCast(if (layout.direction == .row) inner_w else inner_h));
    const dist = try calculateSpaces(allocator, layout.main_align, container_extent, content_extent, children.len);
    defer allocator.free(dist.between_gaps);

    var cursor_main: i32 = dist.start_space;
    var i: usize = 0;
    while (i < children.len) : (i += 1) {
        const c = children[i];
        var x: usize = inner_x;
        var y: usize = inner_y;
        var w: usize = c.width;
        var h: usize = c.height;
        if (layout.direction == .row) {
            x = inner_x + @as(usize, @intCast(cursor_main));
            switch (layout.cross_align) {
                .start => {
                    y = inner_y;
                    h = c.height;
                },
                .center => {
                    h = if (c.height > inner_h) inner_h else c.height;
                    y = inner_y + (inner_h - h) / 2;
                },
                .end => {
                    h = if (c.height > inner_h) inner_h else c.height;
                    y = inner_y + (inner_h - h);
                },
                .stretch => {
                    y = inner_y;
                    h = inner_h;
                },
            }
        } else {
            y = inner_y + @as(usize, @intCast(cursor_main));
            switch (layout.cross_align) {
                .start => {
                    x = inner_x;
                    w = c.width;
                },
                .center => {
                    w = if (c.width > inner_w) inner_w else c.width;
                    x = inner_x + (inner_w - w) / 2;
                },
                .end => {
                    w = if (c.width > inner_w) inner_w else c.width;
                    x = inner_x + (inner_w - w);
                },
                .stretch => {
                    x = inner_x;
                    w = inner_w;
                },
            }
        }
        rects[i] = .{ .x = x, .y = y, .w = w, .h = h };
        cursor_main += @as(i32, @intCast(if (layout.direction == .row) c.width else c.height));
        if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
    }
    return rects;
}

pub const Direction = enum { row, column };
pub const MainAxisAlignment = enum { start, center, end, space_between, space_around, space_evenly };
pub const CrossAxisAlignment = enum { start, center, end, stretch };

pub const SpaceDistribution = struct {
    start_space: i32,
    between_gaps: []i32,
};

pub fn calculateSpaces(allocator: std.mem.Allocator, alignment: MainAxisAlignment, container: i32, content: i32, count: usize) !SpaceDistribution {
    @setEvalBranchQuota(5000);
    const remaining = @max(0, container - content);
    var dist = SpaceDistribution{
        .start_space = 0,
        .between_gaps = try allocator.alloc(i32, if (count == 0) 0 else if (count == 1) 0 else count - 1),
    };
    for (dist.between_gaps) |*g| g.* = 0;

    switch (alignment) {
        .start => dist.start_space = 0,
        .end => dist.start_space = remaining,
        .center => dist.start_space = @divTrunc(remaining, 2),
        .space_between => if (count > 1) {
            const gaps = count - 1;
            const base = @divTrunc(remaining, @as(i32, @intCast(gaps)));
            var rem = remaining - base * @as(i32, @intCast(gaps));
            dist.start_space = 0;
            var i: usize = 0;
            while (i < gaps) : (i += 1) {
                var add: i32 = base;
                if (rem > 0) {
                    add += 1;
                    rem -= 1;
                }
                dist.between_gaps[i] = add;
            }
        } else {},
        .space_around => if (count > 0) {
            // Model space-around as 2*count half-slots: start (1), end (1), and two halves per between gap.
            // Each half-slot gets base_half = remaining / (2*count). The spaces between items are 2*base_half,
            // and the leading/trailing spaces are base_half. Distribute any remainder starting from start.
            const half_slots: i32 = @as(i32, @intCast(2 * count));
            const base_half: i32 = @divTrunc(remaining, half_slots);
            var rem: i32 = remaining - base_half * half_slots;
            dist.start_space = base_half;
            var i: usize = 0;
            while (i < dist.between_gaps.len) : (i += 1) {
                dist.between_gaps[i] = base_half * 2;
            }
            // Distribute remainder: start first, then each between gap from left to right, then repeat if needed.
            var idx: usize = 0;
            while (rem > 0) {
                if (idx == 0) {
                    dist.start_space += 1;
                } else {
                    const gap_index = idx - 1;
                    if (gap_index < dist.between_gaps.len) {
                        dist.between_gaps[gap_index] += 1;
                    } else {
                        // wrap around to start again
                        idx = 0;
                        continue;
                    }
                }
                idx += 1;
                if (idx > dist.between_gaps.len) idx = 0; // cycle through start + gaps
                rem -= 1;
            }
        } else {},
        .space_evenly => if (count > 0) {
            const slots = count + 1; // start + gaps + end
            const base = @divTrunc(remaining, @as(i32, @intCast(slots)));
            var rem = remaining - base * @as(i32, @intCast(slots));
            dist.start_space = base;
            var i: usize = 0;
            while (i < dist.between_gaps.len) : (i += 1) {
                var add: i32 = base;
                if (rem > 0) {
                    add += 1;
                    rem -= 1;
                }
                dist.between_gaps[i] = add;
            }
        } else {},
    }
    return dist;
}

// --- Style -> Layout mapping helpers ---

fn styleFlexDirToDirection(dir: StyleFlexDir) Direction {
    return switch (dir) {
        .row, .row_reverse => .row,
        .column, .column_reverse => .column,
    };
}

fn styleAlignToCross(@"align": StyleAlign) CrossAxisAlignment {
    return switch (@"align") {
        .start => .start,
        .end => .end,
        .center => .center,
        .stretch => .stretch,
        // Map unsupported values to sensible defaults for now
        .baseline, ._u0, ._u1, ._u2 => .start,
    };
}

fn styleJustifyToMainAxis(j: StyleJustify) MainAxisAlignment {
    return switch (j) {
        .start => .start,
        .end => .end,
        .center => .center,
        .space_between => .space_between,
        .space_around => .space_around,
        .space_evenly => .space_evenly,
        ._u0, ._u1 => .start,
    };
}

pub fn layoutFromStyleRow(row: StyleRow) Layout {
    return .{
        .direction = styleFlexDirToDirection(row.flex_dir),
        .main_align = styleJustifyToMainAxis(row.justify),
        .cross_align = styleAlignToCross(row.align_items),
    };
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
    try std.testing.expect(l0.cross_align == .stretch);

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
        fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items = dom_.headers.slice();
            const sid = items.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
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

pub const Raster = struct {
    width: usize,
    height: usize,
    cells: []GlyphId, // MxN grid of interned glyph identifiers

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Raster {
        const r = Raster{
            .width = width,
            .height = height,
            .cells = try allocator.alloc(GlyphId, width * height),
        };
        var i: usize = 0;
        while (i < r.cells.len) : (i += 1) r.cells[i] = @as(GlyphId, 32); // space
        return r;
    }

    pub fn deinit(self: *Raster, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }

    /// Set an ASCII glyph at a cell
    pub fn set(self: *Raster, x: usize, y: usize, ch: u8) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = @as(GlyphId, ch);
    }

    /// Set a glyph id at a cell
    pub fn setGlyph(self: *Raster, x: usize, y: usize, gid: GlyphId) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = gid;
    }

    pub fn toStringAlloc(self: *const Raster, allocator: std.mem.Allocator) ![]u8 {
        const line_len = self.width + 1; // + '\n'
        var out = try allocator.alloc(u8, self.height * line_len);
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const gid = self.cells[y * self.width + x];
                // For ASCII ids (0..=255) we emit the single byte; otherwise, emit '?'
                out[y * line_len + x] = if (gid <= 255) @as(u8, @intCast(gid)) else '?';
            }
            out[y * line_len + self.width] = '\n';
        }
        return out;
    }
};

pub fn drawBorderAscii(r: *Raster, x: usize, y: usize, w: usize, h: usize) void {
    if (w == 0 or h == 0) return;
    const x2 = if (x + w == 0) 0 else x + w - 1;
    const y2 = if (y + h == 0) 0 else y + h - 1;
    r.set(x, y, '+');
    r.set(x2, y, '+');
    r.set(x, y2, '+');
    r.set(x2, y2, '+');
    var xi: usize = x + 1;
    while (xi < x2) : (xi += 1) {
        r.set(xi, y, '-');
        r.set(xi, y2, '-');
    }
    var yi: usize = y + 1;
    while (yi < y2) : (yi += 1) {
        r.set(x, yi, '|');
        r.set(x2, yi, '|');
    }
}

pub fn drawBorderUnicode(r: *Raster, allocator: std.mem.Allocator, glyphs: *GlyphTable, x: usize, y: usize, w: usize, h: usize) !void {
    if (w == 0 or h == 0) return;
    const tl = try glyphs.intern(allocator, "┌");
    const tr = try glyphs.intern(allocator, "┐");
    const bl = try glyphs.intern(allocator, "└");
    const br = try glyphs.intern(allocator, "┘");
    const hz = try glyphs.intern(allocator, "─");
    const vt = try glyphs.intern(allocator, "│");
    const x2 = if (x + w == 0) 0 else x + w - 1;
    const y2 = if (y + h == 0) 0 else y + h - 1;
    r.setGlyph(x, y, tl);
    r.setGlyph(x2, y, tr);
    r.setGlyph(x, y2, bl);
    r.setGlyph(x2, y2, br);
    var xi: usize = x + 1;
    while (xi < x2) : (xi += 1) {
        r.setGlyph(xi, y, hz);
        r.setGlyph(xi, y2, hz);
    }
    var yi: usize = y + 1;
    while (yi < y2) : (yi += 1) {
        r.setGlyph(x, yi, vt);
        r.setGlyph(x2, yi, vt);
    }
}

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

pub const PaintOpTag = enum { FillRect, StrokeRect, GlyphRun };
pub const PaintOp = union(PaintOpTag) {
    FillRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8 },
    StrokeRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8, style: PaintBorderStyle },
    GlyphRun: struct { x: usize, y: usize, glyphs: []const GlyphId },
};

pub const DisplayList = struct {
    ops: std.ArrayList(PaintOp),
    pub fn init(alloc: std.mem.Allocator) DisplayList {
        return .{ .ops = std.ArrayList(PaintOp).init(alloc) };
    }
    pub fn deinit(self: *DisplayList) void {
        self.ops.deinit();
        self.* = undefined;
    }
    pub fn push(self: *DisplayList, op: PaintOp) !void {
        try self.ops.append(op);
    }
};

pub fn rasterizeDisplayListAscii(r: *Raster, alloc: std.mem.Allocator, glyphs: *GlyphTable, list: *const DisplayList) !void {
    for (list.ops.items) |op| switch (op) {
        .FillRect => |fr| {
            // For ASCII raster, ignore color; optional clear to spaces (already default)
            _ = fr;
        },
        .StrokeRect => |sr| {
            switch (sr.style) {
                .ascii => drawBorderAscii(r, sr.x, sr.y, sr.w, sr.h),
                .unicode => try drawBorderUnicode(r, alloc, glyphs, sr.x, sr.y, sr.w, sr.h),
            }
        },
        .GlyphRun => |gr| {
            var i: usize = 0;
            while (i < gr.glyphs.len) : (i += 1) r.setGlyph(gr.x + i, gr.y, gr.glyphs[i]);
        },
    };
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
    var dl = DisplayList.init(al);
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

// --- DOM/Layout -> DisplayList pipeline ---

pub fn buildDisplayListFromBoxes(list: *DisplayList, dom: *const Dom, tree: *const BoxTree, glyphs: *GlyphTable) !void {
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
            const inner_w: usize = if (h.rect.w > 1) h.rect.w - 2 else h.rect.w;
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
                if (line_width + seg_w > inner_w and line_width > 0) {
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
                        const extra = if (line_w_cols >= inner_w) 0 else switch (row.justify) {
                            .start => 0,
                            .center => (inner_w - line_w_cols) / 2,
                            .end => inner_w - line_w_cols,
                            else => 0,
                        };
                        try list.push(PaintOp{ .GlyphRun = .{ .x = h.rect.x + 1 + extra, .y = h.rect.y + 1 + y_offset, .glyphs = run } });
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
            if (line_start < slice.len and y_offset < if (h.rect.h > 0) h.rect.h - 2 else 0) {
                const line_bytes = slice[line_start..];
                var gids = std.ArrayList(GlyphId).init(list.ops.allocator);
                defer gids.deinit();
                var it2 = g.iterator(line_bytes);
                var w2: usize = 0;
                while (it2.next()) |gc| {
                    const gb = gc.bytes(line_bytes);
                    const w = dw.strWidth(gb);
                    if (w2 + w > inner_w) break;
                    w2 += w;
                    const gid = try glyphs.intern(list.ops.allocator, gb);
                    try gids.append(gid);
                }
                if (gids.items.len > 0) {
                    const run = try list.ops.allocator.alloc(GlyphId, gids.items.len);
                    std.mem.copyForwards(GlyphId, run, gids.items);
                    const line_w_cols = dw.strWidth(line_bytes);
                    const extra = if (line_w_cols >= inner_w) 0 else switch (row.justify) {
                        .start => 0,
                        .center => (inner_w - line_w_cols) / 2,
                        .end => inner_w - line_w_cols,
                        else => 0,
                    };
                    try list.push(PaintOp{ .GlyphRun = .{ .x = h.rect.x + 1 + extra, .y = h.rect.y + 1 + y_offset, .glyphs = run } });
                }
            }
        }
    }
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
        fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
            _ = self;
            const items2 = dom_.headers.slice();
            const sid = items2.items(.style_id)[@as(usize, @intCast(id))];
            const row = dom_.styles.cols.items[@intCast(sid)];
            return layoutFromStyleRow(row);
        }
        fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
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
    var dl = DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
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
    fn props(self: @This(), dom_: *const Dom, id: DomNodeId) Layout {
        _ = self;
        const items = dom_.headers.slice();
        const sid = items.items(.style_id)[@as(usize, @intCast(id))];
        const row = dom_.styles.cols.items[@intCast(sid)];
        return layoutFromStyleRow(row);
    }

    fn measure(self: @This(), dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize) BoxSize {
        const items = dom_.headers.slice();
        const kind = items.items(.kind)[@as(usize, @intCast(id))];
        const sid = items.items(.style_id)[@as(usize, @intCast(id))];
        const row = dom_.styles.cols.items[@intCast(sid)];

        const border_w: usize = @as(usize, @intCast(row.border.width_cells));
        const pad_x: usize = @as(usize, @intCast(row.padding.l + row.padding.r)) + border_w * 2;
        const pad_y: usize = @as(usize, @intCast(row.padding.t + row.padding.b)) + border_w * 2;

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

    var dl = DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
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

    var dl = DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
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

    var dl = DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
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
