//! Graphemes Module
//!
//! Code for handling graphemes: fragments of string which should be
//! treated as one unit.  Like Farmer Bob here: 👨🏻‍🌾

s1: []u16 = undefined,
s2: []u16 = undefined,
s3: []u8 = undefined,

const Graphemes = @This();

pub fn init(allocator: Allocator) Allocator.Error!Graphemes {
    var graphemes = Graphemes{};
    try graphemes.setup(allocator);
    return graphemes;
}

pub fn setup(graphemes: *Graphemes, allocator: Allocator) Allocator.Error!void {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("gbp");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();

    const s1_len: u16 = reader.readInt(u16, endian) catch unreachable;
    graphemes.s1 = try allocator.alloc(u16, s1_len);
    errdefer allocator.free(graphemes.s1);
    for (0..s1_len) |i| graphemes.s1[i] = reader.readInt(u16, endian) catch unreachable;

    const s2_len: u16 = reader.readInt(u16, endian) catch unreachable;
    graphemes.s2 = try allocator.alloc(u16, s2_len);
    errdefer allocator.free(graphemes.s2);
    for (0..s2_len) |i| graphemes.s2[i] = reader.readInt(u16, endian) catch unreachable;

    const s3_len: u16 = reader.readInt(u16, endian) catch unreachable;
    graphemes.s3 = try allocator.alloc(u8, s3_len);
    errdefer allocator.free(graphemes.s3);
    _ = reader.readAll(graphemes.s3) catch unreachable;
}

pub fn deinit(graphemes: *const Graphemes, allocator: Allocator) void {
    allocator.free(graphemes.s1);
    allocator.free(graphemes.s2);
    allocator.free(graphemes.s3);
}

/// Lookup the grapheme break property for a code point.
pub fn gbp(graphemes: Graphemes, cp: u21) Gbp {
    return @enumFromInt(graphemes.s3[graphemes.s2[graphemes.s1[cp >> 8] + (cp & 0xff)]] >> 4);
}

/// Lookup the indic syllable type for a code point.
pub fn indic(graphemes: Graphemes, cp: u21) Indic {
    return @enumFromInt((graphemes.s3[graphemes.s2[graphemes.s1[cp >> 8] + (cp & 0xff)]] >> 1) & 0x7);
}

/// Lookup the emoji property for a code point.
pub fn isEmoji(graphemes: Graphemes, cp: u21) bool {
    return graphemes.s3[graphemes.s2[graphemes.s1[cp >> 8] + (cp & 0xff)]] & 1 == 1;
}

/// Returns an iterator over the graphemes in `string`.
pub fn iterator(graphemes: *const Graphemes, string: []const u8) Iterator {
    return Iterator.init(string, graphemes);
}

/// Returns a reverse iterator over the graphemes in `string`.
pub fn reverseIterator(graphemes: *const Graphemes, string: []const u8) ReverseIterator {
    return ReverseIterator.init(string, graphemes);
}

/// Indic syllable type.
pub const Indic = enum {
    none,

    Consonant,
    Extend,
    Linker,
};

/// Grapheme break property.
pub const Gbp = enum {
    none,
    Control,
    CR,
    Extend,
    L,
    LF,
    LV,
    LVT,
    Prepend,
    Regional_Indicator,
    SpacingMark,
    T,
    V,
    ZWJ,
};

/// `Grapheme` represents a Unicode grapheme cluster by its length and offset in the source bytes.
pub const Grapheme = struct {
    len: uoffset,
    offset: uoffset,

    /// `bytes` returns the slice of bytes that correspond to
    /// this grapheme cluster in `src`.
    pub fn bytes(self: Grapheme, src: []const u8) []const u8 {
        return src[self.offset..][0..self.len];
    }
};

// NOTE: graphemeAtIndex is, probably, not in an optimal form.  It has the advantage
// of being composed of other parts, but the constant factor can _probably_ be improved
// by a bespoke implmentation using graphemes.graphemeBreak directly.  There's a limit
// to how much cycle-bumming I'm willing to do at any given moment; that limit has been
// reached.  Perhaps you, Dear Reader, might pick up the torch?

