const std = @import("std");
const builtin = @import("builtin");

const options = @import("options");

const block_size = 256;
const Block = [block_size]i4;

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
            return std.mem.eql(i4, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var flat_map = std.AutoHashMap(u21, i4).init(allocator);
    defer flat_map.deinit();

    var line_buf: [4096]u8 = undefined;

    // Process DerivedEastAsianWidth.txt
    var deaw_file = try std.fs.cwd().openFile("data/unicode/extracted/DerivedEastAsianWidth.txt", .{});
    defer deaw_file.close();
    var deaw_buf = std.io.bufferedReader(deaw_file.reader());
    const deaw_reader = deaw_buf.reader();

    while (try deaw_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        // @missing ranges
        if (std.mem.startsWith(u8, line, "# @missing: ")) {
            const semi = std.mem.indexOfScalar(u8, line, ';').?;
            const field = line[12..semi];
            const dots = std.mem.indexOf(u8, field, "..").?;
            const from = try std.fmt.parseInt(u21, field[0..dots], 16);
            const to = try std.fmt.parseInt(u21, field[dots + 2 ..], 16);
            if (from == 0 and to == 0x10ffff) continue;
            for (from..to + 1) |cp| try flat_map.put(@intCast(cp), 2);
            continue;
        }

        if (line[0] == '#') continue;

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
                    // Width
                    if (std.mem.eql(u8, field, "W") or
                        std.mem.eql(u8, field, "F") or
                        (options.cjk and std.mem.eql(u8, field, "A")))
                    {
                        for (current_code[0]..current_code[1] + 1) |cp| try flat_map.put(@intCast(cp), 2);
                    }
                },
                else => {},
            }
        }
    }

    // Process DerivedGeneralCategory.txt
    var dgc_file = try std.fs.cwd().openFile("data/unicode/extracted/DerivedGeneralCategory.txt", .{});
    defer dgc_file.close();
    var dgc_buf = std.io.bufferedReader(dgc_file.reader());
    const dgc_reader = dgc_buf.reader();

    while (try dgc_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
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
                    if (std.mem.eql(u8, field, "Mn")) {
                        // Nonspacing_Mark
                        for (current_code[0]..current_code[1] + 1) |cp| try flat_map.put(@intCast(cp), 0);
                    } else if (std.mem.eql(u8, field, "Me")) {
                        // Enclosing_Mark
                        for (current_code[0]..current_code[1] + 1) |cp| try flat_map.put(@intCast(cp), 0);
                    } else if (std.mem.eql(u8, field, "Mc")) {
                        // Spacing_Mark
                        for (current_code[0]..current_code[1] + 1) |cp| try flat_map.put(@intCast(cp), 0);
                    } else if (std.mem.eql(u8, field, "Cf")) {
                        if (std.mem.indexOf(u8, line, "ARABIC") == null) {
                            // Format except Arabic
                            for (current_code[0]..current_code[1] + 1) |cp| try flat_map.put(@intCast(cp), 0);
                        }
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

    var stage2 = std.ArrayList(i4).init(allocator);
    defer stage2.deinit();

    var block: Block = [_]i4{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        var width = flat_map.get(cp) orelse 1;

        // Specific overrides
        switch (cp) {
            // Three-em dash
            0x2e3b => width = 3,

            // C0/C1 control codes
            0...0x20 => width = if (options.c0_width) |c0| c0 else 0,
            0x80...0x9f => width = if (options.c1_width) |c1| c1 else 0,

            // Line separator
            0x2028,

            // Paragraph separator
            0x2029,

            // Hangul syllable and ignorable.
            0x1160...0x11ff,
            0xd7b0...0xd7ff,
            0x2060...0x206f,
            0xfff0...0xfff8,
            0xe0000...0xE0fff,
            => width = 0,

            // Two-em dash
            0x2e3a,

            // Regional indicators
            0x1f1e6...0x1f200,

            // CJK Blocks
            0x3400...0x4dbf, // CJK Unified Ideographs Extension A
            0x4e00...0x9fff, // CJK Unified Ideographs
            0xf900...0xfaff, // CJK Compatibility Ideographs
            0x20000...0x2fffd, // Plane 2
            0x30000...0x3fffd, // Plane 3
            => width = 2,

            else => {},
        }

        // ASCII
        if (0x20 <= cp and cp < 0x7f) width = 1;

        // Soft hyphen
        if (cp == 0xad) width = 1;

        // Backspace and delete
        if (cp == 0x8 or cp == 0x7f) width = if (options.c0_width) |c0| c0 else -1;

        // Process block
        block[block_len] = width;
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
    for (stage2.items) |i| try writer.writeInt(i8, i, endian);

    try out_comp.flush();
}
