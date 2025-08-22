const std = @import("std");

pub const LineReader = struct {
    bytes: []u8,
    it: std.mem.TokenIterator(u8, .scalar),

    pub fn initAlloc(allocator: std.mem.Allocator, path: []const u8) !LineReader {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        return .{ .bytes = bytes, .it = std.mem.tokenizeScalar(u8, bytes, '\n') };
    }

    pub fn next(self: *LineReader) ?[]const u8 {
        return self.it.next();
    }

    pub fn deinit(self: *LineReader, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};
