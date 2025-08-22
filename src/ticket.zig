//! Ticket-style human-friendly ID encoder.
//!
//! This module encodes fixed-size binary data (e.g. hash digests) into
//! short, readable, **all-caps** “robot ticket” strings with a pleasant
//! consonant–vowel–digit rhythm.  IDs are constant-length, free of case
//! mixing, and avoid ambiguous glyphs (`0/O`, `1/I/L`).
//!
//! ## Encoding scheme
//! - The alphabet is split into:
//!   - 20 consonants: `BCDFGHJKMNPQRSTVWXYZ`
//!   - 5 vowels:      `AEIOU`
//!   - 8 digits:      `23456789`
//! - Two cell types are used:
//!   - `.CVN` (3 chars): consonant + vowel + digit → base-800
//!   - `.CV`  (2 chars): consonant + vowel         → base-100
//! - A *pattern* is a compile-time array of `Cell` values specifying the
//!   sequence of cells for an ID (e.g. `{ .CVN, .CV, .CVN, .CV }`).
//! - The input byte array is treated as a big-endian integer and repeatedly
//!   divided by each cell’s base (mixed-radix conversion). The remainders
//!   become the output characters.
//! - Because the pattern is known at compile time, both input length and
//!   output length are constant and checked by the compiler.
//!
//! ## Features
//! - **Comptime sizes**: no allocations, no dynamic buffers; output length is
//!   available as `MyEncoder.out_len`.
//! - **Deterministic**: given the same input and pattern, output is stable.
//! - **Collision behaviour**: full input space is represented exactly in the
//!   mixed-radix space of the chosen pattern. Change pattern → change ID.
//! - **Readable rhythm**: consonant–vowel alternation and occasional digits
//!   make scanning and verbal communication easy.
//!
//! ## Usage
//! Define an encoder type with `encodeFixed(InLen, &pattern)`:
//!
//! ```zig
//! pub const Wy64Ticket12 = encodeFixed(8, &PATTERN_12);
//! pub const Sha256Ticket16 = encodeFixed(32, &PATTERN_16);
//!
//! const id = Wy64Ticket12.encode(&[8]u8{ 0xde,0xad,0xbe,0xef,0x12,0x34,0x56,0x78 });
//! // id is [Wy64Ticket12.out_len]u8, e.g. "KOV5MEB4TUA…"
//! ```
//!
//! See the preset `PATTERN_*` constants for ready-made rhythms.

const std = @import("std");

pub const Cell = enum { CVN, CV }; // CVN=3 chars (base 800), CV=2 chars (base 100)

const CONS = "BCDFGHJKMNPQRSTVWXYZ"; // 20 distinct uppercase consonants
const VOWS = "AEIOU"; // 5 vowels
const DIGS = "23456789"; // 8 digits (no 0/1)

fn cellBase(c: Cell) u16 {
    return switch (c) {
        .CVN => 800, // 20 * 5 * 8
        .CV => 100, // 20 * 5
    };
}

fn outChars(c: Cell) comptime_int {
    return switch (c) {
        .CVN => 3,
        .CV => 2,
    };
}

pub fn encodedLen(comptime pattern: []const Cell) comptime_int {
    var n: usize = 0;
    inline for (pattern) |cell| n += outChars(cell);
    return n;
}

/// Divide a big-endian magnitude `num` by `base` in place.
/// Writes the big-endian quotient back into `num`, returns the remainder.
/// Requires 2 <= base <= 65535.
fn beDivMod(num: []u8, base: u16) u16 {
    std.debug.assert(base >= 2);
    var rem: u32 = 0; // wide enough to hold (base-1)*256 + 255
    for (num) |*b| {
        const cur: u32 = (rem << 8) | @as(u32, b.*);
        const q: u32 = cur / base; // 0..255 (see proof below)
        const r: u32 = cur - q * base; // faster than cur % base on some CPUs
        b.* = @intCast(q);
        rem = r;
    }
    return @intCast(rem);
}

