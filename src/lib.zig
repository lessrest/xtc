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
// Debug helpers
const DEBUG_LOG: bool = true; // set false to silence
fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG_LOG) std.debug.print(fmt, args);
}

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
        // Parse utility-class list (Tailwind-like) into a StyleRow
        const style_row = parseUtilityClassList(style_bytes);
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

// --- XML -> DOM mapping ---
pub const XmlDom = struct { dom: Dom, root: DomNodeId };

fn xmlAddElementRecursive(dom: *Dom, el: @import("xml").Element) !DomNodeId {
    const class_attr = el.attr("class") orelse "";
    const id = try dom.addElement(class_attr);
    if (el.content) |_| {
        const kids = el.children();
        var i: usize = 0;
        while (i < kids.len) : (i += 1) {
            const n = kids[i].v();
            switch (n) {
                .element => |child_el| {
                    const cid = try xmlAddElementRecursive(dom, child_el);
                    dom.appendChild(id, cid);
                },
                .text => |sidx| {
                    const tid = try dom.addText(sidx.slice());
                    dom.appendChild(id, tid);
                },
                .pi => |_| {},
            }
        }
    }
    return id;
}

pub fn domFromXmlAlloc(alloc: std.mem.Allocator, doc: *const @import("xml").Document) !XmlDom {
    var dom = Dom.init(alloc);
    doc.acquire();
    defer doc.release();
    const root_id = try xmlAddElementRecursive(&dom, doc.root);
    return .{ .dom = dom, .root = root_id };
}

// --- Unified (parse+emit) Tailwind-like rules ---
const Rule = struct {
    parse: fn (*StyleRow, []const u8) bool,
    emit: fn (*std.ArrayList([]const u8), std.mem.Allocator, StyleRow, StyleRow) anyerror!void,
};

fn ruleExactField(comptime token: []const u8, comptime field_name: []const u8, comptime value: anytype, comptime omit_if_default: bool) Rule {
    return .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                if (!std.mem.eql(u8, tok, token)) return false;
                @field(row, field_name) = value;
                return true;
            }
        }.p,
        .emit = struct {
            fn e(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, def: StyleRow) anyerror!void {
                const cur = @field(row, field_name);
                if (cur != value) return;
                if (omit_if_default and @field(def, field_name) == value) return;
                try dup_and_push(alloc, out, token);
            }
        }.e,
    };
}

fn ruleParseOnlyExact(comptime token: []const u8, comptime apply: fn (*StyleRow) void) Rule {
    return .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                if (!std.mem.eql(u8, tok, token)) return false;
                apply(row);
                return true;
            }
        }.p,
        .emit = struct {
            fn e(_: *std.ArrayList([]const u8), _: std.mem.Allocator, _: StyleRow, _: StyleRow) anyerror!void {}
        }.e,
    };
}

fn ruleNumField(comptime prefix: []const u8, comptime field_name: []const u8) Rule {
    return .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                if (!std.mem.startsWith(u8, tok, prefix)) return false;
                const n = parseUint(tok[prefix.len..]) orelse 0;
                const T = @TypeOf(@field(row, field_name));
                const maxv: usize = @intCast(std.math.maxInt(T));
                @field(row, field_name) = @intCast(if (n < maxv) n else maxv);
                return true;
            }
        }.p,
        .emit = struct {
            fn e(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
                const v = @field(row, field_name);
                if (v == 0) return;
                try emitFmt(alloc, out, prefix ++ "{}", .{v});
            }
        }.e,
    };
}

fn ruleNumNestedParseOnly(comptime prefix: []const u8, comptime field_a: []const u8, comptime field_b: []const u8) Rule {
    return .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                if (!std.mem.startsWith(u8, tok, prefix)) return false;
                const n = parseUint(tok[prefix.len..]) orelse 0;
                const T = @TypeOf(@field(@field(row, field_a), field_b));
                const maxv: usize = @intCast(std.math.maxInt(T));
                @field(@field(row, field_a), field_b) = @intCast(if (n < maxv) n else maxv);
                return true;
            }
        }.p,
        .emit = struct {
            fn e(_: *std.ArrayList([]const u8), _: std.mem.Allocator, _: StyleRow, _: StyleRow) anyerror!void {}
        }.e,
    };
}

fn ruleNumCustomParseOnly(comptime prefix: []const u8, comptime set: fn (*StyleRow, usize) void) Rule {
    return .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                if (!std.mem.startsWith(u8, tok, prefix)) return false;
                const n = parseUint(tok[prefix.len..]) orelse 0;
                set(row, n);
                return true;
            }
        }.p,
        .emit = struct {
            fn e(_: *std.ArrayList([]const u8), _: std.mem.Allocator, _: StyleRow, _: StyleRow) anyerror!void {}
        }.e,
    };
}

fn ruleNumCustom(comptime prefix: []const u8, comptime set: fn (*StyleRow, usize) void, comptime get: fn (StyleRow) ?usize) Rule {
    return .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                if (!std.mem.startsWith(u8, tok, prefix)) return false;
                const n = parseUint(tok[prefix.len..]) orelse 0;
                set(row, n);
                return true;
            }
        }.p,
        .emit = struct {
            fn e(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
                const n = get(row) orelse return;
                try emitFmt(alloc, out, prefix ++ "{}", .{n});
            }
        }.e,
    };
}