/// Returns the `Grapheme` at `string[index]`, which does not have to be a
/// valid start of a codepoint.  Asserts the string is not empty.  Index must be
/// less than `string.len`.  Always returns a `Grapheme`.
pub fn graphemeAtIndex(graphemes: *const Graphemes, string: []const u8, index: usize) Grapheme {
    assert(string.len != 0);
    if (index == 0 or (index > 0 and
        string[index] < 0x80 and
        string[index - 1] < 0x80) and
        (string[index - 1] != '\r' and string[index] != '\n'))
    {
        // There's always a grapheme break between two ASCII code points (except CRLF)
        var iter = graphemes.iterator(string[index..]);
        const next = iter.next().?;
        return Grapheme{
            .len = next.len,
            .offset = @as(u32, @intCast(index)) + next.offset,
        };
    } // Otherwise it gets hairy.
    const idx: uoffset = code_point.codepointAtIndex(string, @intCast(index)).?.offset;
    if (idx == string.len) {
        var iter = graphemes.reverseIterator(string);
        return iter.prev().?;
    }
    // We're on a valid codepoint boundary, we go back from here
    var r_iter = graphemes.reverseIterAtIndex(string, idx);
    if (r_iter.prev()) |g| {
        if (g.offset == 0) {
            var iter = graphemes.iterator(string);
            while (iter.next()) |g2| {
                if (g2.offset <= idx and idx < g2.offset + g2.len) return g2;
            }
        }
    }
    // We need to toss one, because otherwise we might not be pending when
    // we in fact need to be.
    _ = r_iter.prev();
    while (r_iter.pending != .none) : (_ = r_iter.prev()) {}
    var iter = graphemes.iterAtIndex(string, r_iter.cp_iter.i orelse 0);
    while (iter.next()) |g| {
        if (g.offset <= idx and idx < g.offset + g.len) return g;
    }
    unreachable;
}

/// Return a (forward) iterator of `string` after `grapheme`.
pub fn iterateAfterGrapheme(graphemes: *const Graphemes, string: []const u8, grapheme: Grapheme) Iterator {
    return graphemes.iterAtIndex(string, grapheme.offset + grapheme.len);
}

/// Return a reverse iterator of `string` before `grapheme`.
pub fn iterateBeforeGrapheme(graphemes: *const Graphemes, string: []const u8, grapheme: Grapheme) ReverseIterator {
    // This bit of weirdness is because reverse iterators are "advance last",
    // while forward iterators are "advance first".  This leaves some room for
    // further optimization, if anyone dares.
    var r_iter = graphemes.reverseIterAtIndex(string, grapheme.offset + grapheme.len - 1);
    _ = r_iter.prev();
    return r_iter;
}

fn reverseIterAtIndex(graphemes: *const Graphemes, string: []const u8, idx: uoffset) ReverseIterator {
    var r_iter: ReverseIterator = undefined;
    r_iter.data = graphemes;
    var rcp_iter: CodePointReverseIterator = .{ .bytes = string, .i = idx };
    r_iter.buf[1] = rcp_iter.prev();
    r_iter.buf[0] = rcp_iter.prev();
    r_iter.pending = .none;
    r_iter.cp_iter = rcp_iter;
    return r_iter;
}

fn iterAtIndex(graphemes: *const Graphemes, string: []const u8, idx: uoffset) Iterator {
    var iter: Iterator = undefined;
    iter.data = graphemes;
    iter.buf[0] = first: {
        if (idx == string.len) break :first null;
        var r_cp_iter: CodePointReverseIterator = .{ .bytes = string, .i = idx };
        break :first r_cp_iter.prev();
    };
    var cp_iter: CodePointIterator = .{ .bytes = string, .i = idx };
    iter.buf[1] = cp_iter.next();
    iter.cp_iter = cp_iter;
    return iter;
}

