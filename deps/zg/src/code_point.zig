//! Unicode Code Point module
//!
//! Provides a decoder and iterator over a UTF-8 encoded string.
//! Represents invalid data according to the Replacement of Maximal
//! Subparts algorithm.

pub const uoffset = if (@import("config").fat_offset) u64 else u32;

/// `CodePoint` represents a Unicode code point by its code,
/// length, and offset in the source bytes.
pub const CodePoint = struct {
    code: u21,
    len: u3,
    offset: uoffset,

    /// Return the slice of this codepoint, given the original string.
    pub inline fn bytes(cp: CodePoint, str: []const u8) []const u8 {
        return str[cp.offset..][0..cp.len];
    }

    pub fn format(cp: CodePoint, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("CodePoint '{u}' .{{ ", .{cp.code});
        try writer.print(
            ".code = 0x{x}, .offset = {d}, .len = {d} }}",
            .{ cp.code, cp.offset, cp.len },
        );
    }
};

/// This function is deprecated and will be removed in a later release.
/// Use `decodeAtIndex` or `decodeAtCursor`.
pub fn decode(bytes: []const u8, offset: uoffset) ?CodePoint {
    var off: uoffset = 0;
    var maybe_code = decodeAtCursor(bytes, &off);
    if (maybe_code) |*code| {
        code.offset = offset;
        return code.*;
    }
    return null;
}

/// Return the codepoint at `index`, even if `index` is in the middle
/// of that codepoint.
pub fn codepointAtIndex(bytes: []const u8, index: uoffset) ?CodePoint {
    var idx = index;
    while (idx > 0 and 0x80 <= bytes[idx] and bytes[idx] <= 0xbf) : (idx -= 1) {}
    return decodeAtIndex(bytes, idx);
}

/// Decode the CodePoint, if any, at `bytes[idx]`.
pub fn decodeAtIndex(bytes: []const u8, index: uoffset) ?CodePoint {
    var off = index;
    return decodeAtCursor(bytes, &off);
}

/// Decode the CodePoint, if any, at `bytes[cursor.*]`.  After, the
/// cursor will point at the next potential codepoint index.
pub fn decodeAtCursor(bytes: []const u8, cursor: *uoffset) ?CodePoint {
    // EOS
    if (cursor.* >= bytes.len) return null;

    const this_off = cursor.*;
    cursor.* += 1; // +1

    // ASCII
    var byte = bytes[this_off];
    if (byte < 0x80) return .{
        .code = byte,
        .offset = this_off,
        .len = 1,
    };
    // Multibyte

    // Second:
    var class: u4 = @intCast(u8dfa[byte]);
    var st: u32 = state_dfa[class];
    if (st == RUNE_REJECT or cursor.* == bytes.len) {
        @branchHint(.cold);
        // First one is never a truncation
        return .{
            .code = 0xfffd,
            .len = 1,
            .offset = this_off,
        };
    }
    var rune: u32 = byte & class_mask[class];
    byte = bytes[cursor.*];
    class = @intCast(u8dfa[byte]);
    st = state_dfa[st + class];
    rune = (byte & 0x3f) | (rune << 6);
    cursor.* += 1; // +2
    if (st == RUNE_ACCEPT) {
        return .{
            .code = @intCast(rune),
            .len = 2,
            .offset = this_off,
        };
    }
    if (st == RUNE_REJECT or cursor.* == bytes.len) {
        @branchHint(.cold);
        // Truncation and other bad bytes the same here:
        cursor.* -= 1; // + 1
        return .{
            .code = 0xfffd,
            .len = 1,
            .offset = this_off,
        };
    }
    // Third
    byte = bytes[cursor.*];
    class = @intCast(u8dfa[byte]);
    st = state_dfa[st + class];
    rune = (byte & 0x3f) | (rune << 6);
    cursor.* += 1; // +3
    if (st == RUNE_ACCEPT) {
        return .{
            .code = @intCast(rune),
            .len = 3,
            .offset = this_off,
        };
    }
    if (st == RUNE_REJECT or cursor.* == bytes.len) {
        @branchHint(.cold);
        // This, and the branch below, detect truncation, the
        // only invalid state handled differently by the Maximal
        // Subparts algorithm.
        if (state_dfa[@intCast(u8dfa[byte])] == RUNE_REJECT) {
            cursor.* -= 2; // +1
            return .{
                .code = 0xfffd,
                .len = 1,
                .offset = this_off,
            };
        } else {
            cursor.* -= 1; // +2
            return .{
                .code = 0xfffd,
                .len = 2,
                .offset = this_off,
            };
        }
    }
    byte = bytes[cursor.*];
    class = @intCast(u8dfa[byte]);
    st = state_dfa[st + class];
    rune = (byte & 0x3f) | (rune << 6);
    cursor.* += 1; // +4
    if (st == RUNE_REJECT) {
        @branchHint(.cold);
        if (state_dfa[@intCast(u8dfa[byte])] == RUNE_REJECT) {
            cursor.* -= 3; // +1
            return .{
                .code = 0xfffd,
                .len = 1,
                .offset = this_off,
            };
        } else {
            cursor.* -= 1; // +3
            return .{
                .code = 0xfffd,
                .len = 3,
                .offset = this_off,
            };
        }
    }
    assert(st == RUNE_ACCEPT);
    return .{
        .code = @intCast(rune),
        .len = 4,
        .offset = this_off,
    };
}