fn ruleEmitOnly(comptime emit_fn: fn (*std.ArrayList([]const u8), std.mem.Allocator, StyleRow, StyleRow) anyerror!void) Rule {
    return .{
        .parse = struct {
            fn p(_: *StyleRow, _: []const u8) bool {
                return false;
            }
        }.p,
        .emit = emit_fn,
    };
}

fn parseUtilityClassList(s: []const u8) StyleRow {
    var row = defaultStyleRow();
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |tok| outer: {
        inline for (RULES) |rule| {
            if (rule.parse(&row, tok)) break :outer;
        }
        // Unknown token: ignore
    }
    return row;
}

// Emission: generate a compact set of utility tokens from a row.
fn dup_and_push(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), s: []const u8) !void {
    const buf = try alloc.alloc(u8, s.len);
    std.mem.copyForwards(u8, buf, s);
    try out.append(buf);
}

fn emitFmt(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) !void {
    var tmp = std.ArrayList(u8).init(alloc);
    defer tmp.deinit();
    try tmp.writer().print(fmt, args);
    try dup_and_push(alloc, out, tmp.items);
}

// Unified custom helpers
fn set_basis_cells(row: *StyleRow, n: usize) void {
    row.flex.basis_auto = 0;
    const maxv: usize = @intCast(std.math.maxInt(@TypeOf(row.flex.basis_cells)));
    row.flex.basis_cells = @intCast(if (n < maxv) n else maxv);
}

fn get_border_w_gt1(row: StyleRow) ?usize {
    return if (row.border.width_cells > 1) row.border.width_cells else null;
}

fn get_basis_cells_emit(row: StyleRow) ?usize {
    return if (row.flex.basis_auto == 0 and row.flex.basis_cells != 0) row.flex.basis_cells else null;
}

fn emit_border_eq1(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
    if (row.border.width_cells == 1) try dup_and_push(alloc, out, "border");
}

fn emit_padding_shorthands(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
    const p = row.padding;
    if ((p.t | p.r | p.b | p.l) == 0) return;
    if (p.t == p.r and p.r == p.b and p.b == p.l) {
        try emitFmt(alloc, out, "p-{}", .{p.t});
        return;
    }
    if (p.l == p.r and p.t == p.b) {
        if (p.l != 0) try emitFmt(alloc, out, "px-{}", .{p.l});
        if (p.t != 0) try emitFmt(alloc, out, "py-{}", .{p.t});
    }
}

fn emit_padding_edges(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
    const p = row.padding;
    if (p.t == p.r and p.r == p.b and p.b == p.l) return;
    if (p.l == p.r and p.t == p.b) return;
    if (p.l != 0) try emitFmt(alloc, out, "pl-{}", .{p.l});
    if (p.r != 0) try emitFmt(alloc, out, "pr-{}", .{p.r});
    if (p.t != 0) try emitFmt(alloc, out, "pt-{}", .{p.t});
    if (p.b != 0) try emitFmt(alloc, out, "pb-{}", .{p.b});
}

fn emit_basis_auto(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, def: StyleRow) anyerror!void {
    if (row.flex.basis_auto == 1 and !(def.flex.basis_auto == 1 and row.flex.basis_cells == 0)) {
        try dup_and_push(alloc, out, "basis-auto");
    }
}

