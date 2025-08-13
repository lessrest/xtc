//! Word Breaking Algorithm.
//!
//! https://www.unicode.org/reports/tr29/#Word_Boundaries
//!

const WordBreakProperty = enum(u5) {
    none,
    Double_Quote,
    Single_Quote,
    Hebrew_Letter,
    CR,
    LF,
    Newline,
    Extend,
    Regional_Indicator,
    Format,
    Katakana,
    ALetter,
    MidLetter,
    MidNum,
    MidNumLet,
    Numeric,
    ExtendNumLet,
    ZWJ,
    WSegSpace,
};

s1: []u16 = undefined,
s2: []u5 = undefined,

const Words = @This();

pub fn init(allocator: Allocator) Allocator.Error!Words {
    var wb: Words = undefined;
    try wb.setup(allocator);
    return wb;
}

pub fn setup(wb: *Words, allocator: Allocator) Allocator.Error!void {
    wb.setupImpl(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
}

pub fn deinit(words: *const Words, allocator: mem.Allocator) void {
    allocator.free(words.s1);
    allocator.free(words.s2);
}

/// Represents a Unicode word span, as an offset into the source string
/// and the length of the word.
pub const Word = struct {
    offset: uoffset,
    len: uoffset,

    /// Returns a slice of the word given the source string.
    pub fn bytes(word: Word, src: []const u8) []const u8 {
        return src[word.offset..][0..word.len];
    }
};

/// Returns the word break property type for `cp`.
pub fn breakProperty(words: *const Words, cp: u21) WordBreakProperty {
    return @enumFromInt(words.s2[words.s1[cp >> 8] + (cp & 0xff)]);
}

/// Convenience function for working with CodePoints
fn breakProp(words: *const Words, point: CodePoint) WordBreakProperty {
    return @enumFromInt(words.s2[words.s1[point.code >> 8] + (point.code & 0xff)]);
}

/// Returns the Word at the given index.  Asserts that the index is less than
/// `string.len`, and that the string is not empty. Always returns a word.
/// The index does not have to be the start of a codepoint in the word.
pub fn wordAtIndex(words: *const Words, string: []const u8, index: usize) Word {
    assert(index < string.len and string.len > 0);
    var iter_back: ReverseIterator = reverseFromIndex(words, string, index);
    const first_back = iter_back.prev();
    if (first_back) |back| {
        if (back.offset == 0) {
            var iter_fwd = words.iterator(string);
            while (iter_fwd.next()) |word| {
                if (word.offset <= index and index < word.offset + word.len)
                    return word;
            }
        }
    } else {
        var iter_fwd = words.iterator(string);
        while (iter_fwd.next()) |word| {
            if (word.offset <= index and index < word.offset + word.len)
                return word;
        }
    }
    _ = iter_back.prev();
    // There's sometimes flags:
    if (iter_back.flags > 0) {
        while (iter_back.flags > 0) {
            if (iter_back.prev()) |_| {
                continue;
            } else {
                break;
            }
        }
    }
    var iter_fwd = iter_back.forwardIterator();
    while (iter_fwd.next()) |word| {
        if (word.offset <= index and index < word.offset + word.len)
            return word;
    }
    unreachable;
}

/// Returns an iterator over words in `slice`.
pub fn iterator(words: *const Words, slice: []const u8) Iterator {
    return Iterator.init(words, slice);
}

/// Returns a reverse iterator over the words in `slice`.
pub fn reverseIterator(words: *const Words, slice: []const u8) ReverseIterator {
    return ReverseIterator.init(words, slice);
}

/// Returns an iterator after the `word` in `slice`.
pub fn iterateAfterWord(words: *const Words, slice: []const u8, word: Word) Iterator {
    return forwardFromIndex(words, slice, word.offset + word.len);
}

/// Returns a reverse iterator before the `word` in `slice`.
pub fn iterateBeforeWord(words: *const Words, slice: []const u8, word: Word) ReverseIterator {
    return reverseFromIndex(words, slice, word.offset);
}

/// An iterator, forward, over all words in a provided string.
pub const Iterator = struct {
    this: ?CodePoint = null,
    that: ?CodePoint = null,
    cp_iter: CodepointIterator,
    wb: *const Words,

    /// Assumes `str` is valid UTF-8.
    pub fn init(words: *const Words, str: []const u8) Iterator {
        var wb_iter: Iterator = .{ .cp_iter = .init(str), .wb = words };
        wb_iter.advance();
        return wb_iter;
    }

    /// Returns the next word segment, without advancing.
    pub fn peek(iter: *Iterator) ?Word {
        const cache = .{ iter.this, iter.that, iter.cp_iter };
        defer {
            iter.this, iter.that, iter.cp_iter = cache;
        }
        return iter.next();
    }

    /// Returns a reverse iterator from the point this iterator is paused
    /// at.  Usually, and always when using the API to create iterators,
    /// calling `prev()` will return the word just seen.
    pub fn reverseIterator(iter: *Iterator) ReverseIterator {
        var cp_it = iter.cp_iter.reverseIterator();
        if (iter.that) |_|
            _ = cp_it.prev();
        if (iter.cp_iter.peek()) |_|
            _ = cp_it.prev();
        return .{
            .wb = iter.wb,
            .before = cp_it.prev(),
            .after = iter.that,
            .cp_iter = cp_it,
        };
    }

    /// Returns the next word segment, if any.
    pub fn next(iter: *Iterator) ?Word {
        iter.advance();

        // Done?
        if (iter.this == null) return null;
        // Last?
        if (iter.that == null) return Word{ .len = iter.this.?.len, .offset = iter.this.?.offset };

        const word_start = iter.this.?.offset;
        var word_len: uoffset = 0;

        // State variables.
        var last_p: WordBreakProperty = .none;
        var last_last_p: WordBreakProperty = .none;
        var ri_count: usize = 0;

        scan: while (true) : (iter.advance()) {
            const this = iter.this.?;
            word_len += this.len;
            if (iter.that) |that| {
                const this_p = iter.wb.breakProp(this);
                const that_p = iter.wb.breakProp(that);
                if (!isIgnorable(this_p)) {
                    last_last_p = last_p;
                    last_p = this_p;
                }
                // WB3  CR × LF
                if (this_p == .CR and that_p == .LF) continue :scan;
                // WB3a  (Newline | CR | LF) ÷
                if (isNewline(this_p)) break :scan;
                // WB3b  ÷ (Newline | CR | LF)
                if (isNewline(that_p)) break :scan;
                // WB3c  ZWJ × \p{Extended_Pictographic}
                if (this_p == .ZWJ and ext_pict.isMatch(that.bytes(iter.cp_iter.bytes))) {
                    continue :scan;
                }
                // WB3d  WSegSpace × WSegSpace
                if (this_p == .WSegSpace and that_p == .WSegSpace) continue :scan;
                // WB4  X (Extend | Format | ZWJ)* → X
                if (isIgnorable(that_p)) {
                    continue :scan;
                } // Now we use last_p instead of this_p for ignorable's sake
                if (isAHLetter(last_p)) {
                    // WB5  AHLetter × AHLetter
                    if (isAHLetter(that_p)) continue :scan;
                    // WB6  AHLetter × (MidLetter | MidNumLetQ) AHLetter
                    if (isMidVal(that_p)) {
                        const next_val = iter.peekPast();
                        if (next_val) |next_cp| {
                            const next_p = iter.wb.breakProp(next_cp);
                            if (isAHLetter(next_p)) {
                                continue :scan;
                            }
                        }
                    }
                }
                // WB7 AHLetter (MidLetter | MidNumLetQ) × AHLetter
                if (isAHLetter(last_last_p) and isMidVal(last_p) and isAHLetter(that_p)) {
                    continue :scan;
                }
                if (last_p == .Hebrew_Letter) {
                    // WB7a  Hebrew_Letter × Single_Quote
                    if (that_p == .Single_Quote) continue :scan;
                    // WB7b  Hebrew_Letter × Double_Quote Hebrew_Letter
                    if (that_p == .Double_Quote) {
                        const next_val = iter.peekPast();
                        if (next_val) |next_cp| {
                            const next_p = iter.wb.breakProp(next_cp);
                            if (next_p == .Hebrew_Letter) {
                                continue :scan;
                            }
                        }
                    }
                }
                // WB7c  Hebrew_Letter Double_Quote × Hebrew_Letter
                if (last_last_p == .Hebrew_Letter and last_p == .Double_Quote and that_p == .Hebrew_Letter)
                    continue :scan;
                // WB8  Numeric × Numeric
                if (last_p == .Numeric and that_p == .Numeric) continue :scan;
                // WB9  AHLetter × Numeric
                if (isAHLetter(last_p) and that_p == .Numeric) continue :scan;
                // WB10  Numeric ×  AHLetter
                if (last_p == .Numeric and isAHLetter(that_p)) continue :scan;
                // WB11  Numeric (MidNum | MidNumLetQ) × Numeric
                if (last_last_p == .Numeric and isMidNum(last_p) and that_p == .Numeric)
                    continue :scan;
                // WB12  Numeric × (MidNum | MidNumLetQ) Numeric
                if (last_p == .Numeric and isMidNum(that_p)) {
                    const next_val = iter.peekPast();
                    if (next_val) |next_cp| {
                        const next_p = iter.wb.breakProp(next_cp);
                        if (next_p == .Numeric) {
                            continue :scan;
                        }
                    }
                }
                // WB13  Katakana × Katakana
                if (last_p == .Katakana and that_p == .Katakana) continue :scan;
                // WB13a  (AHLetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
                if (isExtensible(last_p) and that_p == .ExtendNumLet) continue :scan;
                // WB13b  ExtendNumLet × (AHLetter | Numeric | Katakana)
                if (last_p == .ExtendNumLet and isExtensible(that_p)) continue :scan;
                // WB15, WB16  ([^RI] | sot) (RI RI)* RI × RI
                const maybe_flag = that_p == .Regional_Indicator and last_p == .Regional_Indicator;
                if (maybe_flag) {
                    ri_count += 1;
                    if (ri_count % 2 == 1) continue :scan;
                }
                // WB999  Any ÷ Any
                break :scan;
            } else { // iter.that == null
                break :scan;
            }
        }

        return Word{ .len = word_len, .offset = word_start };
    }

    pub fn format(iter: Iterator, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print(
            "Iterator {{ .this = {any}, .that = {any} }}",
            .{ iter.this, iter.that },
        );
    }

    fn advance(iter: *Iterator) void {
        iter.this = iter.that;
        iter.that = iter.cp_iter.next();
    }

    fn peekPast(iter: *Iterator) ?CodePoint {
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.peek()) |peeked| {
            if (!isIgnorable(iter.wb.breakProp(peeked))) return peeked;
            _ = iter.cp_iter.next();
        }
        return null;
    }
};