/// `Iterator` iterates a string one `CodePoint` at-a-time.
pub const Iterator = struct {
    bytes: []const u8,
    i: uoffset = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes, .i = 0 };
    }

    pub fn next(self: *Iterator) ?CodePoint {
        return decodeAtCursor(self.bytes, &self.i);
    }

    pub fn peek(iter: *Iterator) ?CodePoint {
        const saved_i = iter.i;
        defer iter.i = saved_i;
        return iter.next();
    }

    /// Create a backward iterator at this point.  It will repeat
    /// the last CodePoint seen.
    pub fn reverseIterator(iter: *const Iterator) ReverseIterator {
        if (iter.i == iter.bytes.len) {
            return .init(iter.bytes);
        }
        return .{ .i = iter.i, .bytes = iter.bytes };
    }
};

// A fast DFA decoder for UTF-8
//
// The algorithm used aims to be optimal, without involving SIMD, this
// strikes a balance between portability and efficiency.  That is done
// by using a DFA, represented as a few lookup tables, to track state,
// encoding valid transitions between bytes, arriving at 0 each time a
// codepoint is decoded.  In the process it builds up the value of the
// codepoint in question.
//
// The virtue of such an approach is low branching factor, achieved at
// a modest cost of storing the tables.  An embedded system might want
// to use a more familiar decision graph based on switches, but modern
// hosted environments can well afford the space, and may appreciate a
// speed increase in exchange.
//
// Credit for the algorithm goes to Björn Höhrmann, who wrote it up at
// https://bjoern.hoehrmann.de/utf-8/decoder/dfa/ .  The original
// license may be found in the ./credits folder.
//

/// Successful codepoint parse
const RUNE_ACCEPT = 0;

/// Error state
const RUNE_REJECT = 12;

/// Byte transitions: value to class
const u8dfa: [256]u8 = .{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 00..1f
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 20..3f
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 40..5f
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 60..7f
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 80..9f
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // a0..bf
    8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // c0..df
    0xa, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x4, 0x3, 0x3, // e0..ef
    0xb, 0x6, 0x6, 0x6, 0x5, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, // f0..ff
};

/// State transition: state + class = new state
const state_dfa: [108]u8 = .{
    0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, // 0  (RUNE_ACCEPT)
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, // 12 (RUNE_REJECT)
    12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12, // 24
    12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12, // 32
    12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, // 48
    12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12, // 60
    12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, // 72
    12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, // 84
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, // 96
};

