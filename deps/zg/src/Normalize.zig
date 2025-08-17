//! Normalizer contains functions and methods that implement
//! Unicode Normalization. You can normalize strings into NFC,
//! NFKC, NFD, and NFKD normalization forms.

canon_data: CanonData = undefined,
ccc_data: CccData = undefined,
compat_data: CompatData = undefined,
hangul_data: HangulData = undefined,
normp_data: NormPropsData = undefined,

const Normalize = @This();

pub fn init(allocator: Allocator) Allocator.Error!Normalize {
    var norm: Normalize = undefined;
    try norm.setup(allocator);
    return norm;
}

pub fn setup(self: *Normalize, allocator: Allocator) Allocator.Error!void {
    self.canon_data = CanonData.init(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
    errdefer self.canon_data.deinit(allocator);
    self.ccc_data = CccData.init(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
    errdefer self.ccc_data.deinit(allocator);
    self.compat_data = CompatData.init(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
    errdefer self.compat_data.deinit(allocator);
    self.hangul_data = HangulData.init(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
    errdefer self.hangul_data.deinit(allocator);
    self.normp_data = NormPropsData.init(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
}

pub fn deinit(norm: *const Normalize, allocator: Allocator) void {
    // Reasonably safe (?)
    var mut_norm = @constCast(norm);
    mut_norm.canon_data.deinit(allocator);
    mut_norm.ccc_data.deinit(allocator);
    mut_norm.compat_data.deinit(allocator);
    mut_norm.hangul_data.deinit(allocator);
    mut_norm.normp_data.deinit(allocator);
}

const SBase: u21 = 0xAC00;
const LBase: u21 = 0x1100;
const VBase: u21 = 0x1161;
const TBase: u21 = 0x11A7;
const LCount: u21 = 19;
const VCount: u21 = 21;
const TCount: u21 = 28;
const NCount: u21 = 588; // VCount * TCount
const SCount: u21 = 11172; // LCount * NCount

fn decomposeHangul(self: Normalize, cp: u21, buf: []u21) ?Decomp {
    const kind = self.hangul_data.syllable(cp);
    if (kind != .LV and kind != .LVT) return null;

    const SIndex: u21 = cp - SBase;
    const LIndex: u21 = SIndex / NCount;
    const VIndex: u21 = (SIndex % NCount) / TCount;
    const TIndex: u21 = SIndex % TCount;
    const LPart: u21 = LBase + LIndex;
    const VPart: u21 = VBase + VIndex;

    var dc = Decomp{ .form = .nfd };
    buf[0] = LPart;
    buf[1] = VPart;

    if (TIndex == 0) {
        dc.cps = buf[0..2];
        return dc;
    }

    // TPart
    buf[2] = TBase + TIndex;
    dc.cps = buf[0..3];
    return dc;
}

fn composeHangulCanon(lv: u21, t: u21) u21 {
    assert(0x11A8 <= t and t <= 0x11C2);
    return lv + (t - TBase);
}

fn composeHangulFull(l: u21, v: u21, t: u21) u21 {
    assert(0x1100 <= l and l <= 0x1112);
    assert(0x1161 <= v and v <= 0x1175);
    const LIndex = l - LBase;
    const VIndex = v - VBase;
    const LVIndex = LIndex * NCount + VIndex * TCount;

    if (t == 0) return SBase + LVIndex;

    assert(0x11A8 <= t and t <= 0x11C2);
    const TIndex = t - TBase;

    return SBase + LVIndex + TIndex;
}

const Form = enum {
    nfc,
    nfd,
    nfkc,
    nfkd,
    same,
};

const Decomp = struct {
    form: Form = .same,
    cps: []const u21 = &.{},
};

// `mapping` retrieves the decomposition mapping for a code point as per the UCD.
fn mapping(self: Normalize, cp: u21, form: Form) Decomp {
    var dc = Decomp{};

    switch (form) {
        .nfd => {
            dc.cps = self.canon_data.toNfd(cp);
            if (dc.cps.len != 0) dc.form = .nfd;
        },

        .nfkd => {
            dc.cps = self.compat_data.toNfkd(cp);
            if (dc.cps.len != 0) {
                dc.form = .nfkd;
            } else {
                dc.cps = self.canon_data.toNfd(cp);
                if (dc.cps.len != 0) dc.form = .nfkd;
            }
        },

        else => @panic("Normalizer.mapping only accepts form .nfd or .nfkd."),
    }

    return dc;
}

// `decompose` a code point to the specified normalization form, which should be either `.nfd` or `.nfkd`.
fn decompose(
    self: Normalize,
    cp: u21,
    form: Form,
    buf: []u21,
) Decomp {
    // ASCII
    if (cp < 128) return .{};

    // NFD / NFKD quick checks.
    switch (form) {
        .nfd => if (self.normp_data.isNfd(cp)) return .{},
        .nfkd => if (self.normp_data.isNfkd(cp)) return .{},
        else => @panic("Normalizer.decompose only accepts form .nfd or .nfkd."),
    }

    // Hangul precomposed syllable full decomposition.
    if (self.decomposeHangul(cp, buf)) |dc| return dc;

    // Full decomposition.
    var dc = Decomp{ .form = form };

    var result_index: usize = 0;
    var work_index: usize = 1;

    // Start work with argument code point.
    var work = [_]u21{cp} ++ [_]u21{0} ** 17;

    while (work_index > 0) {
        // Look at previous code point in work queue.
        work_index -= 1;
        const next = work[work_index];
        const m = self.mapping(next, form);

        // No more of decompositions for this code point.
        if (m.form == .same) {
            buf[result_index] = next;
            result_index += 1;
            continue;
        }

        // Work backwards through decomposition.
        // `i` starts at 1 because m_last is 1 past the last code point.
        var i: usize = 1;
        while (i <= m.cps.len) : ({
            i += 1;
            work_index += 1;
        }) {
            work[work_index] = m.cps[m.cps.len - i];
        }
    }

    dc.cps = buf[0..result_index];

    return dc;
}

test "decompose" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    var buf: [18]u21 = undefined;

    var dc = n.decompose('é', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ 'e', '\u{301}' }, dc.cps[0..2]);

    dc = n.decompose('\u{1e0a}', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ 'D', '\u{307}' }, dc.cps[0..2]);

    dc = n.decompose('\u{1e0a}', .nfkd, &buf);
    try testing.expect(dc.form == .nfkd);
    try testing.expectEqualSlices(u21, &[_]u21{ 'D', '\u{307}' }, dc.cps[0..2]);

    dc = n.decompose('\u{3189}', .nfd, &buf);
    try testing.expect(dc.form == .same);
    try testing.expect(dc.cps.len == 0);

    dc = n.decompose('\u{3189}', .nfkd, &buf);
    try testing.expect(dc.form == .nfkd);
    try testing.expectEqualSlices(u21, &[_]u21{'\u{1188}'}, dc.cps[0..1]);

    dc = n.decompose('\u{ace1}', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{1100}', '\u{1169}', '\u{11a8}' }, dc.cps[0..3]);

    dc = n.decompose('\u{ace1}', .nfkd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{1100}', '\u{1169}', '\u{11a8}' }, dc.cps[0..3]);

    dc = n.decompose('\u{3d3}', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{3d2}', '\u{301}' }, dc.cps[0..2]);

    dc = n.decompose('\u{3d3}', .nfkd, &buf);
    try testing.expect(dc.form == .nfkd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{3a5}', '\u{301}' }, dc.cps[0..2]);
}

/// Returned from various functions in this namespace. Remember to call `deinit` to free any allocated memory.
/// Note that normalization functions will not copy what they're given if no normalization is needed, if you
/// need to ensure that this Result outlasts the given string, call `try result.toOwned(allocator)`.  This
/// will not make a third copy if the Result is already copied from the input.
pub const Result = struct {
    allocated: bool = false,
    slice: []const u8,

    /// Ensures that the slice result is a copy of the input, by making a copy if it was not.
    pub fn toOwned(result: Result, allocator: Allocator) error{OutOfMemory}!Result {
        if (result.allocated) return result;
        return .{ .allocated = true, .slice = try allocator.dupe(u8, result.slice) };
    }

    pub fn deinit(self: *const Result, allocator: Allocator) void {
        if (self.allocated) allocator.free(self.slice);
    }
};

// Compares code points by Canonical Combining Class order.
fn cccLess(self: Normalize, lhs: u21, rhs: u21) bool {
    return self.ccc_data.ccc(lhs) < self.ccc_data.ccc(rhs);
}

// Applies the Canonical Sorting Algorithm.
fn canonicalSort(self: Normalize, cps: []u21) void {
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        const start: usize = i;
        while (i < cps.len and self.ccc_data.ccc(cps[i]) != 0) : (i += 1) {}
        mem.sort(u21, cps[start..i], self, cccLess);
    }
}

/// Normalize `str` to NFD.
pub fn nfd(self: Normalize, allocator: Allocator, str: []const u8) Allocator.Error!Result {
    return self.nfxd(allocator, str, .nfd);
}

/// Normalize `str` to NFKD.
pub fn nfkd(self: Normalize, allocator: Allocator, str: []const u8) Allocator.Error!Result {
    return self.nfxd(allocator, str, .nfkd);
}

pub fn nfxdCodePoints(self: Normalize, allocator: Allocator, str: []const u8, form: Form) Allocator.Error![]u21 {
    var dcp_list = std.ArrayList(u21).init(allocator);
    defer dcp_list.deinit();

    var cp_iter = CodePointIterator{ .bytes = str };
    var dc_buf: [18]u21 = undefined;

    while (cp_iter.next()) |cp| {
        const dc = self.decompose(cp.code, form, &dc_buf);
        if (dc.form == .same) {
            try dcp_list.append(cp.code);
        } else {
            try dcp_list.appendSlice(dc.cps);
        }
    }

    self.canonicalSort(dcp_list.items);

    return try dcp_list.toOwnedSlice();
}

fn nfxd(self: Normalize, allocator: Allocator, str: []const u8, form: Form) Allocator.Error!Result {
    // Quick checks.
    if (ascii.isAsciiOnly(str)) return Result{ .slice = str };

    const dcps = try self.nfxdCodePoints(allocator, str, form);
    defer allocator.free(dcps);

    var dstr_list = std.ArrayList(u8).init(allocator);
    defer dstr_list.deinit();
    var buf: [4]u8 = undefined;

    for (dcps) |dcp| {
        const len = unicode.utf8Encode(dcp, &buf) catch unreachable;
        try dstr_list.appendSlice(buf[0..len]);
    }

    return Result{ .allocated = true, .slice = try dstr_list.toOwnedSlice() };
}

test "nfd ASCII / no-alloc" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    const result = try n.nfd(allocator, "Hello World!");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Hello World!", result.slice);
}

test "nfd !ASCII / alloc" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    const result = try n.nfd(allocator, "Héllo World! \u{3d3}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("He\u{301}llo World! \u{3d2}\u{301}", result.slice);
}

test "nfkd ASCII / no-alloc" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    const result = try n.nfkd(allocator, "Hello World!");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Hello World!", result.slice);
}

test "nfkd !ASCII / alloc" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    const result = try n.nfkd(allocator, "Héllo World! \u{3d3}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("He\u{301}llo World! \u{3a5}\u{301}", result.slice);
}

pub fn nfdCodePoints(
    self: Normalize,
    allocator: Allocator,
    cps: []const u21,
) Allocator.Error![]u21 {
    var dcp_list = std.ArrayList(u21).init(allocator);
    defer dcp_list.deinit();

    var dc_buf: [18]u21 = undefined;

    for (cps) |cp| {
        const dc = self.decompose(cp, .nfd, &dc_buf);

        if (dc.form == .same) {
            try dcp_list.append(cp);
        } else {
            try dcp_list.appendSlice(dc.cps);
        }
    }

    self.canonicalSort(dcp_list.items);

    return try dcp_list.toOwnedSlice();
}

pub fn nfkdCodePoints(
    self: Normalize,
    allocator: Allocator,
    cps: []const u21,
) Allocator.Error![]u21 {
    var dcp_list = std.ArrayList(u21).init(allocator);
    defer dcp_list.deinit();

    var dc_buf: [18]u21 = undefined;

    for (cps) |cp| {
        const dc = self.decompose(cp, .nfkd, &dc_buf);

        if (dc.form == .same) {
            try dcp_list.append(cp);
        } else {
            try dcp_list.appendSlice(dc.cps);
        }
    }

    self.canonicalSort(dcp_list.items);

    return try dcp_list.toOwnedSlice();
}

// Composition (NFC, NFKC)

fn isHangul(self: Normalize, cp: u21) bool {
    return cp >= 0x1100 and self.hangul_data.syllable(cp) != .none;
}

/// Normalizes `str` to NFC.
pub fn nfc(self: Normalize, allocator: Allocator, str: []const u8) Allocator.Error!Result {
    return self.nfxc(allocator, str, .nfc);
}

/// Normalizes `str` to NFKC.
pub fn nfkc(self: Normalize, allocator: Allocator, str: []const u8) Allocator.Error!Result {
    return self.nfxc(allocator, str, .nfkc);
}

fn nfxc(self: Normalize, allocator: Allocator, str: []const u8, form: Form) Allocator.Error!Result {
    // Quick checks.
    if (ascii.isAsciiOnly(str)) return Result{ .slice = str };
    if (form == .nfc and isLatin1Only(str)) return Result{ .slice = str };

    // Decompose first.
    var dcps = if (form == .nfc)
        try self.nfxdCodePoints(allocator, str, .nfd)
    else
        try self.nfxdCodePoints(allocator, str, .nfkd);
    defer allocator.free(dcps);

    // Compose
    const tombstone = 0xe000; // Start of BMP Private Use Area

    // Loop over all decomposed code points.
    while (true) {
        var i: usize = 1; // start at second code point.
        var deleted: usize = 0;

        // For each code point, C, find the preceding
        // starter code point L, if any.
        block_check: while (i < dcps.len) : (i += 1) {
            const C = dcps[i];
            if (C == tombstone) continue :block_check;
            const cc_C = self.ccc_data.ccc(C);
            var starter_index: ?usize = null;
            var j: usize = i;

            // Seek back to find starter L, if any.
            while (true) {
                j -= 1;
                if (dcps[j] == tombstone) continue;

                // Check for starter.
                if (self.ccc_data.isStarter(dcps[j])) {
                    // Check for blocking conditions.
                    for (dcps[(j + 1)..i]) |B| {
                        if (B == tombstone) continue;
                        const cc_B = self.ccc_data.ccc(B);
                        if (cc_B != 0 and self.isHangul(C)) continue :block_check;
                        if (cc_B >= cc_C) continue :block_check;
                    }

                    // Found starter at j.
                    starter_index = j;
                    break;
                }

                if (j == 0) break;
            }

            // If we have a starter L, see if there's a primary
            // composite, P, for the sequence L, C. If so, we must
            // repace L with P and delete C.
            if (starter_index) |sidx| {
                const L = dcps[sidx];
                var processed_hangul = false;

                // If L and C are Hangul syllables, we can compose
                // them algorithmically if possible.
                if (self.isHangul(L) and self.isHangul(C)) {
                    // Get Hangul syllable types.
                    const l_stype = self.hangul_data.syllable(L);
                    const c_stype = self.hangul_data.syllable(C);

                    if (l_stype == .LV and c_stype == .T) {
                        // LV, T canonical composition.
                        dcps[sidx] = composeHangulCanon(L, C);
                        dcps[i] = tombstone; // Mark for deletion.
                        processed_hangul = true;
                    }

                    if (l_stype == .L and c_stype == .V) {
                        // L, V full composition. L, V, T is handled via main loop.
                        dcps[sidx] = composeHangulFull(L, C, 0);
                        dcps[i] = tombstone; // Mark for deletion.
                        processed_hangul = true;
                    }

                    if (processed_hangul) deleted += 1;
                }

                // If no composition has occurred yet.
                if (!processed_hangul) {
                    // L, C are not Hangul, so check for primary composite
                    // in the Unicode Character Database.
                    if (self.canon_data.toNfc(.{ L, C })) |P| {
                        // We have a primary composite P for L, C.
                        // We must check if P is not in the Full
                        // Composition Exclusions  (FCX) list,
                        // preventing it from appearing in any
                        // composed form (NFC, NFKC).
                        if (!self.normp_data.isFcx(P)) {
                            dcps[sidx] = P;
                            dcps[i] = tombstone; // Mark for deletion.
                            deleted += 1;
                        }
                    }
                }
            }
        }

        // If we have no deletions. the code point sequence
        // has been fully composed.
        if (deleted == 0) {
            var cstr_list = std.ArrayList(u8).init(allocator);
            defer cstr_list.deinit();
            var buf: [4]u8 = undefined;

            for (dcps) |cp| {
                if (cp == tombstone) continue; // "Delete"
                const len = unicode.utf8Encode(cp, &buf) catch unreachable;
                try cstr_list.appendSlice(buf[0..len]);
            }

            return Result{ .allocated = true, .slice = try cstr_list.toOwnedSlice() };
        }
    }
}

test "nfc" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    const result = try n.nfc(allocator, "Complex char: \u{3D2}\u{301}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Complex char: \u{3D3}", result.slice);
}

test "nfkc" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    const result = try n.nfkc(allocator, "Complex char: \u{03A5}\u{0301}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Complex char: \u{038E}", result.slice);
}

/// Tests for equality of `a` and `b` after normalizing to NFC.
pub fn eql(self: Normalize, allocator: Allocator, a: []const u8, b: []const u8) !bool {
    const norm_result_a = try self.nfc(allocator, a);
    defer norm_result_a.deinit(allocator);
    const norm_result_b = try self.nfc(allocator, b);
    defer norm_result_b.deinit(allocator);

    return mem.eql(u8, norm_result_a.slice, norm_result_b.slice);
}

test "eql" {
    const allocator = testing.allocator;
    const n = try Normalize.init(allocator);
    defer n.deinit(allocator);

    try testing.expect(try n.eql(allocator, "foé", "foe\u{0301}"));
    try testing.expect(try n.eql(allocator, "foϓ", "fo\u{03D2}\u{0301}"));
}

/// Returns true if `str` only contains Latin-1 Supplement
/// code points. Uses SIMD if possible.
pub fn isLatin1Only(str: []const u8) bool {
    var cp_iter = CodePointIterator{ .bytes = str };

    const vec_len = simd.suggestVectorLength(u21) orelse return blk: {
        break :blk while (cp_iter.next()) |cp| {
            if (cp.code > 256) break false;
        } else true;
    };

    const Vec = @Vector(vec_len, u21);

    outer: while (true) {
        var v1: Vec = undefined;
        const saved_cp_i = cp_iter.i;

        for (0..vec_len) |i| {
            if (cp_iter.next()) |cp| {
                v1[i] = cp.code;
            } else {
                cp_iter.i = saved_cp_i;
                break :outer;
            }
        }
        const v2: Vec = @splat(256);
        if (@reduce(.Or, v1 > v2)) return false;
    }

    return while (cp_iter.next()) |cp| {
        if (cp.code > 256) break false;
    } else true;
}

test "isLatin1Only" {
    const latin1_only = "Hello, World! \u{fe} \u{ff}";
    try testing.expect(isLatin1Only(latin1_only));
    const not_latin1_only = "Héllo, World! \u{3d3}";
    try testing.expect(!isLatin1Only(not_latin1_only));
}

const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const simd = std.simd;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = std.mem.Allocator;

const ascii = @import("ascii");
const CodePointIterator = @import("code_point").Iterator;

const CanonData = @import("CanonData");
const CccData = @import("CombiningData");
const CompatData = @import("CompatData");
const HangulData = @import("HangulData");
const NormPropsData = @import("NormPropsData");
