//! Display Width module
//!
//! Answers questions about the printable width in monospaced fonts of the
//! string of interest.

graphemes: Graphemes = undefined,
s1: []u16 = undefined,
s2: []i4 = undefined,
owns_graphemes: bool = true,

const DisplayWidth = @This();

pub fn init(allocator: Allocator) Allocator.Error!DisplayWidth {
    var dw = DisplayWidth{};
    try dw.setup(allocator);
    errdefer {
        allocator.free(dw.s1);
        allocator.free(dw.s2);
    }
    dw.owns_graphemes = true;
    dw.graphemes = try Graphemes.init(allocator);
    errdefer dw.graphemes.deinit(allocator);
    return dw;
}

pub fn initWithGraphemes(allocator: Allocator, graphemes: Graphemes) Allocator.Error!DisplayWidth {
    var dw = DisplayWidth{};
    try dw.setup(allocator);
    dw.graphemes = graphemes;
    dw.owns_graphemes = false;
    return dw;
}

pub fn setupWithGraphemes(dw: *DisplayWidth, allocator: Allocator, graphemes: Graphemes) Allocator.Error!void {
    try dw.setup(allocator);
    dw.graphemes = graphemes;
    dw.owns_graphemes = false;
}

// Sets up the DisplayWidthData, leaving the GraphemeData undefined.
pub fn setup(dw: *DisplayWidth, allocator: Allocator) Allocator.Error!void {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("dwp");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();

    const stage_1_len: u16 = reader.readInt(u16, endian) catch unreachable;
    dw.s1 = try allocator.alloc(u16, stage_1_len);
    errdefer allocator.free(dw.s1);
    for (0..stage_1_len) |i| dw.s1[i] = reader.readInt(u16, endian) catch unreachable;

    const stage_2_len: u16 = reader.readInt(u16, endian) catch unreachable;
    dw.s2 = try allocator.alloc(i4, stage_2_len);
    errdefer allocator.free(dw.s2);
    for (0..stage_2_len) |i| dw.s2[i] = @intCast(reader.readInt(i8, endian) catch unreachable);
}

pub fn deinit(dw: *const DisplayWidth, allocator: Allocator) void {
    allocator.free(dw.s1);
    allocator.free(dw.s2);
    if (dw.owns_graphemes) dw.graphemes.deinit(allocator);
}

/// codePointWidth returns the number of cells `cp` requires when rendered
/// in a fixed-pitch font (i.e. a terminal screen). This can range from -1 to
/// 3, where BACKSPACE and DELETE return -1 and 3-em-dash returns 3. C0/C1
/// control codes return 0. If `cjk` is true, ambiguous code points return 2,
/// otherwise they return 1.
pub fn codePointWidth(dw: DisplayWidth, cp: u21) i4 {
    return dw.s2[dw.s1[cp >> 8] + (cp & 0xff)];
}

test "codePointWidth" {
    const dw = try DisplayWidth.init(std.testing.allocator);
    defer dw.deinit(std.testing.allocator);
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x0000)); // null
    try testing.expectEqual(@as(i4, -1), dw.codePointWidth(0x8)); // \b
    try testing.expectEqual(@as(i4, -1), dw.codePointWidth(0x7f)); // DEL
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x0005)); // Cf
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x0007)); // \a BEL
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x000A)); // \n LF
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x000B)); // \v VT
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x000C)); // \f FF
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x000D)); // \r CR
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x000E)); // SQ
    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x000F)); // SI

    try testing.expectEqual(@as(i4, 0), dw.codePointWidth(0x070F)); // Cf
    try testing.expectEqual(@as(i4, 1), dw.codePointWidth(0x0603)); // Cf Arabic

    try testing.expectEqual(@as(i4, 1), dw.codePointWidth(0x00AD)); // soft-hyphen
    try testing.expectEqual(@as(i4, 2), dw.codePointWidth(0x2E3A)); // two-em dash
    try testing.expectEqual(@as(i4, 3), dw.codePointWidth(0x2E3B)); // three-em dash

    try testing.expectEqual(@as(i4, 1), dw.codePointWidth(0x00BD)); // ambiguous halfwidth

    try testing.expectEqual(@as(i4, 1), dw.codePointWidth('é'));
    try testing.expectEqual(@as(i4, 2), dw.codePointWidth('😊'));
    try testing.expectEqual(@as(i4, 2), dw.codePointWidth('统'));
}

