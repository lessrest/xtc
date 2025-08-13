//! Hangul Data

pub const Syllable = enum {
    none,
    L,
    LV,
    LVT,
    V,
    T,
};

s1: []u16 = undefined,
s2: []u3 = undefined,

const Hangul = @This();

pub fn init(allocator: mem.Allocator) !Hangul {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("hangul");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();
    var hangul = Hangul{};

    const stage_1_len: u16 = try reader.readInt(u16, endian);
    hangul.s1 = try allocator.alloc(u16, stage_1_len);
    errdefer allocator.free(hangul.s1);
    for (0..stage_1_len) |i| hangul.s1[i] = try reader.readInt(u16, endian);

    const stage_2_len: u16 = try reader.readInt(u16, endian);
    hangul.s2 = try allocator.alloc(u3, stage_2_len);
    errdefer allocator.free(hangul.s2);
    for (0..stage_2_len) |i| hangul.s2[i] = @intCast(try reader.readInt(u8, endian));

    return hangul;
}

pub fn deinit(hangul: *const Hangul, allocator: mem.Allocator) void {
    allocator.free(hangul.s1);
    allocator.free(hangul.s2);
}

/// Returns the Hangul syllable type for `cp`.
pub fn syllable(hangul: *const Hangul, cp: u21) Syllable {
    return @enumFromInt(hangul.s2[hangul.s1[cp >> 8] + (cp & 0xff)]);
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const testing = std.testing;
