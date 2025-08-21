const std = @import("std");

const GlyphTable = @This();

pub const GlyphId = u32; // 0..=255 self-map to single-byte ASCII

/// Fixed-capacity-friendly glyph interning built on std's unmanaged string map.
/// Keys are UTF-8 byte slices that live in a contiguous arena; values are `GlyphId`.
/// Glyph ids 0..=255 are reserved for single-byte glyphs (ASCII/self-mapped).
const Span = struct { off: u32, len: u8 };

alloc: std.mem.Allocator,
map: std.StringArrayHashMap(GlyphId),
arena: std.ArrayList(u8),
spans: std.MultiArrayList(Span), // index => (off,len), id == index

pub fn init(allocator: std.mem.Allocator) !*GlyphTable {
    var gt = try allocator.create(GlyphTable);
    errdefer allocator.destroy(gt);

    gt.* = .{
        .alloc = allocator,
        .map = std.StringArrayHashMap(GlyphId).initContext(
            allocator,
            std.array_hash_map.StringContext{},
        ),
        .arena = std.ArrayList(u8).init(allocator),
        .spans = std.MultiArrayList(Span).empty,
    };

    // Prepopulate ASCII 0x00..0xFF as self-mapped one-byte spans
    try gt.spans.ensureTotalCapacity(allocator, 256);
    try gt.arena.ensureTotalCapacity(256);
    try gt.map.ensureTotalCapacity(256);
    errdefer gt.map.deinit();
    errdefer gt.arena.deinit();
    errdefer gt.spans.deinit(allocator);

    var ascii_i: usize = 0;
    while (ascii_i < 256) : (ascii_i += 1) {
        const off: u32 = @intCast(gt.arena.items.len);
        try gt.arena.append(@as(u8, @intCast(ascii_i)));
        gt.spans.appendAssumeCapacity(.{ .off = off, .len = 1 });
        const key = gt.arena.items[@as(usize, off) .. @as(usize, off) + 1];
        gt.map.putAssumeCapacity(key, @as(GlyphId, @intCast(ascii_i)));
    }
    return gt;
}

pub fn deinit(self: *GlyphTable) void {
    self.map.deinit();
    self.arena.deinit();
    self.spans.deinit(self.alloc);
    self.alloc.destroy(self);
}

pub fn clearRetainingCapacity(self: *GlyphTable) void {
    self.map.clearRetainingCapacity();
    self.arena.clearRetainingCapacity();
    self.spans.clearRetainingCapacity();
}

/// Interns `bytes` and returns a glyph id. Single-byte values map directly to that byte value.
pub fn intern(self: *GlyphTable, allocator: std.mem.Allocator, bytes: []const u8) !GlyphId {
    if (bytes.len == 1) return @as(GlyphId, bytes[0]);
    if (self.map.get(bytes)) |existing| return existing;
    if (bytes.len > std.math.maxInt(u8)) return error.GlyphTooLong;

    const off_u32: u32 = @intCast(self.arena.items.len);
    try self.arena.appendSlice(bytes);
    const len_u8: u8 = @intCast(bytes.len);
    try self.spans.append(allocator, .{ .off = off_u32, .len = len_u8 });
    const id: GlyphId = @intCast(self.spans.len - 1);

    // Create a stable slice into arena memory for the key.
    const base_ptr: [*]u8 = self.arena.items.ptr;
    const key: []const u8 = base_ptr[off_u32 .. off_u32 + len_u8];
    try self.map.put(key, id);
    return id;
}

/// Returns the (off,len) span for any id including ASCII.
pub fn getSpan(self: *const GlyphTable, id: GlyphId) ?Span {
    const idx: usize = @as(usize, @intCast(id));
    if (idx >= self.spans.len) return null;
    return self.spans.get(idx);
}

pub fn getSlice(self: *const GlyphTable, id: GlyphId) ?[]const u8 {
    const span = self.getSpan(id) orelse return null;
    const off: usize = span.off;
    const len: usize = span.len;
    return self.arena.items[off .. off + len];
}