/// `Iterator` iterates a sting of UTF-8 encoded bytes one grapheme cluster at-a-time.
pub const Iterator = struct {
    buf: [2]?CodePoint = .{ null, null },
    cp_iter: CodePointIterator,
    data: *const Graphemes,

    const Self = @This();

    /// Assumes `src` is valid UTF-8.
    pub fn init(str: []const u8, data: *const Graphemes) Self {
        var self = Self{ .cp_iter = .{ .bytes = str }, .data = data };
        self.advance();
        return self;
    }

    fn advance(self: *Self) void {
        self.buf[0] = self.buf[1];
        self.buf[1] = self.cp_iter.next();
    }

    pub fn next(self: *Self) ?Grapheme {
        self.advance();

        // If no more
        if (self.buf[0] == null) return null;
        // If last one
        if (self.buf[1] == null) return Grapheme{ .len = self.buf[0].?.len, .offset = self.buf[0].?.offset };
        // If ASCII
        if (self.buf[0].?.code != '\r' and self.buf[0].?.code < 128 and self.buf[1].?.code < 128) {
            return Grapheme{ .len = self.buf[0].?.len, .offset = self.buf[0].?.offset };
        }

        const gc_start = self.buf[0].?.offset;
        var gc_len: u8 = self.buf[0].?.len;
        var state = IterState{};

        if (graphemeBreak(
            self.buf[0].?.code,
            self.buf[1].?.code,
            self.data,
            &state,
        )) return Grapheme{ .len = gc_len, .offset = gc_start };

        while (true) {
            self.advance();
            if (self.buf[0] == null) break;

            gc_len += self.buf[0].?.len;

            if (graphemeBreak(
                self.buf[0].?.code,
                if (self.buf[1]) |ncp| ncp.code else 0,
                self.data,
                &state,
            )) break;
        }

        return Grapheme{ .len = gc_len, .offset = gc_start };
    }

    pub fn peek(self: *Self) ?Grapheme {
        const saved_cp_iter = self.cp_iter;
        const s0 = self.buf[0];
        const s1 = self.buf[1];
        defer {
            self.cp_iter = saved_cp_iter;
            self.buf[0] = s0;
            self.buf[1] = s1;
        }
        return self.next();
    }
};