/// An iterator, backward, over all words in a provided string.
pub const ReverseIterator = struct {
    after: ?CodePoint = null,
    before: ?CodePoint = null,
    cp_iter: ReverseCodepointIterator,
    wb: *const Words,
    flags: usize = 0,

    /// Assumes `str` is valid UTF-8.
    pub fn init(words: *const Words, str: []const u8) ReverseIterator {
        var wb_iter: ReverseIterator = .{ .cp_iter = .init(str), .wb = words };
        wb_iter.advance();
        return wb_iter;
    }

    /// Returns the previous word segment, if any, without advancing.
    pub fn peek(iter: *ReverseIterator) ?Word {
        const cache = .{ iter.before, iter.after, iter.cp_iter, iter.flags };
        defer {
            iter.before, iter.after, iter.cp_iter, iter.flags = cache;
        }
        return iter.prev();
    }

    /// Return a forward iterator from where this iterator paused.  Usually,
    /// and always when using the API to create iterators, calling `next()`
    /// will return the word just seen.
    pub fn forwardIterator(iter: *ReverseIterator) Iterator {
        var cp_it = iter.cp_iter.forwardIterator();
        if (iter.before) |_|
            _ = cp_it.next();
        return .{
            .wb = iter.wb,
            .this = cp_it.next(),
            .that = iter.after,
            .cp_iter = cp_it,
        };
    }

    /// Return the previous word, if any.
    pub fn prev(iter: *ReverseIterator) ?Word {
        iter.advance();

        // Done?
        if (iter.after == null) return null;
        // Last?
        if (iter.before == null) return Word{ .len = iter.after.?.len, .offset = 0 };

        const word_end = iter.after.?.offset + iter.after.?.len;
        var word_len: uoffset = 0;

        // State variables.
        var last_p: WordBreakProperty = .none;
        var last_last_p: WordBreakProperty = .none;

        scan: while (true) : (iter.advance()) {
            const after = iter.after.?;
            word_len += after.len;
            if (iter.before) |before| {
                var sneak = sneaky(iter); // 'sneaks' past ignorables
                const after_p = iter.wb.breakProp(after);
                var before_p = iter.wb.breakProp(before);
                if (!isIgnorable(after_p)) {
                    last_last_p = last_p;
                    last_p = after_p;
                }
                // WB3  CR × LF
                if (before_p == .CR and after_p == .LF) continue :scan;
                // WB3a  (Newline | CR | LF) ÷
                if (isNewline(before_p)) break :scan;
                // WB3b  ÷ (Newline | CR | LF)
                if (isNewline(after_p)) break :scan;
                // WB3c  ZWJ × \p{Extended_Pictographic}
                if (before_p == .ZWJ and ext_pict.isMatch(after.bytes(iter.cp_iter.bytes))) {
                    continue :scan;
                }
                // WB3d  WSegSpace × WSegSpace
                if (before_p == .WSegSpace and after_p == .WSegSpace) continue :scan;
                // WB4  X (Extend | Format | ZWJ)* → X
                if (isIgnorable(before_p)) {
                    const maybe_before = sneak.prev();
                    if (maybe_before) |valid_before| {
                        before_p = iter.wb.breakProp(valid_before);
                    } else if (!isIgnorable(after_p)) {
                        // We're done
                        break :scan;
                    }
                }
                if (isIgnorable(after_p)) continue :scan;
                // WB5  AHLetter × AHLetter
                if (isAHLetter(last_p) and isAHLetter(before_p)) {
                    continue :scan;
                }
                // WB6  AHLetter × (MidLetter | MidNumLetQ) AHLetter
                if (isAHLetter(before_p) and isMidVal(last_p) and isAHLetter(last_last_p)) {
                    continue :scan;
                }
                // WB7 AHLetter (MidLetter | MidNumLetQ) × AHLetter
                if (isMidVal(before_p) and isAHLetter(last_p)) {
                    const prev_val = sneak.peek();
                    if (prev_val) |prev_cp| {
                        const prev_p = iter.wb.breakProp(prev_cp);
                        if (isAHLetter(prev_p)) {
                            continue :scan;
                        }
                    }
                }
                // WB7a  Hebrew_Letter × Single_Quote
                if (before_p == .Hebrew_Letter and last_p == .Single_Quote) continue :scan;
                // WB7b  Hebrew_Letter × Double_Quote Hebrew_Letter
                if (before_p == .Hebrew_Letter and last_p == .Double_Quote and last_last_p == .Hebrew_Letter) {
                    continue :scan;
                }
                // WB7c  Hebrew_Letter Double_Quote × Hebrew_Letter
                if (before_p == .Double_Quote and last_p == .Hebrew_Letter) {
                    const prev_val = sneak.peek();
                    if (prev_val) |prev_cp| {
                        const prev_p = iter.wb.breakProp(prev_cp);
                        if (prev_p == .Hebrew_Letter) {
                            continue :scan;
                        }
                    }
                }
                // WB8  Numeric × Numeric
                if (before_p == .Numeric and last_p == .Numeric) continue :scan;
                // WB9  AHLetter × Numeric
                if (isAHLetter(before_p) and last_p == .Numeric) continue :scan;
                // WB10  Numeric ×  AHLetter
                if (before_p == .Numeric and isAHLetter(last_p)) continue :scan;
                // WB11  Numeric (MidNum | MidNumLetQ) × Numeric
                if (isMidNum(before_p) and last_p == .Numeric) {
                    const prev_val = sneak.peek();
                    if (prev_val) |prev_cp| {
                        const prev_p = iter.wb.breakProp(prev_cp);
                        if (prev_p == .Numeric) {
                            continue :scan;
                        }
                    }
                }
                // WB12  Numeric × (MidNum | MidNumLetQ) Numeric
                if (before_p == .Numeric and isMidNum(last_p) and last_last_p == .Numeric) {
                    continue :scan;
                }
                // WB13  Katakana × Katakana
                if (before_p == .Katakana and last_p == .Katakana) continue :scan;
                // WB13a  (AHLetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
                if (isExtensible(before_p) and last_p == .ExtendNumLet) continue :scan;
                // WB13b  ExtendNumLet × (AHLetter | Numeric | Katakana)
                if (before_p == .ExtendNumLet and isExtensible(last_p)) continue :scan;
                // WB15, WB16  ([^RI] | sot) (RI RI)* RI × RI
                // NOTE:
                // So here we simply have to know whether a run of flags is even or odd.
                // The whole run.  To avoid quadratic behavior (and long flag runs are
                // actually a thing in the wild), we have to count them once, store that
                // on the iterator, and decrement each time we see two, possibly breaking
                // once extra at the beginning. They break up one per flag, once we hit
                // zero, that's all the flags.  If we see another flag we do it again.
                if (before_p == .Regional_Indicator and last_p == .Regional_Indicator) {
                    defer {
                        if (iter.flags > 0) iter.flags -= 1;
                    }
                    if (iter.flags == 0) {
                        iter.flags = sneak.countFlags();
                    }
                    if (iter.flags % 2 == 0) {
                        continue :scan;
                    }
                }
                // WB999  Any ÷ Any
                break :scan;
            }
            break :scan;
        }
        return Word{ .len = word_len, .offset = word_end - word_len };
    }

    pub fn format(iter: ReverseIterator, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print(
            "ReverseIterator {{ .before = {any}, .after = {any}, .flags = {d} }}",
            .{ iter.before, iter.after, iter.flags },
        );
    }

    fn peekPast(iter: *ReverseIterator) ?CodePoint {
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.peek()) |peeked| {
            if (!isIgnorable(iter.wb.breakProp(peeked))) return peeked;
            _ = iter.cp_iter.prev();
        }
        return null;
    }

    fn advance(iter: *ReverseIterator) void {
        iter.after = iter.before;
        iter.before = iter.cp_iter.prev();
    }
};