// Map digits to glyphs (no allocations)
fn putCVN(out: []u8, idx: usize, d: u16) void {
    // d in 0..799 → c = d/40 (0..19), v = (d/8)%5 (0..4), n = d%8 (0..7)
    const c: usize = d / 40;
    const v: usize = (d / 8) % 5;
    const n: usize = d % 8;
    out[idx + 0] = CONS[c];
    out[idx + 1] = VOWS[v];
    out[idx + 2] = DIGS[n];
}
fn putCV(out: []u8, idx: usize, d: u16) void {
    // d in 0..99 → c = d/5 (0..19), v = d%5 (0..4)
    const c: usize = d / 5;
    const v: usize = d % 5;
    out[idx + 0] = CONS[c];
    out[idx + 1] = VOWS[v];
}

/// Core, fully comptime-sized encoder.
/// - `InLen` is the number of input bytes (known at comptime).
/// - `pattern` is a comptime sequence of cells (CVN/CV), deciding output length.
/// - Returns a fixed-size all-caps, no-separator ticket.
pub fn encodeFixed(comptime InLen: usize, comptime pattern: []const Cell) type {
    const OutLen = encodedLen(pattern);
    return struct {
        pub const out_len = OutLen;

        pub fn encode(input_be: *const [InLen]u8) [OutLen]u8 {
            // Work copy for in-place big-int division (no heap)
            var work: [InLen]u8 = input_be.*;
            // We’ll extract remainders for each cell from the END to the START,
            // so the human-readable order is preserved.
            const Cells = pattern.len;
            var digits: [Cells]u16 = undefined;

            // Walk cells from last to first, divmod by that cell’s base.
            var i: usize = Cells;
            while (i > 0) {
                i -= 1;
                const base = cellBase(pattern[i]);
                digits[i] = beDivMod(&work, base);
            }

            // Map digits to glyphs
            var out: [OutLen]u8 = undefined;
            var pos: usize = 0;
            inline for (pattern, 0..) |cell, k| {
                switch (cell) {
                    .CVN => {
                        putCVN(&out, pos, digits[k]);
                        pos += 3;
                    },
                    .CV => {
                        putCV(&out, pos, digits[k]);
                        pos += 2;
                    },
                }
            }
            return out;
        }
    };
}

// -------------------- Presets --------------------

// Patterns tuned for a nice “ticket” rhythm (no separators).
pub const PATTERN_12 = [_]Cell{ .CVN, .CV, .CVN, .CV }; // 3+2+3+2 = 10 chars (short)
pub const PATTERN_16 = [_]Cell{ .CVN, .CVN, .CV, .CVN, .CV }; // 3+3+2+3+2 = 13 chars
pub const PATTERN_20 = [_]Cell{ .CVN, .CV, .CV, .CVN, .CVN, .CV }; // 3+2+2+3+3+2 = 15 chars
pub const PATTERN_24 = [_]Cell{ .CVN, .CVN, .CV, .CVN, .CV, .CVN, .CV }; // 18 chars

// You can define as many patterns as you like; pick by “aesthetic length”.

// --- Hash-oriented wrappers (inputs are fixed-size at comptime) ---

// For SHA-256 digests (32 bytes). You likely don't want all 256 bits;
// pick a visual length and pattern. These consume the *entire* digest
// via mixed-radix conversion, but the length is determined solely by `pattern`.
pub const Sha256Ticket16 = encodeFixed(32, &PATTERN_16);
pub const Sha256Ticket20 = encodeFixed(32, &PATTERN_20);
pub const Sha256Ticket24 = encodeFixed(32, &PATTERN_24);

// For 64-bit Wyhash output:
pub const Wy64Ticket12 = encodeFixed(8, &PATTERN_12);
pub const Wy64Ticket16 = encodeFixed(8, &PATTERN_16);

// For 128-bit hashes (e.g., XXH3 128):
pub const H128Ticket20 = encodeFixed(16, &PATTERN_20);

