cutoff: u21 = undefined,
cwcf_exceptions_min: u21 = undefined,
cwcf_exceptions_max: u21 = undefined,
cwcf_exceptions: []u21 = undefined,
multiple_start: u21 = undefined,
stage1: []u8 = undefined,
stage2: []u8 = undefined,
stage3: []i24 = undefined,
normalize: Normalize,
owns_normalize: bool,

const CaseFolding = @This();

pub fn init(allocator: Allocator) Allocator.Error!CaseFolding {
    var case_fold: CaseFolding = undefined;
    try case_fold.setup(allocator);
    return case_fold;
}

pub fn initWithNormalize(allocator: Allocator, norm: Normalize) Allocator.Error!CaseFolding {
    var casefold: CaseFolding = undefined;
    try casefold.setupWithNormalize(allocator, norm);
    return casefold;
}

pub fn setup(casefold: *CaseFolding, allocator: Allocator) Allocator.Error!void {
    try casefold.setupImpl(allocator);
    // Handle normalize memory separately during setup:
    casefold.owns_normalize = false;
    errdefer casefold.deinit(allocator);
    try casefold.normalize.setup(allocator);
    casefold.owns_normalize = true;
}

pub fn setupWithNormalize(casefold: *CaseFolding, allocator: Allocator, norm: Normalize) !void {
    try casefold.setupImpl(allocator);
    casefold.normalize = norm;
    casefold.owns_normalize = false;
}