//| Implementation Details

/// Initialize a ReverseIterator at the provided index. Used in `wordAtIndex`.
fn reverseFromIndex(words: *const Words, string: []const u8, index: usize) ReverseIterator {
    var idx: uoffset = @intCast(index);
    // Find the next lead byte:
    while (idx < string.len and 0x80 <= string[idx] and string[idx] <= 0xBf) : (idx += 1) {}
    if (idx == string.len) return words.reverseIterator(string);
    var iter: ReverseIterator = undefined;
    iter.wb = words;
    iter.flags = 0;
    // We need to populate the CodePoints, and the codepoint iterator.
    // Consider "abc| def" with the cursor as |.
    // We need `before` to be `c` and `after` to be ' ',
    // and `cp_iter.prev()` to be `b`.
    var cp_iter: ReverseCodepointIterator = .{ .bytes = string, .i = idx };
    iter.after = cp_iter.prev();
    iter.before = cp_iter.prev();
    iter.cp_iter = cp_iter;
    return iter;
}

fn forwardFromIndex(words: *const Words, string: []const u8, index: usize) Iterator {
    var idx: uoffset = @intCast(index);
    if (idx == string.len) {
        return .{
            .cp_iter = .{ .bytes = string, .i = idx },
            .this = null,
            .that = null,
            .wb = words,
        };
    }
    while (idx > 0 and 0x80 <= string[idx] and string[idx] <= 0xBf) : (idx -= 1) {}
    if (idx == 0) return words.iterator(string);
    var iter: Iterator = undefined;
    iter.wb = words;
    // We need to populate the CodePoints, and the codepoint iterator.
    // Consider "abc |def" with the cursor as |.
    // We need `this` to be ` ` and `that` to be 'd',
    // and `cp_iter.next()` to be `d`.
    idx -= 1;
    while (idx > 0 and 0x80 <= string[idx] and string[idx] <= 0xBf) : (idx -= 1) {}
    // "abc| def"
    var cp_iter: CodepointIterator = .{ .bytes = string, .i = idx };
    iter.this = cp_iter.next();
    iter.that = cp_iter.next();
    iter.cp_iter = cp_iter;
    return iter;
}