/// strWidth returns the total display width of `str` as the number of cells
/// required in a fixed-pitch font (i.e. a terminal screen).
pub fn strWidth(dw: DisplayWidth, str: []const u8) usize {
    var total: isize = 0;

    // ASCII fast path
    if (ascii.isAsciiOnly(str)) {
        for (str) |b| total += dw.codePointWidth(b);
        return @intCast(@max(0, total));
    }

    var giter = dw.graphemes.iterator(str);

    while (giter.next()) |gc| {
        var cp_iter = CodePointIterator{ .bytes = gc.bytes(str) };
        var gc_total: isize = 0;

        while (cp_iter.next()) |cp| {
            var w = dw.codePointWidth(cp.code);

            if (w != 0) {
                // Handle text emoji sequence.
                if (cp_iter.next()) |ncp| {
                    // emoji text sequence.
                    if (ncp.code == 0xFE0E) w = 1;
                    if (ncp.code == 0xFE0F) w = 2;
                }

                // Only adding width of first non-zero-width code point.
                if (gc_total == 0) {
                    gc_total = w;
                    break;
                }
            }
        }

        total += gc_total;
    }

    return @intCast(@max(0, total));
}

test "strWidth" {
    const dw = try DisplayWidth.init(testing.allocator);
    defer dw.deinit(testing.allocator);
    const c0 = options.c0_width orelse 0;

    try testing.expectEqual(@as(usize, 5), dw.strWidth("Hello\r\n"));
    try testing.expectEqual(@as(usize, 1), dw.strWidth("\u{0065}\u{0301}"));
    try testing.expectEqual(@as(usize, 2), dw.strWidth("\u{1F476}\u{1F3FF}\u{0308}\u{200D}\u{1F476}\u{1F3FF}"));
    try testing.expectEqual(@as(usize, 8), dw.strWidth("Hello 😊"));
    try testing.expectEqual(@as(usize, 8), dw.strWidth("Héllo 😊"));
    try testing.expectEqual(@as(usize, 8), dw.strWidth("Héllo :)"));
    try testing.expectEqual(@as(usize, 8), dw.strWidth("Héllo 🇪🇸"));
    try testing.expectEqual(@as(usize, 2), dw.strWidth("\u{26A1}")); // Lone emoji
    try testing.expectEqual(@as(usize, 1), dw.strWidth("\u{26A1}\u{FE0E}")); // Text sequence
    try testing.expectEqual(@as(usize, 2), dw.strWidth("\u{26A1}\u{FE0F}")); // Presentation sequence
    try testing.expectEqual(@as(usize, 1), dw.strWidth("\u{2764}")); // Default text presentation
    try testing.expectEqual(@as(usize, 1), dw.strWidth("\u{2764}\u{FE0E}")); // Default text presentation with VS15 selector
    try testing.expectEqual(@as(usize, 2), dw.strWidth("\u{2764}\u{FE0F}")); // Default text presentation with VS16 selector
    const expect_bs: usize = if (c0 == 0) 0 else 1 + c0;
    try testing.expectEqual(expect_bs, dw.strWidth("A\x08")); // Backspace
    try testing.expectEqual(expect_bs, dw.strWidth("\x7FA")); // DEL
    const expect_long_del: usize = if (c0 == 0) 0 else 1 + (c0 * 3);
    try testing.expectEqual(expect_long_del, dw.strWidth("\x7FA\x08\x08")); // never less than 0

    // wcwidth Python lib tests. See: https://github.com/jquast/wcwidth/blob/master/tests/test_core.py
    const empty = "";
    try testing.expectEqual(@as(usize, 0), dw.strWidth(empty));
    const with_null = "hello\x00world";
    try testing.expectEqual(@as(usize, 10 + c0), dw.strWidth(with_null));
    const hello_jp = "コンニチハ, セカイ!";
    try testing.expectEqual(@as(usize, 19), dw.strWidth(hello_jp));
    const control = "\x1b[0m";
    try testing.expectEqual(@as(usize, 3 + c0), dw.strWidth(control));
    const balinese = "\u{1B13}\u{1B28}\u{1B2E}\u{1B44}";
    try testing.expectEqual(@as(usize, 3), dw.strWidth(balinese));

    // These commented out tests require a new specification for complex scripts.
    // See: https://www.unicode.org/L2/L2023/23107-terminal-suppt.pdf
    // const jamo = "\u{1100}\u{1160}";
    // try testing.expectEqual(@as(usize, 3), strWidth(jamo));
    // const devengari = "\u{0915}\u{094D}\u{0937}\u{093F}";
    // try testing.expectEqual(@as(usize, 3), strWidth(devengari));
    // const tamal = "\u{0b95}\u{0bcd}\u{0bb7}\u{0bcc}";
    // try testing.expectEqual(@as(usize, 5), strWidth(tamal));
    // const kannada_1 = "\u{0cb0}\u{0ccd}\u{0c9d}\u{0cc8}";
    // try testing.expectEqual(@as(usize, 3), strWidth(kannada_1));
    // The following passes but as a mere coincidence.
    const kannada_2 = "\u{0cb0}\u{0cbc}\u{0ccd}\u{0c9a}";
    try testing.expectEqual(@as(usize, 2), dw.strWidth(kannada_2));

    // From Rust https://github.com/jameslanska/unicode-display-width
    try testing.expectEqual(@as(usize, 15), dw.strWidth("🔥🗡🍩👩🏻‍🚀⏰💃🏼🔦👍🏻"));
    try testing.expectEqual(@as(usize, 2), dw.strWidth("🦀"));
    try testing.expectEqual(@as(usize, 2), dw.strWidth("👨‍👩‍👧‍👧"));
    try testing.expectEqual(@as(usize, 2), dw.strWidth("👩‍🔬"));
    try testing.expectEqual(@as(usize, 9), dw.strWidth("sane text"));
    try testing.expectEqual(@as(usize, 9), dw.strWidth("Ẓ̌á̲l͔̝̞̄̑͌g̖̘̘̔̔͢͞͝o̪̔T̢̙̫̈̍͞e̬͈͕͌̏͑x̺̍ṭ̓̓ͅ"));
    try testing.expectEqual(@as(usize, 17), dw.strWidth("슬라바 우크라이나"));
    try testing.expectEqual(@as(usize, 1), dw.strWidth("\u{378}"));
}