/// Iterate a string backward by Grapheme.
pub const ReverseIterator = struct {
    buf: [2]?CodePoint = .{ null, null },
    cp_iter: CodePointReverseIterator,
    data: *const Graphemes,
    /// Codepoint read from `cp_iter` but not returned by `previous`
    pending: Pending = .none,

    const Pending = union(enum) {
        none: void,
        /// Count of pending RI codepoints, it is an even number
        ri_count: usize,
        /// End of (Extend* ZWJ) sequence pending from failed GB11: !Emoji Extend* ZWJ x Emoji
        extend_end: uoffset,
    };

    const Self = @This();

    pub fn init(str: []const u8, data: *const Graphemes) Self {
        var self: Self = .{ .cp_iter = .init(str), .data = data };
        self.advance();
        self.advance();
        return self;
    }

    fn advance(self: *Self) void {
        self.buf[1] = self.buf[0];
        self.buf[0] = self.cp_iter.prev();
    }

    pub fn peek(self: *Self) ?Grapheme {
        const cache = .{ self.buf, self.cp_iter, self.pending };
        defer self.buf, self.cp_iter, self.pending = cache;
        return self.prev();
    }

    pub fn prev(self: *Self) ?Grapheme {
        if (self.buf[1] == null) return null;

        const grapheme_end: uoffset = end: {
            const codepoint = self.buf[1].?;

            switch (self.pending) {
                // BUF: [?Any, Any]
                .none => break :end codepoint.offset + codepoint.len,
                .ri_count => |ri_count| {
                    std.debug.assert(ri_count > 0);
                    std.debug.assert(ri_count % 2 == 0);

                    if (ri_count > 2) {
                        self.pending.ri_count -= 2;

                        // Use the fact that all RI have length 4 in utf8 encoding
                        // since they are in range 0x1f1e6...0x1f1ff
                        // https://en.wikipedia.org/wiki/UTF-8#Encoding
                        return Grapheme{
                            .len = 8,
                            .offset = @intCast(codepoint.offset + self.pending.ri_count * 4),
                        };
                    } else {
                        self.pending = .{ .none = {} };
                        break :end codepoint.offset + codepoint.len + 4;
                    }
                },
                // BUF: [?Any, Extend] Extend* ZWJ
                .extend_end => |extend_end| {
                    self.pending = .{ .none = {} };
                    break :end extend_end;
                },
            }
        };

        while (self.buf[0] != null) {
            var state: IterState = .{};
            state.xpic = true;
            state.regional = false;
            state.indic = true;

            if (graphemeBreak(
                self.buf[0].?.code,
                self.buf[1].?.code,
                self.data,
                &state,
            )) break;

            self.advance();

            if (!state.indic) {

                // BUF: [?Any, Extend | Linker] Consonant
                var indic_offset: uoffset = self.buf[1].?.offset + self.buf[1].?.len;

                indic: while (true) {
                    if (self.buf[0] == null) {
                        self.pending = .{ .extend_end = indic_offset };
                        return .{
                            .len = @intCast(grapheme_end - indic_offset),
                            .offset = indic_offset,
                        };
                    }

                    const codepoint = self.buf[0].?;

                    switch (self.data.indic(codepoint.code)) {
                        .Extend, .Linker => {
                            self.advance();
                            continue :indic;
                        },
                        .Consonant => {
                            // BUF: [Consonant, Extend | Linker] (Extend | Linker)* Consonant
                            indic_offset = codepoint.offset;
                            self.advance();

                            if (self.buf[0]) |cp1| {
                                state.indic = true;

                                if (graphemeBreak(cp1.code, self.buf[1].?.code, self.data, &state)) break;

                                if (!state.indic) {
                                    continue :indic;
                                } else {
                                    break :indic;
                                }
                            } else {
                                break :indic;
                            }
                        },
                        .none => {
                            // BUF: [Any, Extend | Linker] (Extend | Linker)* Consonant
                            self.pending = .{ .extend_end = indic_offset };
                            return .{
                                .len = @intCast(grapheme_end - indic_offset),
                                .offset = indic_offset,
                            };
                        },
                    }
                }
            }

            if (!state.xpic) {
                // BUF: [?Any, ZWJ] Emoji
                var emoji_offset: uoffset = self.buf[1].?.offset + self.buf[1].?.len;

                // Look for previous Emoji
                emoji: while (true) {
                    if (self.buf[0] == null) {
                        self.pending = .{ .extend_end = emoji_offset };
                        return .{
                            .len = @intCast(grapheme_end - emoji_offset),
                            .offset = emoji_offset,
                        };
                    }

                    const codepoint = self.buf[0].?;

                    if (self.data.gbp(codepoint.code) == .Extend) {
                        self.advance();
                        continue :emoji;
                    }

                    if (self.data.isEmoji(codepoint.code)) {
                        // BUF: [Emoji, Extend] (Extend* ZWJ Emoji)*
                        emoji_offset = codepoint.offset;
                        self.advance();

                        if (self.buf[0] != null and
                            // ZWJ = 0x200d
                            self.buf[0].?.code == 0x200d)
                        {
                            // BUF: [ZWJ, Emoji] (Extend* ZWJ Emoji)*
                            // Back at the beginning of the loop, "recursively" look for emoji
                            self.advance();
                            continue :emoji;
                        } else {
                            // BUF: [?Any, Emoji] (Extend* ZWJ Emoji)*
                            break :emoji;
                        }
                    } else {
                        // BUF: [Any, Extend] (Extend* ZWJ Emoji)*
                        self.pending = .{ .extend_end = emoji_offset };
                        return .{
                            .len = @intCast(grapheme_end - emoji_offset),
                            .offset = emoji_offset,
                        };
                    }
                }
            }

            if (state.regional) {
                var ri_count: usize = 0;
                while (self.buf[0] != null and
                    self.data.gbp(self.buf[0].?.code) == .Regional_Indicator)
                {
                    ri_count += 1;
                    self.advance();
                }

                // Use the fact that all RI have length 4 in utf8 encoding
                // since they are in range 0x1f1e6...0x1f1ff
                // https://en.wikipedia.org/wiki/UTF-8#Encoding
                if (ri_count == 0) {
                    // There are no pending RI codepoints
                } else if (ri_count % 2 == 0) {
                    self.pending = .{ .ri_count = ri_count };
                    return .{ .len = 8, .offset = grapheme_end - 8 };
                } else {
                    // Add one to count for the unused RI
                    self.pending = .{ .ri_count = ri_count + 1 };
                    return .{ .len = 4, .offset = grapheme_end - 4 };
                }
            }
        }

        const grapheme_start = if (self.buf[1]) |codepoint| codepoint.offset else 0;
        self.advance();
        return .{
            .len = @intCast(grapheme_end - grapheme_start),
            .offset = grapheme_start,
        };
    }
};