// -------------------- Demo --------------------
pub fn main() !void {
    // Pretend we have a SHA-256 digest:
    const sha: [32]u8 = [_]u8{
        0x60, 0x4b, 0x0b, 0x0f, 0x83, 0x24, 0xa4, 0x2c,
        0x99, 0x2a, 0x8c, 0x91, 0x5d, 0x1b, 0x4a, 0x1e,
        0x97, 0x31, 0x0b, 0x7f, 0x2b, 0xf2, 0x84, 0x57,
        0x9c, 0x2a, 0x5c, 0x98, 0x73, 0x66, 0x11, 0x42,
    };

    const t16 = Sha256Ticket16.encode(&sha);
    const t20 = Sha256Ticket20.encode(&sha);

    // Wyhash-64 example:
    const wy: [8]u8 = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x12, 0x34, 0x56, 0x78 };
    const w12 = Wy64Ticket12.encode(&wy);

    var buf: [512]u8 = undefined;
    var state = std.fs.File.stdout().writer(&buf);
    const out: *std.Io.Writer = &state.interface;
    try out.print("SHA256/13ch : {s}\n", .{t16});
    try out.print("SHA256/15ch : {s}\n", .{t20});
    try out.print("WY64 /10ch : {s}\n", .{w12});
}

// 1) Fixed-size/length sanity
test "encodedLen sums cell widths" {
    try std.testing.expectEqual(@as(usize, 10), encodedLen(&[_]Cell{ .CVN, .CV, .CVN, .CV })); // 3+2+3+2
    try std.testing.expectEqual(@as(usize, 13), encodedLen(&[_]Cell{ .CVN, .CVN, .CV, .CVN, .CV })); // 3+3+2+3+2
}

// 2) Wy64Ticket12 known-good vectors (all zeros / one)
// Pattern is CVN (3) + CV (2) + CVN (3) + CV (2) = 10 chars.
// Mapping for digit 0: CVN => C0/V0/N0 => B A 2  => "BA2"
//                      CV  => C0/V0     => B A    => "BA"
test "Wy64Ticket12 zero vector" {
    const zero: [8]u8 = [_]u8{0} ** 8;
    const got = Wy64Ticket12.encode(&zero);
    try std.testing.expectEqual(@as(usize, Wy64Ticket12.out_len), got.len);
    // Digits will all be 0 => "BA2" "BA" "BA2" "BA"
    try std.testing.expectEqualStrings("BA2BABA2BA", &got);
}

// For input = 1 (big-endian), only the *last* digit is 1; others are 0.
// CVN(0) = "BA2", CV(0) = "BA", CVN(0) = "BA2", last CV(1) => c=1/5=0 -> 'B', v=1%5=1 -> 'E' => "BE"
test "Wy64Ticket12 one vector" {
    const one: [8]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
    const got = Wy64Ticket12.encode(&one);
    try std.testing.expectEqualStrings("BA2BABA2BE", &got);
}

// 3) Glyph whitelist: every char must be in CONS/VOWS/DIGS
test "glyphs are from allowed sets" {
    const sample: [8]u8 = .{ 0xde, 0xad, 0xbe, 0xef, 0x12, 0x34, 0x56, 0x78 };
    const t10 = Wy64Ticket12.encode(&sample);
    const allowed = CONS ++ VOWS ++ DIGS;
    for (t10) |ch| {
        try std.testing.expect(std.mem.indexOfScalar(u8, allowed, ch) != null);
    }
}

// 4) SHA-256 preset: only assert lengths and character class (don’t freeze the exact string)
test "Sha256Ticket presets produce correct length and class" {
    const sha: [32]u8 = [_]u8{
        0x60, 0x4b, 0x0b, 0x0f, 0x83, 0x24, 0xa4, 0x2c,
        0x99, 0x2a, 0x8c, 0x91, 0x5d, 0x1b, 0x4a, 0x1e,
        0x97, 0x31, 0x0b, 0x7f, 0x2b, 0xf2, 0x84, 0x57,
        0x9c, 0x2a, 0x5c, 0x98, 0x73, 0x66, 0x11, 0x42,
    };
    const t16 = Sha256Ticket16.encode(&sha);
    const t20 = Sha256Ticket20.encode(&sha);

    try std.testing.expectEqual(@as(usize, Sha256Ticket16.out_len), t16.len);
    try std.testing.expectEqual(@as(usize, Sha256Ticket20.out_len), t20.len);

    const allowed = CONS ++ VOWS ++ DIGS;
    for (t16) |ch| try std.testing.expect(std.mem.indexOfScalar(u8, allowed, ch) != null);
    for (t20) |ch| try std.testing.expect(std.mem.indexOfScalar(u8, allowed, ch) != null);
}

