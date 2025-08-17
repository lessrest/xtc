//! Canonicalization Data

nfc: std.AutoHashMapUnmanaged([2]u21, u21),
nfd: [][]u21 = undefined,
cps: []u21 = undefined,

const CanonData = @This();

pub fn init(allocator: mem.Allocator) !CanonData {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("canon");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();
    var cdata = CanonData{
        .nfc = .empty,
        .nfd = try allocator.alloc([]u21, 0x110000),
    };
    {
        errdefer allocator.free(cdata.nfd);
        cdata.cps = try allocator.alloc(u21, magic.canon_size);
    }

    var total_cp: u24 = undefined;

    errdefer {
        cdata.nfc.deinit(allocator);
        allocator.free(cdata.cps);
        allocator.free(cdata.nfd);
    }

    @memset(cdata.nfd, &.{});

    var total_len: usize = 0;

    while (true) {
        const len: u8 = try reader.readInt(u8, endian);
        if (len == 0) break;
        const cp = try reader.readInt(u24, endian);
        total_cp = cp;
        const nfd_cp = cdata.cps[total_len..][0 .. len - 1];
        for (0..len - 1) |i| {
            nfd_cp[i] = @intCast(try reader.readInt(u24, endian));
        }
        if (len == 3) {
            try cdata.nfc.put(allocator, nfd_cp[0..2].*, @intCast(cp));
        }
        cdata.nfd[cp] = nfd_cp;
        total_len += len - 1;
    }

    if (comptime magic.print) std.debug.print("CanonData magic number: {d}\n", .{total_len});

    return cdata;
}

pub fn deinit(cdata: *CanonData, allocator: mem.Allocator) void {
    cdata.nfc.deinit(allocator);
    allocator.free(cdata.cps);
    allocator.free(cdata.nfd);
}

/// Returns canonical decomposition for `cp`.
pub fn toNfd(cdata: *const CanonData, cp: u21) []const u21 {
    return cdata.nfd[cp];
}

// Returns the primary composite for the codepoints in `cp`.
pub fn toNfc(cdata: *const CanonData, cps: [2]u21) ?u21 {
    return cdata.nfc.get(cps);
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const magic = @import("magic");
const options = @import("options");