fn sneaky(iter: *const ReverseIterator) SneakIterator {
    return .{ .cp_iter = iter.cp_iter, .wb = iter.wb };
}

const SneakIterator = struct {
    cp_iter: ReverseCodepointIterator,
    wb: *const Words,

    fn peek(iter: *SneakIterator) ?CodePoint {
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.peek()) |peeked| {
            if (!isIgnorable(iter.wb.breakProp(peeked))) return peeked;
            _ = iter.cp_iter.prev();
        }
        return null;
    }

    fn countFlags(iter: *SneakIterator) usize {
        var flags: usize = 0;
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.prev()) |cp| {
            const prop = iter.wb.breakProp(cp);
            if (isIgnorable(prop)) continue;
            if (prop == .Regional_Indicator) {
                flags += 1;
            } else break;
        }
        return flags;
    }

    fn prev(iter: *SneakIterator) ?CodePoint {
        while (iter.cp_iter.prev()) |peeked| {
            if (!isIgnorable(iter.wb.breakProp(peeked))) return peeked;
        }
        return null;
    }
};

inline fn setupImpl(wb: *Words, allocator: Allocator) !void {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("wbp");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();

    const stage_1_len: u16 = try reader.readInt(u16, endian);
    wb.s1 = try allocator.alloc(u16, stage_1_len);
    errdefer allocator.free(wb.s1);
    for (0..stage_1_len) |i| wb.s1[i] = try reader.readInt(u16, endian);

    const stage_2_len: u16 = try reader.readInt(u16, endian);
    wb.s2 = try allocator.alloc(u5, stage_2_len);
    errdefer allocator.free(wb.s2);
    for (0..stage_2_len) |i| wb.s2[i] = @intCast(try reader.readInt(u8, endian));
    var count_0: usize = 0;
    for (wb.s2) |nyb| {
        if (nyb == 0) count_0 += 1;
    }
}

