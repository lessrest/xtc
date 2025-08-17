//! Compatibility Data

nfkd: [][]u21 = undefined,
cps: []u21 = undefined,

const CompatData = @This();

pub fn init(allocator: mem.Allocator) !CompatData {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("compat");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();
    var cpdata = CompatData{
        .nfkd = try allocator.alloc([]u21, 0x110000),
    };
    {
        errdefer allocator.free(cpdata.nfkd);
        cpdata.cps = try allocator.alloc(u21, magic.compat_size);
    }
    errdefer cpdata.deinit(allocator);

    @memset(cpdata.nfkd, &.{});

    var total_len: usize = 0;

    while (true) {
        const len: u8 = try reader.readInt(u8, endian);
        if (len == 0) break;
        const cp = try reader.readInt(u24, endian);
        const nk_s = cpdata.cps[total_len..][0 .. len - 1];
        for (0..len - 1) |i| {
            nk_s[i] = @intCast(try reader.readInt(u24, endian));
        }
        cpdata.nfkd[cp] = nk_s;
        total_len += len - 1;
    }

    if (comptime magic.print) std.debug.print("CompatData magic number: {d}", .{total_len});

    return cpdata;
}

pub fn deinit(cpdata: *const CompatData, allocator: mem.Allocator) void {
    allocator.free(cpdata.cps);
    allocator.free(cpdata.nfkd);
}

/// Returns compatibility decomposition for `cp`.
pub fn toNfkd(cpdata: *const CompatData, cp: u21) []u21 {
    return cpdata.nfkd[cp];
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const magic = @import("magic");