/// State masks
const class_mask: [12]u8 = .{
    0xff,
    0,
    0b0011_1111,
    0b0001_1111,
    0b0000_1111,
    0b0000_0111,
    0b0000_0011,
    0,
    0,
    0,
    0,
    0,
};

pub const ReverseIterator = struct {
    bytes: []const u8,
    i: ?uoffset,

    pub fn init(str: []const u8) ReverseIterator {
        var r_iter: ReverseIterator = undefined;
        r_iter.bytes = str;
        r_iter.i = if (str.len == 0) 0 else @intCast(str.len - 1);
        return r_iter;
    }

    pub fn prev(iter: *ReverseIterator) ?CodePoint {
        if (iter.i == null) return null;
        var i_prev = iter.i.?;

        while (i_prev > 0) : (i_prev -= 1) {
            if (!followbyte(iter.bytes[i_prev])) break;
        }

        if (i_prev > 0)
            iter.i = i_prev - 1
        else
            iter.i = null;

        return decode(iter.bytes[i_prev..], i_prev);
    }

    pub fn peek(iter: *ReverseIterator) ?CodePoint {
        const saved_i = iter.i;
        defer iter.i = saved_i;
        return iter.prev();
    }

    /// Create a forward iterator at this point.  It will repeat the
    /// last CodePoint seen.
    pub fn forwardIterator(iter: *const ReverseIterator) Iterator {
        if (iter.i) |i| {
            var fwd: Iterator = .{ .i = i, .bytes = iter.bytes };
            _ = fwd.next();
            return fwd;
        }
        return .{ .i = 0, .bytes = iter.bytes };
    }
};

inline fn followbyte(b: u8) bool {
    return 0x80 <= b and b <= 0xbf;
}

test "decode" {
    const bytes = "🌩️";
    const res = decode(bytes, 0);

    if (res) |cp| {
        try std.testing.expectEqual(@as(u21, 0x1F329), cp.code);
        try std.testing.expectEqual(4, cp.len);
    } else {
        // shouldn't have failed to return
        try std.testing.expect(false);
    }
}

test Iterator {
    var iter = Iterator{ .bytes = "Hi" };

    try expectEqual(@as(u21, 'H'), iter.next().?.code);
    try expectEqual(@as(u21, 'i'), iter.peek().?.code);
    try expectEqual(@as(u21, 'i'), iter.next().?.code);
    try expectEqual(@as(?CodePoint, null), iter.peek());
    try expectEqual(@as(?CodePoint, null), iter.next());
}

const code_point = @This();

// Keep this in sync with the README
test "Code point iterator" {
    const str = "Hi 😊";
    var iter: code_point.Iterator = .init(str);
    var i: usize = 0;

    while (iter.next()) |cp| : (i += 1) {
        // The `code` field is the actual code point scalar as a `u21`.
        if (i == 0) try expect(cp.code == 'H');
        if (i == 1) try expect(cp.code == 'i');
        if (i == 2) try expect(cp.code == ' ');

        if (i == 3) {
            try expect(cp.code == '😊');
            // The `offset` field is the byte offset in the
            // source string.
            try expect(cp.offset == 3);
            try expectEqual(cp, code_point.decodeAtIndex(str, cp.offset).?);
            // The `len` field is the length in bytes of the
            // code point in the source string.
            try expect(cp.len == 4);
            // There is also a 'cursor' decode, like so:
            {
                var cursor = cp.offset;
                try expectEqual(cp, code_point.decodeAtCursor(str, &cursor).?);
                // Which advances the cursor variable to the next possible
                // offset, in this case, `str.len`.  Don't forget to account
                // for this possibility!
                try expectEqual(cp.offset + cp.len, cursor);
            }
            // There's also this, for when you aren't sure if you have the
            // correct start for a code point:
            try expectEqual(cp, code_point.codepointAtIndex(str, cp.offset + 1).?);
        }
        // Reverse iteration is also an option:
        var r_iter: code_point.ReverseIterator = .init(str);
        // Both iterators can be peeked:
        try expectEqual('😊', r_iter.peek().?.code);
        try expectEqual('😊', r_iter.prev().?.code);
        // Both kinds of iterators can be reversed:
        var fwd_iter = r_iter.forwardIterator(); // or iter.reverseIterator();
        // This will always return the last codepoint from
        // the prior iterator, _if_ it yielded one:
        try expectEqual('😊', fwd_iter.next().?.code);
    }
}
test "overlongs" {
    // None of these should equal `/`, all should be byte-for-byte
    // handled as replacement characters.
    {
        const bytes = "\xc0\xaf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expect('/' != first.code);
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
    }
    {
        const bytes = "\xe0\x80\xaf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expect('/' != first.code);
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(1, third.len);
    }
    {
        const bytes = "\xf0\x80\x80\xaf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expect('/' != first.code);
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(1, third.len);
        const fourth = iter.next().?;
        try expectEqual(0xfffd, fourth.code);
        try testing.expectEqual(1, fourth.len);
    }
}