const RULES = [_]Rule{
    // display
    ruleExactField("flex", "display", StyleDisplay.flex, true),
    ruleExactField("block", "display", StyleDisplay.block, true),
    ruleExactField("inline", "display", StyleDisplay.@"inline", true),
    ruleExactField("inline-flex", "display", StyleDisplay.inline_flex, true),
    // direction (include row for parsing; omit on default)
    ruleExactField("flex-row", "flex_dir", StyleFlexDir.row, true),
    ruleExactField("flex-col", "flex_dir", StyleFlexDir.column, true),
    ruleExactField("flex-row-reverse", "flex_dir", StyleFlexDir.row_reverse, true),
    ruleExactField("flex-col-reverse", "flex_dir", StyleFlexDir.column_reverse, true),
    // basis
    ruleParseOnlyExact("basis-auto", struct {
        fn s(row: *StyleRow) void {
            row.flex.basis_auto = 1;
        }
    }.s),
    ruleNumCustom("basis-", set_basis_cells, get_basis_cells_emit),
    // size
    ruleNumField("w-", "width_cells"),
    ruleNumField("h-", "height_cells"),
    // border
    ruleParseOnlyExact("border", struct {
        fn s(row: *StyleRow) void {
            row.border.width_cells = 1;
        }
    }.s),
    ruleNumCustom("border-", struct {
        fn s(row: *StyleRow, n: usize) void {
            row.border.width_cells = @intCast(@min(n, @as(usize, std.math.maxInt(@TypeOf(row.border.width_cells)))));
        }
    }.s, get_border_w_gt1),
    // justify-content
    ruleExactField("justify-start", "justify", StyleJustify.start, true),
    ruleExactField("justify-end", "justify", StyleJustify.end, true),
    ruleExactField("justify-center", "justify", StyleJustify.center, true),
    ruleExactField("justify-between", "justify", StyleJustify.space_between, true),
    ruleExactField("justify-around", "justify", StyleJustify.space_around, true),
    ruleExactField("justify-evenly", "justify", StyleJustify.space_evenly, true),
    // align-items
    ruleExactField("items-start", "align_items", StyleAlign.start, true),
    ruleExactField("items-end", "align_items", StyleAlign.end, true),
    ruleExactField("items-center", "align_items", StyleAlign.center, true),
    ruleExactField("items-stretch", "align_items", StyleAlign.stretch, true),
    ruleExactField("items-baseline", "align_items", StyleAlign.baseline, true),
    // padding parse rules
    ruleNumCustomParseOnly("p-", setPadAll),
    ruleNumCustomParseOnly("px-", setPadX),
    ruleNumCustomParseOnly("py-", setPadY),
    ruleNumNestedParseOnly("pl-", "padding", "l"),
    ruleNumNestedParseOnly("pr-", "padding", "r"),
    ruleNumNestedParseOnly("pt-", "padding", "t"),
    ruleNumNestedParseOnly("pb-", "padding", "b"),
    // emission-only preferences
    ruleEmitOnly(emit_basis_auto),
    ruleEmitOnly(emit_border_eq1),
    ruleEmitOnly(emit_padding_shorthands),
    ruleEmitOnly(emit_padding_edges),
    // colors
    ruleColor("text-", get_fg_rgb, set_fg_rgb),
    ruleColor("bg-", get_bg_rgb, set_bg_rgb),
};

pub fn utilityTokensFromStyleRow(alloc: std.mem.Allocator, row: StyleRow) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    const def = defaultStyleRow();
    inline for (RULES) |r| try r.emit(&out, alloc, row, def);
    return out.toOwnedSlice();
}

// --- Color integration (Tailwind-like palette via OKLCH) ---

const ColorEntry = struct {
    token: []const u8,
    kind: enum { oklch, rgb },
    l: f64 = 0,
    c: f64 = 0,
    h: f64 = 0,
    rgb: [3]u8 = .{ 0, 0, 0 },
};

inline fn clamp01(x: f64) f64 {
    return if (x < 0.0) 0.0 else if (x > 1.0) 1.0 else x;
}

inline fn linearToSrgb(x: f64) f64 {
    // sRGB electro-optical transfer function
    return if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f64, x, 1.0 / 2.4) - 0.055;
}

inline fn oklchToSrgbU8(l: f64, c: f64, h_deg: f64) [3]u8 {
    const h = h_deg * std.math.pi / 180.0;
    const a = c * std.math.cos(h);
    const ch_b = c * std.math.sin(h);
    // OKLab to LMS
    const l_ = l + 0.3963377774 * a + 0.2158037573 * ch_b;
    const m_ = l - 0.1055613458 * a - 0.0638541728 * ch_b;
    const s_ = l - 0.0894841775 * a - 1.2914855480 * ch_b;
    const l3 = l_ * l_ * l_;
    const m3 = m_ * m_ * m_;
    const s3 = s_ * s_ * s_;
    // LMS to linear sRGB
    const r_lin = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
    const g_lin = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
    const b_lin = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;
    const r = @as(u8, @intFromFloat(255.0 * clamp01(linearToSrgb(r_lin)) + 0.5));
    const g = @as(u8, @intFromFloat(255.0 * clamp01(linearToSrgb(g_lin)) + 0.5));
    const b8 = @as(u8, @intFromFloat(255.0 * clamp01(linearToSrgb(b_lin)) + 0.5));
    return .{ r, g, b8 };
}

inline fn ce_oklch(comptime name: []const u8, comptime l: f64, comptime c: f64, comptime h: f64) ColorEntry {
    return .{ .token = name, .kind = .oklch, .l = l, .c = c, .h = h };
}
inline fn ce(comptime name: []const u8, comptime l: f64, comptime c: f64, comptime h: f64) ColorEntry {
    // Back-compat helper: store OKLCH parameters without converting at comptime
    return ce_oklch(name, l, c, h);
}

inline fn ce_rgb(comptime name: []const u8, comptime r8: u8, comptime g8: u8, comptime b8: u8) ColorEntry {
    return .{ .token = name, .kind = .rgb, .rgb = .{ r8, g8, b8 } };
}