/// Grapheme Iterator state.
pub const IterState = packed struct(u3) {
    xpic: bool = false,
    regional: bool = false,
    indic: bool = false,
};

// Predicates
fn isBreaker(cp: u21, data: *const Graphemes) bool {
    // Extract relevant properties.
    const cp_gbp_prop = data.gbp(cp);
    return cp == '\x0d' or cp == '\x0a' or cp_gbp_prop == .Control;
}

/// `graphemeBreak` returns true only if a grapheme break point is required
/// between `cp1` and `cp2`. `state` should start out as 0. If calling
/// iteratively over a sequence of code points, this function must be called
/// IN ORDER on ALL potential breaks in a string.
/// Modeled after the API of utf8proc's `utf8proc_grapheme_break_stateful`.
/// https://github.com/JuliaStrings/utf8proc/blob/2bbb1ba932f727aad1fab14fafdbc89ff9dc4604/utf8proc.h#L599-L617
pub fn graphemeBreak(
    cp1: u21,
    cp2: u21,
    data: *const Graphemes,
    state: *IterState,
) bool {
    // Extract relevant properties.
    const cp1_gbp_prop = data.gbp(cp1);
    const cp1_indic_prop = data.indic(cp1);
    const cp1_is_emoji = data.isEmoji(cp1);

    const cp2_gbp_prop = data.gbp(cp2);
    const cp2_indic_prop = data.indic(cp2);
    const cp2_is_emoji = data.isEmoji(cp2);

    // GB11: Emoji Extend* ZWJ x Emoji
    if (!state.xpic and cp1_is_emoji) state.xpic = true;
    // GB9c: Indic Conjunct Break
    if (!state.indic and cp1_indic_prop == .Consonant) state.indic = true;

    // GB3: CR x LF
    if (cp1 == '\r' and cp2 == '\n') return false;

    // GB4: Control
    if (isBreaker(cp1, data)) return true;

    // GB11: Emoji Extend* ZWJ x Emoji
    if (state.xpic and
        cp1_gbp_prop == .ZWJ and
        cp2_is_emoji)
    {
        state.xpic = false;
        return false;
    }

    // GB9b: x (Extend | ZWJ)
    if (cp2_gbp_prop == .Extend or cp2_gbp_prop == .ZWJ) return false;

    // GB9a: x Spacing
    if (cp2_gbp_prop == .SpacingMark) return false;

    // GB9b: Prepend x
    if (cp1_gbp_prop == .Prepend and !isBreaker(cp2, data)) return false;

    // GB12, GB13: RI x RI
    if (cp1_gbp_prop == .Regional_Indicator and cp2_gbp_prop == .Regional_Indicator) {
        if (state.regional) {
            state.regional = false;
            return true;
        } else {
            state.regional = true;
            return false;
        }
    }

    // GB6: Hangul L x (L|V|LV|VT)
    if (cp1_gbp_prop == .L) {
        if (cp2_gbp_prop == .L or
            cp2_gbp_prop == .V or
            cp2_gbp_prop == .LV or
            cp2_gbp_prop == .LVT) return false;
    }

    // GB7: Hangul (LV | V) x (V | T)
    if (cp1_gbp_prop == .LV or cp1_gbp_prop == .V) {
        if (cp2_gbp_prop == .V or
            cp2_gbp_prop == .T) return false;
    }

    // GB8: Hangul (LVT | T) x T
    if (cp1_gbp_prop == .LVT or cp1_gbp_prop == .T) {
        if (cp2_gbp_prop == .T) return false;
    }

    // GB9c: Indic Conjunct Break
    if (state.indic and
        cp1_indic_prop == .Consonant and
        (cp2_indic_prop == .Extend or cp2_indic_prop == .Linker))
    {
        return false;
    }

    if (state.indic and
        cp1_indic_prop == .Extend and
        cp2_indic_prop == .Linker)
    {
        return false;
    }

    if (state.indic and
        (cp1_indic_prop == .Linker or cp1_gbp_prop == .ZWJ) and
        cp2_indic_prop == .Consonant)
    {
        state.indic = false;
        return false;
    }

    return true;
}

