const std = @import("std");
const simd = std.simd;
const testing = std.testing;

/// Returns true if `str` only contains ASCII bytes. Uses SIMD if possible.
pub fn isAsciiOnly(str: []const u8) bool {
    const vec_len = simd.suggestVectorLength(u8) orelse return for (str) |b| {
        if (b > 127) break false;
    } else true;

    const Vec = @Vector(vec_len, u8);
    var remaining = str;

    while (true) {
        if (remaining.len < vec_len) return for (remaining) |b| {
            if (b > 127) break false;
        } else true;

        const v1 = remaining[0..vec_len].*;
        const v2: Vec = @splat(127);
        if (@reduce(.Or, v1 > v2)) return false;
        remaining = remaining[vec_len..];
    }

    return true;
}

test "isAsciiOnly" {
    const ascii_only = "Hello, World! 0123456789 !@#$%^&*()_-=+";
    try testing.expect(isAsciiOnly(ascii_only));
    const not_ascii_only = "Héllo, World! 0123456789 !@#$%^&*()_-=+";
    try testing.expect(!isAsciiOnly(not_ascii_only));
}
