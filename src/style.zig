const std = @import("std");

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
        .align_items = .start,
        // align_self defaults to inherit parent cross align; use reserved value as sentinel
        .align_self = ._u0,
        .flex = .{ .grow = 0, .shrink = 1, .basis_auto = 1, .basis_cells = 0 },
        .z_index = 0,
        .order = 0,
    };
}
