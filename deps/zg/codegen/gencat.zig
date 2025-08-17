const std = @import("std");
const builtin = @import("builtin");

const Gc = enum {
    Cc, // Other, Control
    Cf, // Other, Format
    Cn, // Other, Unassigned
    Co, // Other, Private Use
    Cs, // Other, Surrogate
    Ll, // Letter, Lowercase
    Lm, // Letter, Modifier
    Lo, // Letter, Other
    Lu, // Letter, Uppercase
    Lt, // Letter, Titlecase
    Mc, // Mark, Spacing Combining
    Me, // Mark, Enclosing
    Mn, // Mark, Non-Spacing
    Nd, // Number, Decimal Digit
    Nl, // Number, Letter
    No, // Number, Other
    Pc, // Punctuation, Connector
    Pd, // Punctuation, Dash
    Pe, // Punctuation, Close
    Pf, // Punctuation, Final quote (may behave like Ps or Pe depending on usage)
    Pi, // Punctuation, Initial quote (may behave like Ps or Pe depending on usage)
    Po, // Punctuation, Other
    Ps, // Punctuation, Open
    Sc, // Symbol, Currency
    Sk, // Symbol, Modifier
    Sm, // Symbol, Math
    So, // Symbol, Other
    Zl, // Separator, Line
    Zp, // Separator, Paragraph
    Zs, // Separator, Space
};

const block_size = 256;
const Block = [block_size]u5;

const BlockMap = std.HashMap(
    Block,
    u16,
    struct {
        pub fn hash(_: @This(), k: Block) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, k, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Block, b: Block) bool {
            return std.mem.eql(u5, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var flat_map = std.AutoHashMap(u21, u5).init(allocator);
    defer flat_map.deinit();

    var line_buf: [4096]u8 = undefined;

    // Process DerivedGeneralCategory.txt
    var in_file = try std.fs.cwd().openFile("data/unicode/extracted/DerivedGeneralCategory.txt", .{});
    defer in_file.close();
    var in_buf = std.io.bufferedReader(in_file.reader());
    const in_reader = in_buf.reader();

    while (try in_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = std.mem.tokenizeAny(u8, no_comment, "; ");
        var current_code: [2]u21 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (std.mem.indexOf(u8, field, "..")) |dots| {
                        current_code = .{
                            try std.fmt.parseInt(u21, field[0..dots], 16),
                            try std.fmt.parseInt(u21, field[dots + 2 ..], 16),
                        };
                    } else {
                        const code = try std.fmt.parseInt(u21, field, 16);
                        current_code = .{ code, code };
                    }
                },
                1 => {
                    // General category
                    const gc = std.meta.stringToEnum(Gc, field) orelse return error.UnknownGenCat;
                    for (current_code[0]..current_code[1] + 1) |cp| try flat_map.put(@intCast(cp), @intFromEnum(gc));
                },
                else => {},
            }
        }
    }

    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.ArrayList(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.ArrayList(u5).init(allocator);
    defer stage2.deinit();

    var stage3 = std.ArrayList(u5).init(allocator);
    defer stage3.deinit();

    var block: Block = [_]u5{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const gc = flat_map.get(cp).?;

        const stage3_idx = blk: {
            for (stage3.items, 0..) |gci, j| {
                if (gc == gci) break :blk j;
            }
            try stage3.append(gc);
            break :blk stage3.items.len - 1;
        };

        // Process block
        block[block_len] = @intCast(stage3_idx);
        block_len += 1;

        if (block_len < block_size and cp != 0x10ffff) continue;

        const gop = try blocks_map.getOrPut(block);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(stage2.items.len);
            try stage2.appendSlice(&block);
        }

        try stage1.append(gop.value_ptr.*);
        block_len = 0;
    }

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    const compressor = std.compress.flate.deflate.compressor;
    var out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var out_comp = try compressor(.raw, out_file.writer(), .{ .level = .best });
    const writer = out_comp.writer();

    const endian = builtin.cpu.arch.endian();
    try writer.writeInt(u16, @intCast(stage1.items.len), endian);
    for (stage1.items) |i| try writer.writeInt(u16, i, endian);

    try writer.writeInt(u16, @intCast(stage2.items.len), endian);
    for (stage2.items) |i| try writer.writeInt(u8, i, endian);

    try writer.writeInt(u8, @intCast(stage3.items.len), endian);
    for (stage3.items) |i| try writer.writeInt(u8, i, endian);

    try out_comp.flush();
}