//| Predicates

inline fn isNewline(wbp: WordBreakProperty) bool {
    return wbp == .CR or wbp == .LF or wbp == .Newline;
}

inline fn isIgnorable(wbp: WordBreakProperty) bool {
    return switch (wbp) {
        .Format, .Extend, .ZWJ => true,
        else => false,
    };
}

inline fn isAHLetter(wbp: WordBreakProperty) bool {
    return wbp == .ALetter or wbp == .Hebrew_Letter;
}

inline fn isMidVal(wbp: WordBreakProperty) bool {
    return wbp == .MidLetter or wbp == .MidNumLet or wbp == .Single_Quote;
}

inline fn isMidNum(wbp: WordBreakProperty) bool {
    return wbp == .MidNum or wbp == .MidNumLet or wbp == .Single_Quote;
}

inline fn isExtensible(wbp: WordBreakProperty) bool {
    return switch (wbp) {
        .ALetter, .Hebrew_Letter, .Katakana, .Numeric, .ExtendNumLet => true,
        else => false,
    };
}

test "Word Break Properties" {
    const wb = try Words.init(testing.allocator);
    defer wb.deinit(testing.allocator);
    try testing.expectEqual(.CR, wb.breakProperty('\r'));
    try testing.expectEqual(.LF, wb.breakProperty('\n'));
    try testing.expectEqual(.Hebrew_Letter, wb.breakProperty('ש'));
    try testing.expectEqual(.Katakana, wb.breakProperty('\u{30ff}'));
}