fn setupImpl(casefold: *CaseFolding, allocator: Allocator) Allocator.Error!void {
    casefold.setupImplInner(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
}

inline fn setupImplInner(casefold: *CaseFolding, allocator: Allocator) !void {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("fold");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();

    casefold.cutoff = @intCast(try reader.readInt(u24, endian));
    casefold.multiple_start = @intCast(try reader.readInt(u24, endian));

    var len = try reader.readInt(u16, endian);
    casefold.stage1 = try allocator.alloc(u8, len);
    errdefer allocator.free(casefold.stage1);
    for (0..len) |i| casefold.stage1[i] = try reader.readInt(u8, endian);

    len = try reader.readInt(u16, endian);
    casefold.stage2 = try allocator.alloc(u8, len);
    errdefer allocator.free(casefold.stage2);
    for (0..len) |i| casefold.stage2[i] = try reader.readInt(u8, endian);

    len = try reader.readInt(u16, endian);
    casefold.stage3 = try allocator.alloc(i24, len);
    errdefer allocator.free(casefold.stage3);
    for (0..len) |i| casefold.stage3[i] = try reader.readInt(i24, endian);

    casefold.cwcf_exceptions_min = @intCast(try reader.readInt(u24, endian));
    casefold.cwcf_exceptions_max = @intCast(try reader.readInt(u24, endian));
    len = try reader.readInt(u16, endian);
    casefold.cwcf_exceptions = try allocator.alloc(u21, len);
    errdefer allocator.free(casefold.cwcf_exceptions);
    for (0..len) |i| casefold.cwcf_exceptions[i] = @intCast(try reader.readInt(u24, endian));
}

pub fn deinit(fdata: *const CaseFolding, allocator: mem.Allocator) void {
    allocator.free(fdata.stage1);
    allocator.free(fdata.stage2);
    allocator.free(fdata.stage3);
    allocator.free(fdata.cwcf_exceptions);
    if (fdata.owns_normalize) fdata.normalize.deinit(allocator);
}

/// Returns the case fold for `cp`.
pub fn caseFold(fdata: *const CaseFolding, cp: u21, buf: []u21) []const u21 {
    if (cp >= fdata.cutoff) return &.{};

    const stage1_val = fdata.stage1[cp >> 8];
    if (stage1_val == 0) return &.{};

    const stage2_index = @as(usize, stage1_val) * 256 + (cp & 0xFF);
    const stage3_index = fdata.stage2[stage2_index];

    if (stage3_index & 0x80 != 0) {
        const real_index = @as(usize, fdata.multiple_start) + (stage3_index ^ 0x80) * 3;
        const mapping = mem.sliceTo(fdata.stage3[real_index..][0..3], 0);
        for (mapping, 0..) |c, i| buf[i] = @intCast(c);

        return buf[0..mapping.len];
    }

    const offset = fdata.stage3[stage3_index];
    if (offset == 0) return &.{};

    buf[0] = @intCast(@as(i32, cp) + offset);

    return buf[0..1];
}

/// Produces the case folded code points for `cps`. Caller must free returned
/// slice with `allocator`.
pub fn caseFoldAlloc(
    casefold: *const CaseFolding,
    allocator: Allocator,
    cps: []const u21,
) Allocator.Error![]const u21 {
    var cfcps = std.ArrayList(u21).init(allocator);
    defer cfcps.deinit();
    var buf: [3]u21 = undefined;

    for (cps) |cp| {
        const cf = casefold.caseFold(cp, &buf);

        if (cf.len == 0) {
            try cfcps.append(cp);
        } else {
            try cfcps.appendSlice(cf);
        }
    }

    return try cfcps.toOwnedSlice();
}

/// Returns true when caseFold(NFD(`cp`)) != NFD(`cp`).
pub fn cpChangesWhenCaseFolded(casefold: *const CaseFolding, cp: u21) bool {
    var buf: [3]u21 = undefined;
    const has_mapping = casefold.caseFold(cp, &buf).len != 0;
    return has_mapping and !casefold.isCwcfException(cp);
}

pub fn changesWhenCaseFolded(casefold: *const CaseFolding, cps: []const u21) bool {
    return for (cps) |cp| {
        if (casefold.cpChangesWhenCaseFolded(cp)) break true;
    } else false;
}

fn isCwcfException(casefold: *const CaseFolding, cp: u21) bool {
    return cp >= casefold.cwcf_exceptions_min and
        cp <= casefold.cwcf_exceptions_max and
        std.mem.indexOfScalar(u21, casefold.cwcf_exceptions, cp) != null;
}

/// Caseless compare `a` and `b` by decomposing to NFKD. This is the most
/// comprehensive comparison possible, but slower than `canonCaselessMatch`.
pub fn compatCaselessMatch(
    casefold: *const CaseFolding,
    allocator: Allocator,
    a: []const u8,
    b: []const u8,
) Allocator.Error!bool {
    if (ascii.isAsciiOnly(a) and ascii.isAsciiOnly(b)) return std.ascii.eqlIgnoreCase(a, b);

    // Process a
    const nfd_a = try casefold.normalize.nfxdCodePoints(allocator, a, .nfd);
    defer allocator.free(nfd_a);

    var need_free_cf_nfd_a = false;
    var cf_nfd_a: []const u21 = nfd_a;
    if (casefold.changesWhenCaseFolded(nfd_a)) {
        cf_nfd_a = try casefold.caseFoldAlloc(allocator, nfd_a);
        need_free_cf_nfd_a = true;
    }
    defer if (need_free_cf_nfd_a) allocator.free(cf_nfd_a);

    const nfkd_cf_nfd_a = try casefold.normalize.nfkdCodePoints(allocator, cf_nfd_a);
    defer allocator.free(nfkd_cf_nfd_a);
    const cf_nfkd_cf_nfd_a = try casefold.caseFoldAlloc(allocator, nfkd_cf_nfd_a);
    defer allocator.free(cf_nfkd_cf_nfd_a);
    const nfkd_cf_nfkd_cf_nfd_a = try casefold.normalize.nfkdCodePoints(allocator, cf_nfkd_cf_nfd_a);
    defer allocator.free(nfkd_cf_nfkd_cf_nfd_a);

    // Process b
    const nfd_b = try casefold.normalize.nfxdCodePoints(allocator, b, .nfd);
    defer allocator.free(nfd_b);

    var need_free_cf_nfd_b = false;
    var cf_nfd_b: []const u21 = nfd_b;
    if (casefold.changesWhenCaseFolded(nfd_b)) {
        cf_nfd_b = try casefold.caseFoldAlloc(allocator, nfd_b);
        need_free_cf_nfd_b = true;
    }
    defer if (need_free_cf_nfd_b) allocator.free(cf_nfd_b);

    const nfkd_cf_nfd_b = try casefold.normalize.nfkdCodePoints(allocator, cf_nfd_b);
    defer allocator.free(nfkd_cf_nfd_b);
    const cf_nfkd_cf_nfd_b = try casefold.caseFoldAlloc(allocator, nfkd_cf_nfd_b);
    defer allocator.free(cf_nfkd_cf_nfd_b);
    const nfkd_cf_nfkd_cf_nfd_b = try casefold.normalize.nfkdCodePoints(allocator, cf_nfkd_cf_nfd_b);
    defer allocator.free(nfkd_cf_nfkd_cf_nfd_b);

    return mem.eql(u21, nfkd_cf_nfkd_cf_nfd_a, nfkd_cf_nfkd_cf_nfd_b);
}

test "compatCaselessMatch" {
    const allocator = testing.allocator;

    const caser = try CaseFolding.init(allocator);
    defer caser.deinit(allocator);

    try testing.expect(try caser.compatCaselessMatch(allocator, "ascii only!", "ASCII Only!"));

    const a = "Héllo World! \u{3d3}";
    const b = "He\u{301}llo World! \u{3a5}\u{301}";
    try testing.expect(try caser.compatCaselessMatch(allocator, a, b));

    const c = "He\u{301}llo World! \u{3d2}\u{301}";
    try testing.expect(try caser.compatCaselessMatch(allocator, a, c));
}

/// Performs canonical caseless string matching by decomposing to NFD. This is
/// faster than `compatCaselessMatch`, but less comprehensive.
pub fn canonCaselessMatch(
    casefold: *const CaseFolding,
    allocator: Allocator,
    a: []const u8,
    b: []const u8,
) Allocator.Error!bool {
    if (ascii.isAsciiOnly(a) and ascii.isAsciiOnly(b)) return std.ascii.eqlIgnoreCase(a, b);

    // Process a
    const nfd_a = try casefold.normalize.nfxdCodePoints(allocator, a, .nfd);
    defer allocator.free(nfd_a);

    var need_free_cf_nfd_a = false;
    var cf_nfd_a: []const u21 = nfd_a;
    if (casefold.changesWhenCaseFolded(nfd_a)) {
        cf_nfd_a = try casefold.caseFoldAlloc(allocator, nfd_a);
        need_free_cf_nfd_a = true;
    }
    defer if (need_free_cf_nfd_a) allocator.free(cf_nfd_a);

    var need_free_nfd_cf_nfd_a = false;
    var nfd_cf_nfd_a = cf_nfd_a;
    if (!need_free_cf_nfd_a) {
        nfd_cf_nfd_a = try casefold.normalize.nfdCodePoints(allocator, cf_nfd_a);
        need_free_nfd_cf_nfd_a = true;
    }
    defer if (need_free_nfd_cf_nfd_a) allocator.free(nfd_cf_nfd_a);

    // Process b
    const nfd_b = try casefold.normalize.nfxdCodePoints(allocator, b, .nfd);
    defer allocator.free(nfd_b);

    var need_free_cf_nfd_b = false;
    var cf_nfd_b: []const u21 = nfd_b;
    if (casefold.changesWhenCaseFolded(nfd_b)) {
        cf_nfd_b = try casefold.caseFoldAlloc(allocator, nfd_b);
        need_free_cf_nfd_b = true;
    }
    defer if (need_free_cf_nfd_b) allocator.free(cf_nfd_b);

    var need_free_nfd_cf_nfd_b = false;
    var nfd_cf_nfd_b = cf_nfd_b;
    if (!need_free_cf_nfd_b) {
        nfd_cf_nfd_b = try casefold.normalize.nfdCodePoints(allocator, cf_nfd_b);
        need_free_nfd_cf_nfd_b = true;
    }
    defer if (need_free_nfd_cf_nfd_b) allocator.free(nfd_cf_nfd_b);

    return mem.eql(u21, nfd_cf_nfd_a, nfd_cf_nfd_b);
}

test "canonCaselessMatch" {
    const allocator = testing.allocator;

    const caser = try CaseFolding.init(allocator);
    defer caser.deinit(allocator);

    try testing.expect(try caser.canonCaselessMatch(allocator, "ascii only!", "ASCII Only!"));

    const a = "Héllo World! \u{3d3}";
    const b = "He\u{301}llo World! \u{3a5}\u{301}";
    try testing.expect(!try caser.canonCaselessMatch(allocator, a, b));

    const c = "He\u{301}llo World! \u{3d2}\u{301}";
    try testing.expect(try caser.canonCaselessMatch(allocator, a, c));
}

fn testAllocations(allocator: Allocator) !void {
    // With normalize provided
    {
        const normalize = try Normalize.init(allocator);
        defer normalize.deinit(allocator);
        const caser = try CaseFolding.initWithNormalize(allocator, normalize);
        defer caser.deinit(allocator);
    }
    // With normalize owned
    {
        const caser = try CaseFolding.init(allocator);
        defer caser.deinit(allocator);
    }
}

test "Allocation Failures" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testAllocations,
        .{},
    );
}

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const ascii = @import("ascii");
const Normalize = @import("Normalize");

const compress = std.compress;
