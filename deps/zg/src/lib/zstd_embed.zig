const std = @import("std");
const mem = std.mem;
const zstd = std.compress.zstd;

pub const ZstdEmbedReader = struct {
    allocator: mem.Allocator,
    bytes: []const u8,

    pub fn init(allocator: mem.Allocator, bytes: []const u8) ZstdEmbedReader {
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn readAllAlloc(self: *ZstdEmbedReader, allocator: mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = try .initCapacity(
            allocator,
            zstd.default_window_len + zstd.block_size_max,
        );

        defer out.deinit();

        var input: std.Io.Reader = .fixed(self.bytes);
        var decomp = zstd.Decompress.init(&input, .{}, .{});
        _ = try decomp.reader.streamRemaining(&out.writer);

        return out.toOwnedSlice();
    }

    pub fn deinit(self: *ZstdEmbedReader, allocator: mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

pub fn open(allocator: mem.Allocator, bytes: []const u8) !ZstdEmbedReader {
    return ZstdEmbedReader.init(allocator, bytes);
}