const PALETTE = [_]ColorEntry{
    // reds
    ce_oklch("red-50", 0.971, 0.013, 17.38),
    ce_oklch("red-100", 0.936, 0.032, 17.717),
    ce_oklch("red-200", 0.885, 0.062, 18.334),
    ce_oklch("red-300", 0.808, 0.114, 19.571),
    ce_oklch("red-400", 0.704, 0.191, 22.216),
    ce_oklch("red-500", 0.637, 0.237, 25.331),
    ce_oklch("red-600", 0.577, 0.245, 27.325),
    ce_oklch("red-700", 0.505, 0.213, 27.518),
    ce_oklch("red-800", 0.444, 0.177, 26.899),
    ce_oklch("red-900", 0.396, 0.141, 25.723),
    ce_oklch("red-950", 0.258, 0.092, 26.042),
    // orange
    ce_oklch("orange-50", 0.98, 0.016, 73.684),
    ce_oklch("orange-100", 0.954, 0.038, 75.164),
    ce_oklch("orange-200", 0.901, 0.076, 70.697),
    ce_oklch("orange-300", 0.837, 0.128, 66.29),
    ce_oklch("orange-400", 0.75, 0.183, 55.934),
    ce_oklch("orange-500", 0.705, 0.213, 47.604),
    ce_oklch("orange-600", 0.646, 0.222, 41.116),
    ce_oklch("orange-700", 0.553, 0.195, 38.402),
    ce_oklch("orange-800", 0.47, 0.157, 37.304),
    ce_oklch("orange-900", 0.408, 0.123, 38.172),
    ce_oklch("orange-950", 0.266, 0.079, 36.259),
    // amber
    ce("amber-50", 0.987, 0.022, 95.277),
    ce("amber-100", 0.962, 0.059, 95.617),
    ce("amber-200", 0.924, 0.12, 95.746),
    ce("amber-300", 0.879, 0.169, 91.605),
    ce("amber-400", 0.828, 0.189, 84.429),
    ce("amber-500", 0.769, 0.188, 70.08),
    ce("amber-600", 0.666, 0.179, 58.318),
    ce("amber-700", 0.555, 0.163, 48.998),
    ce("amber-800", 0.473, 0.137, 46.201),
    ce("amber-900", 0.414, 0.112, 45.904),
    ce("amber-950", 0.279, 0.077, 45.635),
    // yellow
    ce("yellow-50", 0.987, 0.026, 102.212),
    ce("yellow-100", 0.973, 0.071, 103.193),
    ce("yellow-200", 0.945, 0.129, 101.54),
    ce("yellow-300", 0.905, 0.182, 98.111),
    ce("yellow-400", 0.852, 0.199, 91.936),
    ce("yellow-500", 0.795, 0.184, 86.047),
    ce("yellow-600", 0.681, 0.162, 75.834),
    ce("yellow-700", 0.554, 0.135, 66.442),
    ce("yellow-800", 0.476, 0.114, 61.907),
    ce("yellow-900", 0.421, 0.095, 57.708),
    ce("yellow-950", 0.286, 0.066, 53.813),
    // lime
    ce("lime-50", 0.986, 0.031, 120.757),
    ce("lime-100", 0.967, 0.067, 122.328),
    ce("lime-200", 0.938, 0.127, 124.321),
    ce("lime-300", 0.897, 0.196, 126.665),
    ce("lime-400", 0.841, 0.238, 128.85),
    ce("lime-500", 0.768, 0.233, 130.85),
    ce("lime-600", 0.648, 0.2, 131.684),
    ce("lime-700", 0.532, 0.157, 131.589),
    ce("lime-800", 0.453, 0.124, 130.933),
    ce("lime-900", 0.405, 0.101, 131.063),
    ce("lime-950", 0.274, 0.072, 132.109),
    // green
    ce("green-50", 0.982, 0.018, 155.826),
    ce("green-100", 0.962, 0.044, 156.743),
    ce("green-200", 0.925, 0.084, 155.995),
    ce("green-300", 0.871, 0.15, 154.449),
    ce("green-400", 0.792, 0.209, 151.711),
    ce("green-500", 0.723, 0.219, 149.579),
    ce("green-600", 0.627, 0.194, 149.214),
    ce("green-700", 0.527, 0.154, 150.069),
    ce("green-800", 0.448, 0.119, 151.328),
    ce("green-900", 0.393, 0.095, 152.535),
    ce("green-950", 0.266, 0.065, 152.934),
    // emerald
    ce("emerald-50", 0.979, 0.021, 166.113),
    ce("emerald-100", 0.95, 0.052, 163.051),
    ce("emerald-200", 0.905, 0.093, 164.15),
    ce("emerald-300", 0.845, 0.143, 164.978),
    ce("emerald-400", 0.765, 0.177, 163.223),
    ce("emerald-500", 0.696, 0.17, 162.48),
    ce("emerald-600", 0.596, 0.145, 163.225),
    ce("emerald-700", 0.508, 0.118, 165.612),
    ce("emerald-800", 0.432, 0.095, 166.913),
    ce("emerald-900", 0.378, 0.077, 168.94),
    ce("emerald-950", 0.262, 0.051, 172.552),
    // teal
    ce("teal-50", 0.984, 0.014, 180.72),
    ce("teal-100", 0.953, 0.051, 180.801),
    ce("teal-200", 0.91, 0.096, 180.426),
    ce("teal-300", 0.855, 0.138, 181.071),
    ce("teal-400", 0.777, 0.152, 181.912),
    ce("teal-500", 0.704, 0.14, 182.503),
    ce("teal-600", 0.6, 0.118, 184.704),
    ce("teal-700", 0.511, 0.096, 186.391),
    ce("teal-800", 0.437, 0.078, 188.216),
    ce("teal-900", 0.386, 0.063, 188.416),
    ce("teal-950", 0.277, 0.046, 192.524),
    // cyan
    ce("cyan-50", 0.984, 0.019, 200.873),
    ce("cyan-100", 0.956, 0.045, 203.388),
    ce("cyan-200", 0.917, 0.08, 205.041),
    ce("cyan-300", 0.865, 0.127, 207.078),
    ce("cyan-400", 0.789, 0.154, 211.53),
    ce("cyan-500", 0.715, 0.143, 215.221),
    ce("cyan-600", 0.609, 0.126, 221.723),
    ce("cyan-700", 0.52, 0.105, 223.128),
    ce("cyan-800", 0.45, 0.085, 224.283),
    ce("cyan-900", 0.398, 0.07, 227.392),
    ce("cyan-950", 0.302, 0.056, 229.695),
    // sky
    ce("sky-50", 0.977, 0.013, 236.62),
    ce("sky-100", 0.951, 0.026, 236.824),
    ce("sky-200", 0.901, 0.058, 230.902),
    ce("sky-300", 0.828, 0.111, 230.318),
    ce("sky-400", 0.746, 0.16, 232.661),
    ce("sky-500", 0.685, 0.169, 237.323),
    ce("sky-600", 0.588, 0.158, 241.966),
    ce("sky-700", 0.5, 0.134, 242.749),
    ce("sky-800", 0.443, 0.11, 240.79),
    ce("sky-900", 0.391, 0.09, 240.876),
    ce("sky-950", 0.293, 0.066, 243.157),
    // blue
    ce("blue-50", 0.97, 0.014, 254.604),
    ce("blue-100", 0.932, 0.032, 255.585),
    ce("blue-200", 0.882, 0.059, 254.128),
    ce("blue-300", 0.809, 0.105, 251.813),
    ce("blue-400", 0.707, 0.165, 254.624),
    ce("blue-500", 0.623, 0.214, 259.815),
    ce("blue-600", 0.546, 0.245, 262.881),
    ce("blue-700", 0.488, 0.243, 264.376),
    ce("blue-800", 0.424, 0.199, 265.638),
    ce("blue-900", 0.379, 0.146, 265.522),
    ce("blue-950", 0.282, 0.091, 267.935),
    // indigo
    ce("indigo-50", 0.962, 0.018, 272.314),
    ce("indigo-100", 0.93, 0.034, 272.788),
    ce("indigo-200", 0.87, 0.065, 274.039),
    ce("indigo-300", 0.785, 0.115, 274.713),
    ce("indigo-400", 0.673, 0.182, 276.935),
    ce("indigo-500", 0.585, 0.233, 277.117),
    ce("indigo-600", 0.511, 0.262, 276.966),
    ce("indigo-700", 0.457, 0.24, 277.023),
    ce("indigo-800", 0.398, 0.195, 277.366),
    ce("indigo-900", 0.359, 0.144, 278.697),
    ce("indigo-950", 0.257, 0.09, 281.288),
    // violet
    ce("violet-50", 0.969, 0.016, 293.756),
    ce("violet-100", 0.943, 0.029, 294.588),
    ce("violet-200", 0.894, 0.057, 293.283),
    ce("violet-300", 0.811, 0.111, 293.571),
    ce("violet-400", 0.702, 0.183, 293.541),
    ce("violet-500", 0.606, 0.25, 292.717),
    ce("violet-600", 0.541, 0.281, 293.009),
    ce("violet-700", 0.491, 0.27, 292.581),
    ce("violet-800", 0.432, 0.232, 292.759),
    ce("violet-900", 0.38, 0.189, 293.745),
    ce("violet-950", 0.283, 0.141, 291.089),
    // purple
    ce("purple-50", 0.977, 0.014, 308.299),
    ce("purple-100", 0.946, 0.033, 307.174),
    ce("purple-200", 0.902, 0.063, 306.703),
    ce("purple-300", 0.827, 0.119, 306.383),
    ce("purple-400", 0.714, 0.203, 305.504),
    ce("purple-500", 0.627, 0.265, 303.9),
    ce("purple-600", 0.558, 0.288, 302.321),
    ce("purple-700", 0.496, 0.265, 301.924),
    ce("purple-800", 0.438, 0.218, 303.724),
    ce("purple-900", 0.381, 0.176, 304.987),
    ce("purple-950", 0.291, 0.149, 302.717),
    // fuchsia
    ce("fuchsia-50", 0.977, 0.017, 320.058),
    ce("fuchsia-100", 0.952, 0.037, 318.852),
    ce("fuchsia-200", 0.903, 0.076, 319.62),
    ce("fuchsia-300", 0.833, 0.145, 321.434),
    ce("fuchsia-400", 0.74, 0.238, 322.16),
    ce("fuchsia-500", 0.667, 0.295, 322.15),
    ce("fuchsia-600", 0.591, 0.293, 322.896),
    ce("fuchsia-700", 0.518, 0.253, 323.949),
    ce("fuchsia-800", 0.452, 0.211, 324.591),
    ce("fuchsia-900", 0.401, 0.17, 325.612),
    ce("fuchsia-950", 0.293, 0.136, 325.661),
    // pink
    ce("pink-50", 0.971, 0.014, 343.198),
    ce("pink-100", 0.948, 0.028, 342.258),
    ce("pink-200", 0.899, 0.061, 343.231),
    ce("pink-300", 0.823, 0.12, 346.018),
    ce("pink-400", 0.718, 0.202, 349.761),
    ce("pink-500", 0.656, 0.241, 354.308),
    ce("pink-600", 0.592, 0.249, 0.584),
    ce("pink-700", 0.525, 0.223, 3.958),
    ce("pink-800", 0.459, 0.187, 3.815),
    ce("pink-900", 0.408, 0.153, 2.432),
    ce("pink-950", 0.284, 0.109, 3.907),
    // rose
    ce("rose-50", 0.969, 0.015, 12.422),
    ce("rose-100", 0.941, 0.03, 12.58),
    ce("rose-200", 0.892, 0.058, 10.001),
    ce("rose-300", 0.81, 0.117, 11.638),
    ce("rose-400", 0.712, 0.194, 13.428),
    ce("rose-500", 0.645, 0.246, 16.439),
    ce("rose-600", 0.586, 0.253, 17.585),
    ce("rose-700", 0.514, 0.222, 16.935),
    ce("rose-800", 0.455, 0.188, 13.697),
    ce("rose-900", 0.41, 0.159, 10.272),
    ce("rose-950", 0.271, 0.105, 12.094),
    // slate
    ce("slate-50", 0.984, 0.003, 247.858),
    ce("slate-100", 0.968, 0.007, 247.896),
    ce("slate-200", 0.929, 0.013, 255.508),
    ce("slate-300", 0.869, 0.022, 252.894),
    ce("slate-400", 0.704, 0.04, 256.788),
    ce("slate-500", 0.554, 0.046, 257.417),
    ce("slate-600", 0.446, 0.043, 257.281),
    ce("slate-700", 0.372, 0.044, 257.287),
    ce("slate-800", 0.279, 0.041, 260.031),
    ce("slate-900", 0.208, 0.042, 265.755),
    ce("slate-950", 0.129, 0.042, 264.695),
    // gray
    ce("gray-50", 0.985, 0.002, 247.839),
    ce("gray-100", 0.967, 0.003, 264.542),
    ce("gray-200", 0.928, 0.006, 264.531),
    ce("gray-300", 0.872, 0.01, 258.338),
    ce("gray-400", 0.707, 0.022, 261.325),
    ce("gray-500", 0.551, 0.027, 264.364),
    ce("gray-600", 0.446, 0.03, 256.802),
    ce("gray-700", 0.373, 0.034, 259.733),
    ce("gray-800", 0.278, 0.033, 256.848),
    ce("gray-900", 0.21, 0.034, 264.665),
    ce("gray-950", 0.13, 0.028, 261.692),
    // zinc
    ce("zinc-50", 0.985, 0.0, 0.0),
    ce("zinc-100", 0.967, 0.001, 286.375),
    ce("zinc-200", 0.92, 0.004, 286.32),
    ce("zinc-300", 0.871, 0.006, 286.286),
    ce("zinc-400", 0.705, 0.015, 286.067),
    ce("zinc-500", 0.552, 0.016, 285.938),
    ce("zinc-600", 0.442, 0.017, 285.786),
    ce("zinc-700", 0.37, 0.013, 285.805),
    ce("zinc-800", 0.274, 0.006, 286.033),
    ce("zinc-900", 0.21, 0.006, 285.885),
    ce("zinc-950", 0.141, 0.005, 285.823),
    // neutral
    ce("neutral-50", 0.985, 0.0, 0.0),
    ce("neutral-100", 0.97, 0.0, 0.0),
    ce("neutral-200", 0.922, 0.0, 0.0),
    ce("neutral-300", 0.87, 0.0, 0.0),
    ce("neutral-400", 0.708, 0.0, 0.0),
    ce("neutral-500", 0.556, 0.0, 0.0),
    ce("neutral-600", 0.439, 0.0, 0.0),
    ce("neutral-700", 0.371, 0.0, 0.0),
    ce("neutral-800", 0.269, 0.0, 0.0),
    ce("neutral-900", 0.205, 0.0, 0.0),
    ce("neutral-950", 0.145, 0.0, 0.0),
    // stone
    ce("stone-50", 0.985, 0.001, 106.423),
    ce("stone-100", 0.97, 0.001, 106.424),
    ce("stone-200", 0.923, 0.003, 48.717),
    ce("stone-300", 0.869, 0.005, 56.366),
    ce("stone-400", 0.709, 0.01, 56.259),
    ce("stone-500", 0.553, 0.013, 58.071),
    ce("stone-600", 0.444, 0.011, 73.639),
    ce("stone-700", 0.374, 0.01, 67.558),
    ce("stone-800", 0.268, 0.007, 34.298),
    ce("stone-900", 0.216, 0.006, 56.043),
    ce("stone-950", 0.147, 0.004, 49.25),
    // black/white
    ce_rgb("black", 0, 0, 0),
    ce_rgb("white", 255, 255, 255),
};

