const std = @import("std");
const mem = std.mem;

pub const ZstdEmbedReader = struct {
    const FbsType = std.io.FixedBufferStream([]const u8);
    const ReaderType = FbsType.Reader;
    const DecompType = std.compress.zstd.Decompressor(ReaderType);

    window: []u8,
    fbs: FbsType,
    dz: DecompType,

    pub fn init(allocator: mem.Allocator, bytes: []const u8) !ZstdEmbedReader {
        const window = try allocator.alloc(u8, std.compress.zstd.DecompressorOptions.default_window_buffer_len);
        var fbs = std.io.fixedBufferStream(bytes);
        const dz = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
        return .{ .window = window, .fbs = fbs, .dz = dz };
    }

    pub fn reader(self: *ZstdEmbedReader) DecompType.Reader {
        return self.dz.reader();
    }

    pub fn deinit(self: *ZstdEmbedReader, allocator: mem.Allocator) void {
        allocator.free(self.window);
    }
};

pub fn open(allocator: mem.Allocator, bytes: []const u8) !ZstdEmbedReader {
    return ZstdEmbedReader.init(allocator, bytes);
}