/// centers `str` in a new string of width `total_width` (in display cells) using `pad` as padding.
/// If the length of `str` and `total_width` have different parity, the right side of `str` will
/// receive one additional pad. This makes sure the returned string fills the requested width.
/// Caller must free returned bytes with `allocator`.
pub fn center(
    dw: DisplayWidth,
    allocator: mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    const str_width = dw.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;
    if (str_width == total_width) return try allocator.dupe(u8, str);

    const pad_width = dw.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = @divFloor((total_width - str_width), 2);
    if (pad_width > margin_width) return error.PadTooLong;
    const extra_pad: usize = if (total_width % 2 != str_width % 2) 1 else 0;
    const pads = @divFloor(margin_width, pad_width) * 2 + extra_pad;

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    while (pads_index < pads / 2) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    @memcpy(result[bytes_index..][0..str.len], str);
    bytes_index += str.len;

    pads_index = 0;
    while (pads_index < pads / 2 + extra_pad) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    return result;
}

test "center" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    // Input and width both have odd length
    var centered = try dw.center(allocator, "abc", 9, "*");
    try testing.expectEqualSlices(u8, "***abc***", centered);

    // Input and width both have even length
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "---w😊w---", centered);

    // Input has even length, width has odd length
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "1234", 9, "-");
    try testing.expectEqualSlices(u8, "--1234---", centered);

    // Input has odd length, width has even length
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "123", 8, "-");
    try testing.expectEqualSlices(u8, "--123---", centered);

    // Input is the same length as the width
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "123", 3, "-");
    try testing.expectEqualSlices(u8, "123", centered);

    // Input is empty
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "", 3, "-");
    try testing.expectEqualSlices(u8, "---", centered);

    // Input is empty and width is zero
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "", 0, "-");
    try testing.expectEqualSlices(u8, "", centered);

    // Input is longer than the width, which is an error
    testing.allocator.free(centered);
    try testing.expectError(error.StrTooLong, dw.center(allocator, "123", 2, "-"));
}