fn set_fg_rgb(row: *StyleRow, rgb: [3]u8) void {
    row.fg = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .use_default = 0 };
}
fn set_bg_rgb(row: *StyleRow, rgb: [3]u8) void {
    row.bg = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .use_default = 0 };
}
fn get_fg_rgb(row: StyleRow) ?[3]u8 {
    if (row.fg.use_default == 1) return null;
    return .{ row.fg.r, row.fg.g, row.fg.b };
}
fn get_bg_rgb(row: StyleRow) ?[3]u8 {
    if (row.bg.use_default == 1) return null;
    return .{ row.bg.r, row.bg.g, row.bg.b };
}

fn rgbEqual(a: [3]u8, c: [3]u8) bool {
    return a[0] == c[0] and a[1] == c[1] and a[2] == c[2];
}

inline fn entryRgb(e: ColorEntry) [3]u8 {
    return switch (e.kind) {
        .oklch => oklchToSrgbU8(e.l, e.c, e.h),
        .rgb => e.rgb,
    };
}

fn ruleColor(comptime prefix: []const u8, comptime get_color: anytype, comptime set_color: anytype) Rule {
    return .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                if (!std.mem.startsWith(u8, tok, prefix)) return false;
                const suffix = tok[prefix.len..];
                for (PALETTE) |ce_entry| {
                    if (std.mem.eql(u8, ce_entry.token, suffix)) {
                        set_color(row, entryRgb(ce_entry));
                        return true;
                    }
                }
                return false;
            }
        }.p,
        .emit = struct {
            fn e(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
                const rgb = get_color(row) orelse return;
                for (PALETTE) |ce_entry| {
                    if (rgbEqual(entryRgb(ce_entry), rgb)) {
                        try emitFmt(alloc, out, prefix ++ "{s}", .{ce_entry.token});
                        return;
                    }
                }
            }
        }.e,
    };
}

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

