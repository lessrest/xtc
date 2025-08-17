//! General Categories

s1: []u16 = undefined,
s2: []u5 = undefined,
s3: []u5 = undefined,

/// General Category
pub const Gc = enum {
    Cc, // Other, Control
    Cf, // Other, Format
    Cn, // Other, Unassigned
    Co, // Other, Private Use
    Cs, // Other, Surrogate
    Ll, // Letter, Lowercase
    Lm, // Letter, Modifier
    Lo, // Letter, Other
    Lu, // Letter, Uppercase
    Lt, // Letter, Titlecase
    Mc, // Mark, Spacing Combining
    Me, // Mark, Enclosing
    Mn, // Mark, Non-Spacing
    Nd, // Number, Decimal Digit
    Nl, // Number, Letter
    No, // Number, Other
    Pc, // Punctuation, Connector
    Pd, // Punctuation, Dash
    Pe, // Punctuation, Close
    Pf, // Punctuation, Final quote (may behave like Ps or Pe depending on usage)
    Pi, // Punctuation, Initial quote (may behave like Ps or Pe depending on usage)
    Po, // Punctuation, Other
    Ps, // Punctuation, Open
    Sc, // Symbol, Currency
    Sk, // Symbol, Modifier
    Sm, // Symbol, Math
    So, // Symbol, Other
    Zl, // Separator, Line
    Zp, // Separator, Paragraph
    Zs, // Separator, Space
};

const GeneralCategories = @This();

pub fn init(allocator: Allocator) Allocator.Error!GeneralCategories {
    var gencat = GeneralCategories{};
    try gencat.setup(allocator);
    return gencat;
}

pub fn setup(gencat: *GeneralCategories, allocator: Allocator) Allocator.Error!void {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("gencat");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();

    const s1_len: u16 = reader.readInt(u16, endian) catch unreachable;
    gencat.s1 = try allocator.alloc(u16, s1_len);
    errdefer allocator.free(gencat.s1);
    for (0..s1_len) |i| gencat.s1[i] = reader.readInt(u16, endian) catch unreachable;

    const s2_len: u16 = reader.readInt(u16, endian) catch unreachable;
    gencat.s2 = try allocator.alloc(u5, s2_len);
    errdefer allocator.free(gencat.s2);
    for (0..s2_len) |i| gencat.s2[i] = @intCast(reader.readInt(u8, endian) catch unreachable);

    const s3_len: u16 = reader.readInt(u8, endian) catch unreachable;
    gencat.s3 = try allocator.alloc(u5, s3_len);
    errdefer allocator.free(gencat.s3);
    for (0..s3_len) |i| gencat.s3[i] = @intCast(reader.readInt(u8, endian) catch unreachable);
}

pub fn deinit(gencat: *const GeneralCategories, allocator: mem.Allocator) void {
    allocator.free(gencat.s1);
    allocator.free(gencat.s2);
    allocator.free(gencat.s3);
}

/// Lookup the General Category for `cp`.
pub fn gc(gencat: GeneralCategories, cp: u21) Gc {
    return @enumFromInt(gencat.s3[gencat.s2[gencat.s1[cp >> 8] + (cp & 0xff)]]);
}

/// True if `cp` has an C general category.
pub fn isControl(gencat: GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Cc,
        .Cf,
        .Cn,
        .Co,
        .Cs,
        => true,
        else => false,
    };
}

/// True if `cp` has an L general category.
pub fn isLetter(gencat: GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Ll,
        .Lm,
        .Lo,
        .Lu,
        .Lt,
        => true,
        else => false,
    };
}

/// True if `cp` has an M general category.
pub fn isMark(gencat: GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Mc,
        .Me,
        .Mn,
        => true,
        else => false,
    };
}

/// True if `cp` has an N general category.
pub fn isNumber(gencat: GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Nd,
        .Nl,
        .No,
        => true,
        else => false,
    };
}

/// True if `cp` has an P general category.
pub fn isPunctuation(gencat: GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Pc,
        .Pd,
        .Pe,
        .Pf,
        .Pi,
        .Po,
        .Ps,
        => true,
        else => false,
    };
}

/// True if `cp` has an S general category.
pub fn isSymbol(gencat: GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Sc,
        .Sk,
        .Sm,
        .So,
        => true,
        else => false,
    };
}

/// True if `cp` has an Z general category.
pub fn isSeparator(gencat: GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Zl,
        .Zp,
        .Zs,
        => true,
        else => false,
    };
}

fn testAllocator(allocator: Allocator) !void {
    var gen_cat = try GeneralCategories.init(allocator);
    gen_cat.deinit(allocator);
}

test "Allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testAllocator, .{});
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
