const std = @import("std");
const builtin = @import("builtin");

const Indic = enum {
    none,

    Consonant,
    Extend,
    Linker,
};

const Gbp = enum {
    none,

    Control,
    CR,
    Extend,
    L,
    LF,
    LV,
    LVT,
    Prepend,
    Regional_Indicator,
    SpacingMark,
    T,
    V,
    ZWJ,
};

const block_size = 256;
const Block = [block_size]u16;

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
            return std.mem.eql(u16, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var indic_map = std.AutoHashMap(u21, Indic).init(allocator);
    defer indic_map.deinit();

    var gbp_map = std.AutoHashMap(u21, Gbp).init(allocator);
    defer gbp_map.deinit();

    var emoji_set = std.AutoHashMap(u21, void).init(allocator);
    defer emoji_set.deinit();

    var line_buf: [4096]u8 = undefined;

    // Process Indic
    var indic_file = try std.fs.cwd().openFile("data/unicode/DerivedCoreProperties.txt", .{});
    defer indic_file.close();
    var indic_buf = std.io.bufferedReader(indic_file.reader());
    const indic_reader = indic_buf.reader();

    while (try indic_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "InCB") == null) continue;
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
                2 => {
                    // Prop
                    const prop = std.meta.stringToEnum(Indic, field) orelse return error.InvalidPorp;
                    for (current_code[0]..current_code[1] + 1) |cp| try indic_map.put(@intCast(cp), prop);
                },
                else => {},
            }
        }
    }

    // Process GBP
    var gbp_file = try std.fs.cwd().openFile("data/unicode/auxiliary/GraphemeBreakProperty.txt", .{});
    defer gbp_file.close();
    var gbp_buf = std.io.bufferedReader(gbp_file.reader());
    const gbp_reader = gbp_buf.reader();

    while (try gbp_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
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
                    // Prop
                    const prop = std.meta.stringToEnum(Gbp, field) orelse return error.InvalidPorp;
                    for (current_code[0]..current_code[1] + 1) |cp| try gbp_map.put(@intCast(cp), prop);
                },
                else => {},
            }
        }
    }

    // Process Emoji
    var emoji_file = try std.fs.cwd().openFile("data/unicode/emoji/emoji-data.txt", .{});
    defer emoji_file.close();
    var emoji_buf = std.io.bufferedReader(emoji_file.reader());
    const emoji_reader = emoji_buf.reader();

    while (try emoji_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "Extended_Pictographic") == null) continue;
        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = std.mem.tokenizeAny(u8, no_comment, "; ");

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (std.mem.indexOf(u8, field, "..")) |dots| {
                        const from = try std.fmt.parseInt(u21, field[0..dots], 16);
                        const to = try std.fmt.parseInt(u21, field[dots + 2 ..], 16);
                        for (from..to + 1) |cp| try emoji_set.put(@intCast(cp), {});
                    } else {
                        const cp = try std.fmt.parseInt(u21, field, 16);
                        try emoji_set.put(@intCast(cp), {});
                    }
                },
                else => {},
            }
        }
    }

    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.ArrayList(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.ArrayList(u16).init(allocator);
    defer stage2.deinit();

    var stage3 = std.AutoArrayHashMap(u8, u16).init(allocator);
    defer stage3.deinit();
    var stage3_len: u16 = 0;

    var block: Block = [_]u16{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const gbp_prop: u8 = @intFromEnum(gbp_map.get(cp) orelse .none);
        const indic_prop: u8 = @intFromEnum(indic_map.get(cp) orelse .none);
        const emoji_prop: u1 = @intFromBool(emoji_set.contains(cp));
        var props_byte: u8 = gbp_prop << 4;
        props_byte |= indic_prop << 1;
        props_byte |= emoji_prop;

        const stage3_idx = blk: {
            const gop = try stage3.getOrPut(props_byte);
            if (!gop.found_existing) {
                gop.value_ptr.* = stage3_len;
                stage3_len += 1;
            }

            break :blk gop.value_ptr.*;
        };

        block[block_len] = stage3_idx;
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
    for (stage2.items) |i| try writer.writeInt(u16, i, endian);

    const props_bytes = stage3.keys();
    try writer.writeInt(u16, @intCast(props_bytes.len), endian);
    try writer.writeAll(props_bytes);

    try out_comp.flush();
}