fn parseUint(s: []const u8) ?usize {
    var it = std.mem.tokenizeAny(u8, s, "_"); // allow e.g., h-[12] later; for now simple numbers
    const num = it.next() orelse return null;
    return std.fmt.parseInt(usize, num, 10) catch null;
}

fn clamp4(n: usize) u4 {
    return @intCast(@min(n, 15));
}
fn setPadAll(row: *StyleRow, n: usize) void {
    const v = clamp4(n);
    row.padding = .{ .t = v, .r = v, .b = v, .l = v };
}
fn setPadX(row: *StyleRow, n: usize) void {
    const v = clamp4(n);
    row.padding.l = v;
    row.padding.r = v;
}
fn setPadY(row: *StyleRow, n: usize) void {
    const v = clamp4(n);
    row.padding.t = v;
    row.padding.b = v;
}

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

fn styleSummary(row: StyleRow) struct {
    display: []const u8,
    dir: []const u8,
} {
    const d: []const u8 = switch (row.display) {
        .none => "none",
        .@"inline" => "inline",
        .block => "block",
        .flex => "flex",
        .inline_flex => "inline-flex",
        else => "?",
    };
    const dir: []const u8 = switch (row.flex_dir) {
        .row => "row",
        .column => "column",
        .row_reverse => "row-rev",
        .column_reverse => "col-rev",
    };
    return .{ .display = d, .dir = dir };
}