test "ext_pict" {
    try testing.expect(ext_pict.isMatch("👇"));
    try testing.expect(ext_pict.isMatch("\u{2701}"));
}

test "Words" {
    const wb = try Words.init(testing.allocator);
    defer wb.deinit(testing.allocator);
    const word_str = "Metonym   Μετωνύμιο メトニム";
    var w_iter = wb.iterator(word_str);
    try testing.expectEqualStrings("Metonym", w_iter.next().?.bytes(word_str));
    // Spaces are "words" too!
    try testing.expectEqualStrings("   ", w_iter.next().?.bytes(word_str));
    const in_greek = w_iter.next().?;
    for (in_greek.offset..in_greek.offset + in_greek.len) |i| {
        const at_index = wb.wordAtIndex(word_str, i).bytes(word_str);
        try testing.expectEqualStrings("Μετωνύμιο", at_index);
    }
    _ = w_iter.next();
    try testing.expectEqualStrings("メトニム", w_iter.next().?.bytes(word_str));
}

test wordAtIndex {
    const wb = try Words.init(testing.allocator);
    defer wb.deinit(testing.allocator);
    const t_string = "first second third";
    const second = wb.wordAtIndex(t_string, 8);
    try testing.expectEqualStrings("second", second.bytes(t_string));
    const third = wb.wordAtIndex(t_string, 14);
    try testing.expectEqualStrings("third", third.bytes(t_string));
    {
        const first = wb.wordAtIndex(t_string, 3);
        try testing.expectEqualStrings("first", first.bytes(t_string));
    }
    {
        const first = wb.wordAtIndex(t_string, 0);
        try testing.expectEqualStrings("first", first.bytes(t_string));
    }
    const last = wb.wordAtIndex(t_string, 14);
    try testing.expectEqualStrings("third", last.bytes(t_string));
}

