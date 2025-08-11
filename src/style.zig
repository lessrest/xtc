const std = @import("std");

pub const StyleDisplay = enum(u3) {
    none,
    @"inline",
    block,
    flex,
    inline_flex,
};
pub const StyleWhitespace = enum(u2) {
    normal,
    pre,
    nowrap,
    pre_wrap,
};
pub const BorderStyle = enum(u3) {
    none,
    solid,
    double,
    dashed,
    block,
};
pub const StyleFlexDir = enum(u2) {
    row,
    column,
    row_reverse,
    column_reverse,
};
pub const StyleFlexWrap = enum(u2) {
    nowrap,
    wrap,
    wrap_reverse,
};
pub const StyleJustify = enum(u3) {
    start,
    end,
    center,
    space_between,
    space_around,
    space_evenly,
};
pub const StyleAlign = enum(u3) { start, end, center, stretch, baseline };
pub const StyleOverflow = enum(u2) { visible, hidden, scroll };

pub const StyleColor = packed struct {
    r: u8,
    g: u8,
    b: u8,
    use_default: u1, // 1 = use terminal default, ignore rgb
};

pub const Size = struct {
    w: i32,
    h: i32,

    pub fn trace(self: Size, tracer: anytype) void {
        tracer.print("{d}×{d}", .{ self.w, self.h });
    }
};

pub const EdgeSizing = packed struct {
    t: u4,
    r: u4,
    b: u4,
    l: u4,

    pub fn trace(self: EdgeSizing, tracer: anytype) void {
        tracer.data("edges").put("top", self.t).put("right", self.r).put("bottom", self.b).put("left", self.l).end();
    }
};
pub const GapSizing = packed struct { main: u3, cross: u3 };
pub const BorderStyling = packed struct { width: u2, style: BorderStyle };

// [CSS-FLEXBOX-1] § 7.1.
pub const FlexibleLength = packed struct {
    flexGrowFactor: u4,
    flexShrinkFactor: u4,
};

// not packed: it's anyway in a MultiArrayList,
// and packing made hashing nondeterministic
pub const StyleRow = struct {
    fg: StyleColor,
    bg: StyleColor,
    border_color: StyleColor,
    text_flags: packed struct { bold: u1, italic: u1, underline: u1, inverse: u1, strike: u1, dim: u1, blink: u1 },

    display: StyleDisplay,
    visibility_hidden: u1,
    overflow_x: StyleOverflow,
    overflow_y: StyleOverflow,
    whitespace: StyleWhitespace,

    width: u16,
    height: u16,

    padding: EdgeSizing,
    margin: EdgeSizing,
    border: BorderStyling,

    gaps: GapSizing,

    flex_dir: StyleFlexDir,
    flex_wrap: StyleFlexWrap,
    justify: StyleJustify,
    align_items: StyleAlign,
    align_self: ?StyleAlign,
    flex: FlexibleLength,

    z_index: i16,
    order: i16,
    // ASCII raster test helper: when non-zero, paint stage tiles this glyph in the element's border-box
    fill_glyph: u32 = 0,
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
        .border_color = .{ .r = 0, .g = 0, .b = 0, .use_default = 1 },
        .text_flags = .{ .bold = 0, .italic = 0, .underline = 0, .inverse = 0, .strike = 0, .dim = 0, .blink = 0 },
        .display = .@"inline",
        .visibility_hidden = 0,
        .overflow_x = .visible,
        .overflow_y = .visible,
        .whitespace = .normal,
        .width = 0,
        .height = 0,
        .padding = .{ .t = 0, .r = 0, .b = 0, .l = 0 },
        .margin = .{ .t = 0, .r = 0, .b = 0, .l = 0 },
        .border = .{ .width = 0, .style = .none },
        .gaps = .{ .main = 0, .cross = 0 },
        .flex_dir = .row,
        .flex_wrap = .nowrap,
        .justify = .start,
        .align_items = .start,
        .align_self = .start,
        .flex = .{ .flexGrowFactor = 0, .flexShrinkFactor = 1 },
        .z_index = 0,
        .order = 0,
        .fill_glyph = 0,
    };
}
