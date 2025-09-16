const std = @import("std");

const consonants = "BCDFGHJKMNPQRSTVWXYZ";
const vowels = "AEIOU";
const digits = "23456789";

const Cell = enum {
    cvn,
    cv,

    fn base(self: Cell) u16 {
        return switch (self) {
            .cvn => 800,
            .cv => 100,
        };
    }

    fn width(self: Cell) comptime_int {
        return switch (self) {
            .cvn => 3,
            .cv => 2,
        };
    }

    fn write(cell: Cell, digit: u16, out: *std.Io.Writer) !void {
        switch (cell) {
            .cvn => {
                try out.writeByte(consonants[digit / 40]);
                try out.writeByte(vowels[(digit / 8) % 5]);
                try out.writeByte(digits[digit % 8]);
            },
            .cv => {
                try out.writeByte(consonants[digit / 5]);
                try out.writeByte(vowels[digit % 5]);
            },
        }
    }
};

fn encodedLen(comptime layout: []const Cell) comptime_int {
    var total: usize = 0;
    inline for (layout) |cell| total += cell.width();
    return total;
}

/// Builds a ticket encoder using the provided `Hasher` and cell `pattern`.
/// The hasher must expose `init(seed)`, `update([]const u8)`, and `final() u64`.
pub fn TicketWriter(comptime Hasher: type, comptime pattern: []const Cell) type {
    const fn_info = switch (@typeInfo(@TypeOf(Hasher.init))) {
        .@"fn" => |info| info,
        else => @compileError("Hasher.init must be a function"),
    };
    comptime {
        if (fn_info.params.len != 1) @compileError("Hasher.init must accept exactly one parameter");
        if (fn_info.return_type == null) @compileError("Hasher.init must return a hasher instance");
    }

    const SeedType = fn_info.params[0].type.?;

    return struct {
        pub const Data = [encodedLen(pattern)]u8;

        pub const Seed = SeedType;

        /// Hashes formatted data with the provided `seed` and returns the ticket.
        pub fn format(seed: Seed, comptime fmt: []const u8, args: anytype) Data {
            var ctx = HashingWriter.initHasher(Hasher.init(seed), &.{});
            ctx.writer.print(fmt, args) catch unreachable;
            ctx.writer.flush() catch unreachable;
            return encoded(ctx.hasher.final());
        }

        /// Convenience wrapper over `format` for byte slices and strings.
        pub fn string(seed: Seed, value: anytype) Data {
            if (std.meta.Elem(@TypeOf(value)) != u8) {
                @compileError("fromString only accepts strings");
            }

            return format(seed, "{s}", .{value});
        }

        /// Encodes a ticket derived from the pointer's address.
        pub fn pointer(seed: Seed, ptr: anytype) Data {
            if (@typeInfo(@TypeOf(ptr)) != .pointer) {
                @compileError("fromAddress only accepts pointers");
            }

            return format(seed, "{p}", .{ptr});
        }

        /// Streams data from `reader` into the hasher using the caller's buffer.
        pub fn fromReader(seed: Seed, reader: *std.Io.Reader, buffer: []u8) !Data {
            var ctx = HashingWriter.initHasher(Hasher.init(seed), buffer);
            _ = try reader.streamRemaining(&ctx.writer);
            ctx.writer.flush() catch unreachable;
            return encoded(ctx.hasher.final());
        }

        const HashingWriter = std.Io.Writer.Hashing(Hasher);

        fn writeEncoded(digest: u64, writer: *std.Io.Writer) !void {
            var value = digest;
            var digits_buf: [pattern.len]u16 = undefined;

            comptime var index = pattern.len;
            inline while (index > 0) {
                index -= 1;
                const base = pattern[index].base();
                digits_buf[index] = @intCast(value % base);
                value /= base;
            }

            inline for (pattern, 0..) |cell, i| {
                try cell.write(digits_buf[i], writer);
            }
        }

        fn encoded(digest: u64) Data {
            var out: Data = undefined;
            var w = std.Io.Writer.fixed(&out);
            writeEncoded(digest, &w) catch unreachable;
            return out;
        }
    };
}

fn TicketPreset(comptime Writer: type, comptime seed: Writer.Seed) type {
    return struct {
        pub const Data = Writer.Data;

        /// Hashes formatted data using the preset seed.
        pub fn format(comptime fmt: []const u8, args: anytype) Data {
            return Writer.format(seed, fmt, args);
        }

        /// Hashes string-like data using the preset seed.
        pub fn string(value: anytype) Data {
            return Writer.string(seed, value);
        }

        /// Hashes pointer addresses using the preset seed.
        pub fn pointer(ptr: anytype) Data {
            return Writer.pointer(seed, ptr);
        }

        /// Streams reader data using the preset seed and caller buffer.
        pub fn fromReader(reader: *std.Io.Reader, buffer: []u8) !Data {
            return Writer.fromReader(seed, reader, buffer);
        }
    };
}