test "Segmentation ZWJ and ZWSP emoji sequences" {
    const seq_1 = "\u{1F43B}\u{200D}\u{2744}\u{FE0F}";
    const seq_2 = "\u{1F43B}\u{200D}\u{2744}\u{FE0F}";
    const with_zwj = seq_1 ++ "\u{200D}" ++ seq_2;
    const with_zwsp = seq_1 ++ "\u{200B}" ++ seq_2;
    const no_joiner = seq_1 ++ seq_2;

    const graphemes = try Graphemes.init(std.testing.allocator);
    defer graphemes.deinit(std.testing.allocator);

    {
        var iter = graphemes.iterator(with_zwj);
        var i: usize = 0;
        while (iter.next()) |_| : (i += 1) {}
        try std.testing.expectEqual(@as(usize, 1), i);
    }

    {
        var iter = graphemes.iterator(with_zwsp);
        var i: usize = 0;
        while (iter.next()) |_| : (i += 1) {}
        try std.testing.expectEqual(@as(usize, 3), i);
    }

    {
        var iter = graphemes.iterator(no_joiner);
        var i: usize = 0;
        while (iter.next()) |_| : (i += 1) {}
        try std.testing.expectEqual(@as(usize, 2), i);
    }
}

test "Iterator.peek" {
    const peek_seq = "aΔ👨🏻‍🌾→";
    const data = try Graphemes.init(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    var iter = data.iterator(peek_seq);
    const peek_a = iter.peek().?;
    const next_a = iter.next().?;
    try std.testing.expectEqual(peek_a, next_a);
    try std.testing.expectEqualStrings("a", peek_a.bytes(peek_seq));
    const peek_d1 = iter.peek().?;
    const peek_d2 = iter.peek().?;
    try std.testing.expectEqual(peek_d1, peek_d2);
    const next_d = iter.next().?;
    try std.testing.expectEqual(peek_d2, next_d);
    try std.testing.expectEqual(iter.peek(), iter.next());
    try std.testing.expectEqual(iter.peek(), iter.next());
    try std.testing.expectEqual(null, iter.peek());
    try std.testing.expectEqual(null, iter.peek());
    try std.testing.expectEqual(iter.peek(), iter.next());
}

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const compress = std.compress;
const unicode = std.unicode;

const code_point = @import("code_point");
const CodePoint = code_point.CodePoint;
const CodePointIterator = code_point.Iterator;
const CodePointReverseIterator = code_point.ReverseIterator;
const uoffset = code_point.uoffset;