// 5) beDivMod invariants on small numbers (quick sanity)
fn beToU16(b: [2]u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

test "beDivMod numeric check" {
    var x = [_]u8{ 0x01, 0x00 };
    const r = beDivMod(&x, 10);
    try std.testing.expectEqual(@as(u16, 6), r);
    try std.testing.expectEqual(@as(u16, 25), beToU16(x));
}

inline fn u64be(v: u64) [8]u8 {
    var o: [8]u8 = undefined;
    std.mem.writeInt(u64, &o, v, .big);
    return o;
}
inline fn u128be(v: u128) [16]u8 {
    var o: [16]u8 = undefined;
    std.mem.writeInt(u128, &o, v, .big);
    return o;
}

pub const StreamChunk = 64 * 1024;

// --- TIX12 (10 chars) from XXH3-64 (fast default) ---
pub fn tix12FromReader(reader: anytype) ![Wy64Ticket12.out_len]u8 {
    var h = std.hash.XxHash3.init(0); // same seed style as your tests
    var buf: [StreamChunk]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    const digest: u64 = h.final();
    const be = u64be(digest);
    return Wy64Ticket12.encode(&be);
}

// Optional variant using XxHash64 (also 64-bit)
pub fn tix12FromReader_xx64(reader: anytype) ![Wy64Ticket12.out_len]u8 {
    var h = std.hash.XxHash64.init(0);
    var buf: [StreamChunk]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    const digest: u64 = h.final();
    const be = u64be(digest);
    return Wy64Ticket12.encode(&be);
}

// --- TIX16 (13 chars) from SHA-256 (crypto, compact) ---
pub fn tix16FromReader_sha256(reader: anytype) ![Sha256Ticket16.out_len]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [StreamChunk]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return Sha256Ticket16.encode(&digest);
}

// --- TIX20 / TIX24 from SHA-256 (more headroom) ---
pub fn tix20FromReader_sha256(reader: anytype) ![Sha256Ticket20.out_len]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [StreamChunk]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return Sha256Ticket20.encode(&digest);
}

pub fn tix24FromReader_sha256(reader: anytype) ![Sha256Ticket24.out_len]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [StreamChunk]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return Sha256Ticket24.encode(&digest);
}

pub fn from(something: anytype) ![Wy64Ticket12.out_len]u8 {
    const T = @TypeOf(something);
    const ti = @typeInfo(T);

    // []const u8 / []u8
    if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
        var fbs = std.io.fixedBufferStream(something);
        return try tix12FromReader(fbs.reader());
    }

    // [N]u8
    if (ti == .array and ti.array.child == u8) {
        var fbs = std.io.fixedBufferStream(something[0..]);
        return try tix12FromReader(fbs.reader());
    }

    // *[N]u8 (pointer to array)
    if (ti == .pointer and ti.pointer.size == .one) {
        const child_info = @typeInfo(ti.pointer.child);
        if (child_info == .array and child_info.array.child == u8) {
            var fbs = std.io.fixedBufferStream(something[0..]);
            return try tix12FromReader(fbs.reader());
        }
    }

    // Anything with a .reader() method
    if (@hasDecl(T, "reader")) {
        return try tix12FromReader(something.reader());
    }

    // Already a reader type (has a read method)
    if (@hasDecl(T, "read")) {
        return try tix12FromReader(something);
    }

    @compileError("ticketOf: unsupported type: " ++ @typeName(T));
}

test "ticket of string" {
    const t = try from("Hello, world!");
    try std.testing.expectEqualStrings("BI5KUFI6QI", &t);
}