const testr = "don't a:ka fin!";

test "reversal" {
    const wb = try Words.init(testing.allocator);
    defer wb.deinit(testing.allocator);
    {
        var fwd = wb.iterator(testr);
        var this_word: ?Word = fwd.next();

        while (this_word) |this| : (this_word = fwd.next()) {
            var back = fwd.reverseIterator();
            const that_word = back.prev();
            if (that_word) |that| {
                try testing.expectEqualStrings(this.bytes(testr), that.bytes(testr));
            } else {
                try testing.expect(false);
            }
        }
    }
    {
        var back = wb.reverseIterator(testr);
        var this_word: ?Word = back.prev();

        while (this_word) |this| : (this_word = back.prev()) {
            var fwd = back.forwardIterator();
            const that_word = fwd.next();
            if (that_word) |that| {
                try testing.expectEqualStrings(this.bytes(testr), that.bytes(testr));
            } else {
                try testing.expect(false);
            }
        }
    }
}

fn testAllocations(allocator: Allocator) !void {
    const wb = try Words.init(allocator);
    wb.deinit(allocator);
}

test "allocation safety" {
    try testing.checkAllAllocationFailures(testing.allocator, testAllocations, .{});
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const uoffset = code_point.uoffset;

const code_point = @import("code_point");
const CodepointIterator = code_point.Iterator;
const ReverseCodepointIterator = code_point.ReverseIterator;
const CodePoint = code_point.CodePoint;

const ext_pict = @import("micro_runeset.zig").Extended_Pictographic;