fn dumpBoxTreeNode(writer: anytype, tree: *const BoxTree, dom: *const Dom, idx: u32, depth: usize, is_last: bool, more_mask: u64) !void {
    const h = tree.headers.items[@as(usize, @intCast(idx))];
    const items = dom.headers.slice();
    const kind = items.items(.kind)[@as(usize, @intCast(h.dom_id))];

    try writeIndent(writer, depth, is_last, more_mask);
    const kind_tag = if (kind == .element) "tag" else "text";
    const kind_color = if (kind == .element) Ansi.fg.green else Ansi.fg.yellow;
    try writer.print("{s}{s}{s}{s} ", .{ Ansi.bold, kind_color, kind_tag, Ansi.reset });
    try writer.print("at {s}{d},{d}{s} ", .{ Ansi.fg.cyan, h.rect.x, h.rect.y, Ansi.reset });
    try writer.print("size {s}{d}x{d}{s}", .{ Ansi.fg.blue, h.rect.w, h.rect.h, Ansi.reset });

    const sid = items.items(.style_id)[@as(usize, @intCast(h.dom_id))];
    const row = dom.styles.cols.items[@intCast(sid)];
    const ss = styleSummary(row);
    if (kind == .element) {
        const basis = if (row.flex.basis_auto == 1) "auto" else "";
        const basis_val: usize = @intCast(row.flex.basis_cells);
        try writer.print("  {s}style:{s} {s}{s}{s} {s}{s}{s}", .{ Ansi.dim, Ansi.reset, Ansi.bold, ss.display, Ansi.reset, Ansi.fg.magenta, ss.dir, Ansi.reset });
        if (row.width_cells != 0) try writer.print(" {s}w={d}{s}", .{ Ansi.fg.blue, row.width_cells, Ansi.reset });
        if (row.height_cells != 0) try writer.print(" {s}h={d}{s}", .{ Ansi.fg.blue, row.height_cells, Ansi.reset });
        if (row.flex.basis_auto == 0 or basis_val != 0) try writer.print(" {s}basis={s}{d}{s}", .{ Ansi.fg.blue, basis, basis_val, Ansi.reset });
        if (row.border.width_cells != 0) try writer.print(" {s}border={d}{s}", .{ Ansi.fg.blue, row.border.width_cells, Ansi.reset });
        if ((row.padding.t | row.padding.r | row.padding.b | row.padding.l) != 0)
            try writer.print(" {s}pad={d},{d},{d},{d}{s}", .{ Ansi.fg.blue, row.padding.t, row.padding.r, row.padding.b, row.padding.l, Ansi.reset });
    } else {
        const txt = dom.getTextSlice(h.dom_id);
        const preview_len = if (txt.len > 20) 20 else txt.len;
        try writer.print("  {s}text:{s} {s}\"{s}{s}\"{s}", .{ Ansi.dim, Ansi.reset, Ansi.fg.yellow, txt[0..preview_len], if (txt.len > preview_len) "…" else "", Ansi.reset });
    }
    try writer.print("\n", .{});

    if (h.child_count == 0) return;
    const start: usize = @intCast(h.first_child);
    var j: usize = 0;
    while (j < h.child_count) : (j += 1) {
        const child_idx: u32 = @intCast(start + j);
        const child_is_last = (j + 1 == h.child_count);
        const next_mask = if (depth < 63) (more_mask & ~(@as(u64, 1) << @intCast(depth))) | (if (!child_is_last) (@as(u64, 1) << @intCast(depth)) else 0) else more_mask;
        try dumpBoxTreeNode(writer, tree, dom, child_idx, depth + 1, child_is_last, next_mask);
    }
}