test "surrogates" {
    // Substitution of Maximal Subparts dictates a
    // replacement character for each byte of a surrogate.
    {
        const bytes = "\xed\xad\xbf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(1, third.len);
    }
}

test "truncation" {
    // Truncation must return one (1) replacement
    // character for each stem of a valid UTF-8 codepoint
    // Sample from Table 3-11 of the Unicode Standard 16.0.0
    {
        const bytes = "\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(2, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(3, third.len);
        const fourth = iter.next().?;
        try expectEqual(0xfffd, fourth.code);
        try testing.expectEqual(2, fourth.len);
        const fifth = iter.next().?;
        try expectEqual(0x41, fifth.code);
        try testing.expectEqual(1, fifth.len);
    }
}

test ReverseIterator {
    {
        var r_iter: ReverseIterator = .init("ABC");
        try testing.expectEqual(@as(u21, 'C'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, 'B'), r_iter.peek().?.code);
        try testing.expectEqual(@as(u21, 'B'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, 'A'), r_iter.prev().?.code);
        try testing.expectEqual(@as(?CodePoint, null), r_iter.peek());
        try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
        try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
    }
    {
        var r_iter: ReverseIterator = .init("∅δq🦾ă");
        try testing.expectEqual(@as(u21, 'ă'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, '🦾'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, 'q'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, 'δ'), r_iter.peek().?.code);
        try testing.expectEqual(@as(u21, 'δ'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, '∅'), r_iter.peek().?.code);
        try testing.expectEqual(@as(u21, '∅'), r_iter.peek().?.code);
        try testing.expectEqual(@as(u21, '∅'), r_iter.prev().?.code);
        try testing.expectEqual(@as(?CodePoint, null), r_iter.peek());
        try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
        try testing.expectEqual(@as(?CodePoint, null), r_iter.prev());
    }
    {
        var r_iter: ReverseIterator = .init("123");
        try testing.expectEqual(@as(u21, '3'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, '2'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, '1'), r_iter.prev().?.code);
        var iter = r_iter.forwardIterator();
        try testing.expectEqual(@as(u21, '1'), iter.next().?.code);
        try testing.expectEqual(@as(u21, '2'), iter.next().?.code);
        try testing.expectEqual(@as(u21, '3'), iter.next().?.code);
        r_iter = iter.reverseIterator();
        try testing.expectEqual(@as(u21, '3'), r_iter.prev().?.code);
        try testing.expectEqual(@as(u21, '2'), r_iter.prev().?.code);
        iter = r_iter.forwardIterator();
        r_iter = iter.reverseIterator();
        try testing.expectEqual(@as(u21, '2'), iter.next().?.code);
        try testing.expectEqual(@as(u21, '2'), r_iter.prev().?.code);
    }
}

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const assert = std.debug.assert;
