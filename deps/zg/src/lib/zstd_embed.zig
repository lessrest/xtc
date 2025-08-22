const std = @import("std");
const mem = std.mem;

pub const ZstdEmbedReader = struct {
    buffer: []u8,
    input: std.Io.Reader,
    decomp: std.compress.zstd.Decompress,

    pub fn init(allocator: mem.Allocator, bytes: []const u8) !ZstdEmbedReader {
        // Use an internal buffer for the indirect streaming path.
        const buf = try allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        var self: ZstdEmbedReader = .{
            .buffer = buf,
            .input = .fixed(bytes),
            .decomp = undefined,
        };
        self.decomp = std.compress.zstd.Decompress.init(&self.input, self.buffer, .{});
        return self;
    }

    pub fn reader(self: *ZstdEmbedReader) *std.Io.Reader {
        return &self.decomp.reader;
    }

    pub fn readAllAlloc(self: *ZstdEmbedReader, allocator: mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        _ = try self.decomp.reader.streamRemaining(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn deinit(self: *ZstdEmbedReader, allocator: mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

pub fn open(allocator: mem.Allocator, bytes: []const u8) !ZstdEmbedReader {
    return ZstdEmbedReader.init(allocator, bytes);
}