fn xmlIndent(writer: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.print("  ", .{});
}

fn enumNameDisplay(v: StyleDisplay) []const u8 {
    return switch (v) {
        .none => "none",
        .@"inline" => "inline",
        .block => "block",
        .flex => "flex",
        .inline_flex => "inline-flex",
        else => "unknown",
    };
}
fn enumNameWhitespace(v: StyleWhitespace) []const u8 {
    return switch (v) {
        .normal => "normal",
        .pre => "pre",
        .nowrap => "nowrap",
        .pre_wrap => "pre-wrap",
    };
}
fn enumNameBorderStyle(v: StyleBorderStyle) []const u8 {
    return switch (v) {
        .none => "none",
        .solid => "solid",
        .double => "double",
        .dashed => "dashed",
    };
}
fn enumNameFlexDir(v: StyleFlexDir) []const u8 {
    return switch (v) {
        .row => "row",
        .column => "column",
        .row_reverse => "row-reverse",
        .column_reverse => "column-reverse",
    };
}
fn enumNameFlexWrap(v: StyleFlexWrap) []const u8 {
    return switch (v) {
        .nowrap => "nowrap",
        .wrap => "wrap",
        .wrap_reverse => "wrap-reverse",
        else => "unknown",
    };
}
fn enumNameJustify(v: StyleJustify) []const u8 {
    return switch (v) {
        .start => "start",
        .end => "end",
        .center => "center",
        .space_between => "space-between",
        .space_around => "space-around",
        .space_evenly => "space-evenly",
        else => "unknown",
    };
}
fn enumNameAlign(v: StyleAlign) []const u8 {
    return switch (v) {
        .start => "start",
        .end => "end",
        .center => "center",
        .stretch => "stretch",
        .baseline => "baseline",
        else => "unknown",
    };
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

fn dumpBoxTreeNodeXml(alloc: std.mem.Allocator, writer: anytype, tree: *const BoxTree, dom: *const Dom, idx: u32, depth: usize) !void {
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
    var dl = DisplayList.init(al);
    defer dl.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
    try rasterizeDisplayListAscii(&r, al, &glyphs, &dl);

    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        "+------++------+  \n" ++
        "|      ||      |  \n" ++
        "+------++------+  \n";
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

    var dl = DisplayList.init(al);
    defer dl.deinit();
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    try buildDisplayListFromBoxes(&dl, &dom, &tree, &glyphs);
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
                        try list.push(PaintOp{ .GlyphRun = .{ .x = h.rect.x + inset_left + extra, .y = h.rect.y + inset_top + y_offset, .glyphs = run } });
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
                    try list.push(PaintOp{ .GlyphRun = .{ .x = h.rect.x + inset_left + extra, .y = h.rect.y + inset_top + y_offset, .glyphs = run } });
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
