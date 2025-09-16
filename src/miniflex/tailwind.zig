const std = @import("std");
const style = @import("./style.zig");
const StyleRow = style.StyleRow;
const StyleDisplay = style.StyleDisplay;
const StyleFlexDir = style.StyleFlexDir;
const StyleFlexWrap = style.StyleFlexWrap;
const StyleJustify = style.StyleJustify;
const StyleAlign = style.StyleAlign;
const StyleOverflow = style.StyleOverflow;
const BorderStyle = style.BorderStyle;
const defaultStyleRow = style.defaultStyleRow;

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
                const n = parseUint(tok[prefix.len..]) orelse return false;
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
                const n = parseUint(tok[prefix.len..]) orelse return false;
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
                const n = parseUint(tok[prefix.len..]) orelse return false;
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
                const n = parseUint(tok[prefix.len..]) orelse return false;
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

pub fn parseUtilityClassList(s: []const u8) StyleRow {
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

fn get_border_w_gt1(row: StyleRow) ?usize {
    return if (row.border.width > 1) row.border.width else null;
}

fn emit_border_eq1(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
    if (row.border.width == 1) try dup_and_push(alloc, out, "border");
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
    // grow
    ruleParseOnlyExact("grow", struct {
        fn s(row: *StyleRow) void {
            row.flex.flexGrowFactor = 1;
        }
    }.s),
    ruleNumCustom("grow-", struct {
        fn s(row: *StyleRow, n: usize) void {
            const maxv: usize = @intCast(std.math.maxInt(@TypeOf(row.flex.flexGrowFactor)));
            row.flex.flexGrowFactor = @intCast(if (n < maxv) n else maxv);
        }
    }.s, struct {
        fn g(row: StyleRow) ?usize {
            return if (row.flex.flexGrowFactor != 0) row.flex.flexGrowFactor else null;
        }
    }.g),
    // common shorthand: flex-1 → grow:1; shrink:1 (kept); basis:0
    ruleParseOnlyExact("flex-1", struct {
        fn s(row: *StyleRow) void {
            row.flex.flexGrowFactor = 1;
            row.flex.flexShrinkFactor = 1;
        }
    }.s),
    // size
    ruleNumField("w-", "width"),
    ruleNumField("h-", "height"),
    // border
    ruleParseOnlyExact("border", struct {
        fn s(row: *StyleRow) void {
            row.border.width = 1;
            if (row.border.style == BorderStyle.none) row.border.style = BorderStyle.solid;
        }
    }.s),
    ruleNumCustom("border-", struct {
        fn s(row: *StyleRow, n: usize) void {
            row.border.width = @intCast(@min(n, @as(usize, std.math.maxInt(@TypeOf(row.border.width)))));
            if (row.border.style == BorderStyle.none) row.border.style = BorderStyle.solid;
        }
    }.s, get_border_w_gt1),
    // border style variants
    ruleParseOnlyExact("border-solid", struct {
        fn s(row: *StyleRow) void {
            row.border.style = BorderStyle.solid;
            if (row.border.width == 0) row.border.width = 1;
        }
    }.s),
    ruleParseOnlyExact("border-double", struct {
        fn s(row: *StyleRow) void {
            row.border.style = BorderStyle.double;
            if (row.border.width == 0) row.border.width = 1;
        }
    }.s),
    ruleParseOnlyExact("border-dashed", struct {
        fn s(row: *StyleRow) void {
            row.border.style = BorderStyle.dashed;
            if (row.border.width == 0) row.border.width = 1;
        }
    }.s),
    // non-CSS extension: block (filled cells)
    ruleParseOnlyExact("border-block", struct {
        fn s(row: *StyleRow) void {
            row.border.style = BorderStyle.block;
            if (row.border.width == 0) row.border.width = 1;
        }
    }.s),
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
    // align-self
    ruleExactField("self-start", "align_self", StyleAlign.start, true),
    ruleExactField("self-end", "align_self", StyleAlign.end, true),
    ruleExactField("self-center", "align_self", StyleAlign.center, true),
    ruleExactField("self-stretch", "align_self", StyleAlign.stretch, true),
    // overflow
    ruleExactField("overflow-visible", "overflow_y", StyleOverflow.visible, true),
    ruleExactField("overflow-hidden", "overflow_y", StyleOverflow.hidden, true),
    ruleExactField("overflow-scroll", "overflow_y", StyleOverflow.scroll, true),
    ruleExactField("overflow-x-visible", "overflow_x", StyleOverflow.visible, true),
    ruleExactField("overflow-x-hidden", "overflow_x", StyleOverflow.hidden, true),
    ruleExactField("overflow-x-scroll", "overflow_x", StyleOverflow.scroll, true),
    ruleExactField("overflow-y-visible", "overflow_y", StyleOverflow.visible, true),
    ruleExactField("overflow-y-hidden", "overflow_y", StyleOverflow.hidden, true),
    ruleExactField("overflow-y-scroll", "overflow_y", StyleOverflow.scroll, true),
    // padding parse rules
    ruleNumCustomParseOnly("p-", setPadAll),
    ruleNumCustomParseOnly("px-", setPadX),
    ruleNumCustomParseOnly("py-", setPadY),
    ruleNumNestedParseOnly("pl-", "padding", "l"),
    ruleNumNestedParseOnly("pr-", "padding", "r"),
    ruleNumNestedParseOnly("pt-", "padding", "t"),
    ruleNumNestedParseOnly("pb-", "padding", "b"),
    // emission-only preferences
    ruleEmitOnly(emit_border_eq1),
    ruleEmitOnly(emit_padding_shorthands),
    ruleEmitOnly(emit_padding_edges),
    // colors
    ruleColor("text-", get_fg_rgb, set_fg_rgb),
    ruleColor("bg-", get_bg_rgb, set_bg_rgb),
    ruleColor("border-", get_border_rgb, set_border_rgb),
    // bg-glyph-[x] → set StyleRow.fill_glyph to the codepoint of x (single glyph)
    .{
        .parse = struct {
            fn p(row: *StyleRow, tok: []const u8) bool {
                const pref = "bg-glyph-[";
                if (tok.len < pref.len + 2) return false; // needs at least one char and closing bracket
                if (!std.mem.startsWith(u8, tok, pref)) return false;
                if (tok[tok.len - 1] != ']') return false;
                const inner = tok[pref.len .. tok.len - 1];
                // Accept exactly one UTF-8 scalar; ignore longer strings for now
                var it = std.unicode.Utf8Iterator{ .bytes = inner, .i = 0 };
                const first = it.nextCodepoint() orelse return false;
                // If there is another codepoint, ignore (fail parse)
                if (it.nextCodepoint()) |_| return false;
                row.fill_glyph = first;
                return true;
            }
        }.p,
        .emit = struct {
            fn e(out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, row: StyleRow, _: StyleRow) anyerror!void {
                if (row.fill_glyph == 0) return;
                // Only emit ASCII bracketed form for 1-byte glyphs to keep emission simple
                if (row.fill_glyph <= 0x7F) {
                    var buf: [16]u8 = undefined;
                    const ch: u8 = @intCast(row.fill_glyph);
                    const n = try std.fmt.bufPrint(&buf, "bg-glyph-[{c}]", .{ch});
                    try dup_and_push(alloc, out, n);
                }
            }
        }.e,
    },
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
fn set_border_rgb(row: *StyleRow, rgb: [3]u8) void {
    row.border_color = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .use_default = 0 };
}
pub fn get_fg_rgb(row: StyleRow) ?[3]u8 {
    if (row.fg.use_default == 1) return null;
    return .{ row.fg.r, row.fg.g, row.fg.b };
}
pub fn get_bg_rgb(row: StyleRow) ?[3]u8 {
    if (row.bg.use_default == 1) return null;
    return .{ row.bg.r, row.bg.g, row.bg.b };
}
pub fn get_border_rgb(row: StyleRow) ?[3]u8 {
    if (row.border_color.use_default == 1) return null;
    return .{ row.border_color.r, row.border_color.g, row.border_color.b };
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