/// padLeft returns a new string of width `total_width` (in display cells) using `pad` as padding
/// on the left side. Caller must free returned bytes with `allocator`.
pub fn padLeft(
    dw: DisplayWidth,
    allocator: mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    const str_width = dw.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;

    const pad_width = dw.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = total_width - str_width;
    if (pad_width > margin_width) return error.PadTooLong;

    const pads = @divFloor(margin_width, pad_width);

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    while (pads_index < pads) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    @memcpy(result[bytes_index..][0..str.len], str);

    return result;
}

test "padLeft" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    var right_aligned = try dw.padLeft(allocator, "abc", 9, "*");
    defer testing.allocator.free(right_aligned);
    try testing.expectEqualSlices(u8, "******abc", right_aligned);

    testing.allocator.free(right_aligned);
    right_aligned = try dw.padLeft(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "------w😊w", right_aligned);
}

/// padRight returns a new string of width `total_width` (in display cells) using `pad` as padding
/// on the right side.  Caller must free returned bytes with `allocator`.
pub fn padRight(
    dw: DisplayWidth,
    allocator: mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    const str_width = dw.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;

    const pad_width = dw.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = total_width - str_width;
    if (pad_width > margin_width) return error.PadTooLong;

    const pads = @divFloor(margin_width, pad_width);

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    @memcpy(result[bytes_index..][0..str.len], str);
    bytes_index += str.len;

    while (pads_index < pads) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    return result;
}

test "padRight" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    var left_aligned = try dw.padRight(allocator, "abc", 9, "*");
    defer testing.allocator.free(left_aligned);
    try testing.expectEqualSlices(u8, "abc******", left_aligned);

    testing.allocator.free(left_aligned);
    left_aligned = try dw.padRight(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "w😊w------", left_aligned);
}

/// Wraps a string approximately at the given number of colums per line.
/// `threshold` defines how far the last column of the last word can be
/// from the edge. Caller must free returned bytes with `allocator`.
pub fn wrap(
    dw: DisplayWidth,
    allocator: mem.Allocator,
    str: []const u8,
    columns: usize,
    threshold: usize,
) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    defer result.deinit();

    var line_iter = mem.tokenizeAny(u8, str, "\r\n");
    var line_width: usize = 0;

    while (line_iter.next()) |line| {
        var word_iter = mem.tokenizeScalar(u8, line, ' ');

        while (word_iter.next()) |word| {
            try result.appendSlice(word);
            try result.append(' ');
            line_width += dw.strWidth(word) + 1;

            if (line_width > columns or columns - line_width <= threshold) {
                try result.append('\n');
                line_width = 0;
            }
        }
    }

    // Remove trailing space and newline.
    _ = result.pop();
    _ = result.pop();

    return try result.toOwnedSlice();
}

test "wrap" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    const input = "The quick brown fox\r\njumped over the lazy dog!";
    const got = try dw.wrap(allocator, input, 10, 3);
    defer testing.allocator.free(got);
    const want = "The quick \nbrown fox \njumped \nover the \nlazy dog!";
    try testing.expectEqualStrings(want, got);
}

fn testAllocation(allocator: Allocator) !void {
    {
        var dw = try DisplayWidth.init(allocator);
        dw.deinit(allocator);
    }
    {
        var graph = try Graphemes.init(allocator);
        defer graph.deinit(allocator);
        var dw = try DisplayWidth.initWithGraphemes(allocator, graph);
        dw.deinit(allocator);
    }
}

test "allocation test" {
    try testing.checkAllAllocationFailures(testing.allocator, testAllocation, .{});
}

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const ArrayList = std.ArrayList;
const compress = std.compress;
const mem = std.mem;
const Allocator = mem.Allocator;
const simd = std.simd;
const testing = std.testing;

const ascii = @import("ascii");
const CodePointIterator = @import("code_point").Iterator;

const Graphemes = @import("Graphemes");
