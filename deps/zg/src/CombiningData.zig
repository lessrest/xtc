//! Combining Class Data

s1: []u16 = undefined,
s2: []u8 = undefined,

const CombiningData = @This();

pub fn init(allocator: mem.Allocator) !CombiningData {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("ccc");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();

    var cbdata = CombiningData{};

    const stage_1_len: u16 = try reader.readInt(u16, endian);
    cbdata.s1 = try allocator.alloc(u16, stage_1_len);
    errdefer allocator.free(cbdata.s1);
    for (0..stage_1_len) |i| cbdata.s1[i] = try reader.readInt(u16, endian);

    const stage_2_len: u16 = try reader.readInt(u16, endian);
    cbdata.s2 = try allocator.alloc(u8, stage_2_len);
    errdefer allocator.free(cbdata.s2);
    _ = try reader.readAll(cbdata.s2);

    return cbdata;
}

pub fn deinit(cbdata: *const CombiningData, allocator: mem.Allocator) void {
    allocator.free(cbdata.s1);
    allocator.free(cbdata.s2);
}

/// Returns the canonical combining class for a code point.
pub fn ccc(cbdata: CombiningData, cp: u21) u8 {
    return cbdata.s2[cbdata.s1[cp >> 8] + (cp & 0xff)];
}

/// True if `cp` is a starter code point, not a combining character.
pub fn isStarter(cbdata: CombiningData, cp: u21) bool {
    return cbdata.s2[cbdata.s1[cp >> 8] + (cp & 0xff)] == 0;
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
