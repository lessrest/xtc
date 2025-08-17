//! Normalization Properties Data

s1: []u16 = undefined,
s2: []u4 = undefined,

const NormProps = @This();

pub fn init(allocator: mem.Allocator) !NormProps {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("normp");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();
    var norms = NormProps{};

    const stage_1_len: u16 = try reader.readInt(u16, endian);
    norms.s1 = try allocator.alloc(u16, stage_1_len);
    errdefer allocator.free(norms.s1);
    for (0..stage_1_len) |i| norms.s1[i] = try reader.readInt(u16, endian);

    const stage_2_len: u16 = try reader.readInt(u16, endian);
    norms.s2 = try allocator.alloc(u4, stage_2_len);
    errdefer allocator.free(norms.s2);
    for (0..stage_2_len) |i| norms.s2[i] = @intCast(try reader.readInt(u8, endian));

    return norms;
}

pub fn deinit(norms: *const NormProps, allocator: mem.Allocator) void {
    allocator.free(norms.s1);
    allocator.free(norms.s2);
}

/// Returns true if `cp` is already in NFD form.
pub fn isNfd(norms: *const NormProps, cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 1 == 0;
}

/// Returns true if `cp` is already in NFKD form.
pub fn isNfkd(norms: *const NormProps, cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 2 == 0;
}

/// Returns true if `cp` is not allowed in any normalized form.
pub fn isFcx(norms: *const NormProps, cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const testing = std.testing;