const compact_pattern = [_]Cell{ .cvn, .cv, .cvn };
const fast_pattern = [_]Cell{ .cvn, .cv, .cvn, .cv };
const secure_pattern = [_]Cell{ .cvn, .cv, .cvn, .cv, .cvn, .cv };

/// Internal generator powering `TicketCompact`; trades headroom for brevity.
const CompactWriter = TicketWriter(std.hash.Wyhash, &compact_pattern);
/// Internal generator for `TicketFast`, our default rhythm.
const FastWriter = TicketWriter(std.hash.XxHash3, &fast_pattern);
const SecureHasher = struct {
    const Inner = std.hash.SipHash64(2, 4);

    inner: Inner,

    pub fn init(key: [16]u8) SecureHasher {
        return .{ .inner = Inner.init(&key) };
    }

    pub fn update(self: *SecureHasher, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *SecureHasher) u64 {
        return self.inner.finalInt();
    }
};

/// Internal generator for `TicketSecure`, using SipHash-derived digests.
const SecureWriter = TicketWriter(SecureHasher, &secure_pattern);

/// 8-character, non-keyed ticket tuned for log-friendly compact IDs.
pub const TicketCompact = TicketPreset(CompactWriter, 0);
/// 10-character default ticket that balances readability and avalanche behaviour.
pub const TicketFast = TicketPreset(FastWriter, 0);
/// Alias of `TicketFast` kept for existing callers.
pub const Ticket = TicketFast;

/// Keyed SipHash64-based ticket with 15 characters for untrusted inputs.
pub const TicketSecure = struct {
    pub const Data = SecureWriter.Data;
    pub const Key = SecureWriter.Seed;

    /// Hashes formatted data with the supplied secret key.
    pub fn format(key: Key, comptime fmt: []const u8, args: anytype) Data {
        return SecureWriter.format(key, fmt, args);
    }

    /// Hashes string-like data with the supplied secret key.
    pub fn string(key: Key, value: anytype) Data {
        return SecureWriter.string(key, value);
    }

    /// Hashes pointer addresses with the supplied secret key.
    pub fn pointer(key: Key, ptr: anytype) Data {
        return SecureWriter.pointer(key, ptr);
    }

    /// Streams reader data with the supplied secret key.
    pub fn fromReader(key: Key, reader: *std.Io.Reader, buffer: []u8) !Data {
        return SecureWriter.fromReader(key, reader, buffer);
    }
};

test "ticket compact" {
    const t = TicketCompact.string("Hello, world!");
    try std.testing.expectEqual(encodedLen(&compact_pattern), t.len);
}

test "ticket fast matches previous output" {
    const t = TicketFast.string("Hello, world!");
    try std.testing.expectEqualStrings("BI5KUFI6QI", &t);
}

test "ticket fast pointer uniqueness" {
    const xs = [_]u32{ 42, 42 };
    const t1 = TicketFast.pointer(&xs[0]);
    const t2 = TicketFast.pointer(&xs[1]);
    const fast_len = encodedLen(&fast_pattern);
    try std.testing.expectEqual(fast_len, t1.len);
    try std.testing.expectEqual(fast_len, t2.len);
    try std.testing.expect(!std.mem.eql(u8, &t1, &t2));
}

test "ticket fast reader buffers" {
    var reader = std.Io.Reader.fixed("Hello, world!");
    const ticket = try TicketFast.fromReader(&reader, &.{});
    try std.testing.expectEqualStrings("BI5KUFI6QI", &ticket);

    var reader_large = std.Io.Reader.fixed("Hello, world!");
    var buf_large: [64]u8 = undefined;
    const ticket_large = try TicketFast.fromReader(&reader_large, &buf_large);
    try std.testing.expectEqualStrings("BI5KUFI6QI", &ticket_large);

    var reader_small = std.Io.Reader.fixed("Hello, world!");
    var buf_small: [4]u8 = undefined;
    const ticket_small = try TicketFast.fromReader(&reader_small, &buf_small);
    try std.testing.expectEqualStrings("BI5KUFI6QI", &ticket_small);
}

test "ticket characters stay in whitelist" {
    const sample = "0123456789abcdefghijklmnopqrstuvwxyz";
    const ticket = TicketFast.string(sample);
    const allowed = consonants ++ vowels ++ digits;
    for (ticket) |ch| {
        try std.testing.expect(std.mem.indexOfScalar(u8, allowed, ch) != null);
    }
}

test "secure ticket requires key" {
    const key_a = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const key_b = [_]u8{0xff} ** 16;
    const ta = TicketSecure.string(key_a, "Hello, world!");
    const tb = TicketSecure.string(key_b, "Hello, world!");
    const secure_len = encodedLen(&secure_pattern);
    try std.testing.expectEqual(secure_len, ta.len);
    try std.testing.expectEqual(secure_len, tb.len);
    try std.testing.expect(!std.mem.eql(u8, &ta, &tb));
}
