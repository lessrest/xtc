const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Process DerivedCoreProperties.txt
    var props_file = try std.fs.cwd().openFile("data/unicode/DerivedCoreProperties.txt", .{});
    defer props_file.close();
    var props_buf = std.io.bufferedReader(props_file.reader());
    const props_reader = props_buf.reader();

    var props_map = std.AutoHashMap(u21, void).init(allocator);
    defer props_map.deinit();

    var line_buf: [4096]u8 = undefined;

    props_lines: while (try props_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
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
                    // Core property
                    if (!mem.eql(u8, field, "Changes_When_Casefolded")) continue :props_lines;
                    for (current_code[0]..current_code[1] + 1) |cp| try props_map.put(@intCast(cp), {});
                },
                else => {},
            }
        }
    }

    var codepoint_mapping = std.AutoArrayHashMap(u21, [3]u21).init(allocator);
    defer codepoint_mapping.deinit();

    // Process CaseFolding.txt
    var cp_file = try std.fs.cwd().openFile("data/unicode/CaseFolding.txt", .{});
    defer cp_file.close();
    var cp_buf = std.io.bufferedReader(cp_file.reader());
    const cp_reader = cp_buf.reader();

    while (try cp_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        var field_it = std.mem.splitScalar(u8, line, ';');
        const codepoint_str = field_it.first();
        const codepoint = try std.fmt.parseUnsigned(u21, codepoint_str, 16);

        const status = std.mem.trim(u8, field_it.next() orelse continue, " ");
        // Only interested in 'common' and 'full'
        if (status[0] != 'C' and status[0] != 'F') continue;

        const mapping = std.mem.trim(u8, field_it.next() orelse continue, " ");
        var mapping_it = std.mem.splitScalar(u8, mapping, ' ');
        var mapping_buf = [_]u21{0} ** 3;
        var mapping_i: u8 = 0;
        while (mapping_it.next()) |mapping_c| {
            mapping_buf[mapping_i] = try std.fmt.parseInt(u21, mapping_c, 16);
            mapping_i += 1;
        }

        try codepoint_mapping.putNoClobber(codepoint, mapping_buf);
    }

    var changes_when_casefolded_exceptions = std.ArrayList(u21).init(allocator);
    defer changes_when_casefolded_exceptions.deinit();

    {
        // Codepoints with a case fold mapping can be missing the Changes_When_Casefolded property,
        // but not vice versa.
        for (codepoint_mapping.keys()) |codepoint| {
            if (props_map.get(codepoint) == null) {
                try changes_when_casefolded_exceptions.append(codepoint);
            }
        }
    }

    var offset_to_index = std.AutoHashMap(i32, u8).init(allocator);
    defer offset_to_index.deinit();
    var unique_offsets = std.AutoArrayHashMap(i32, u32).init(allocator);
    defer unique_offsets.deinit();

    // First pass
    {
        var it = codepoint_mapping.iterator();
        while (it.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const mappings = std.mem.sliceTo(entry.value_ptr, 0);
            if (mappings.len == 1) {
                const offset: i32 = @as(i32, mappings[0]) - @as(i32, codepoint);
                const result = try unique_offsets.getOrPut(offset);
                if (!result.found_existing) result.value_ptr.* = 0;
                result.value_ptr.* += 1;
            }
        }

        // A codepoint mapping to itself (offset=0) is the most common case
        try unique_offsets.put(0, 0x10FFFF);
        const C = struct {
            vals: []u32,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.vals[a_index] > ctx.vals[b_index];
            }
        };
        unique_offsets.sort(C{ .vals = unique_offsets.values() });

        var offset_it = unique_offsets.iterator();
        var offset_index: u7 = 0;
        while (offset_it.next()) |entry| {
            try offset_to_index.put(entry.key_ptr.*, offset_index);
            offset_index += 1;
        }
    }

    var mappings_to_index = std.AutoArrayHashMap([3]u21, u8).init(allocator);
    defer mappings_to_index.deinit();
    var codepoint_to_index = std.AutoHashMap(u21, u8).init(allocator);
    defer codepoint_to_index.deinit();

    // Second pass
    {
        var count_multiple_codepoints: u8 = 0;

        var it = codepoint_mapping.iterator();
        while (it.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const mappings = std.mem.sliceTo(entry.value_ptr, 0);
            if (mappings.len > 1) {
                const result = try mappings_to_index.getOrPut(entry.value_ptr.*);
                if (!result.found_existing) {
                    result.value_ptr.* = 0x80 | count_multiple_codepoints;
                    count_multiple_codepoints += 1;
                }
                const index = result.value_ptr.*;
                try codepoint_to_index.put(codepoint, index);
            } else {
                const offset: i32 = @as(i32, mappings[0]) - @as(i32, codepoint);
                const index = offset_to_index.get(offset).?;
                try codepoint_to_index.put(codepoint, index);
            }
        }
    }

    // Build the stage1/stage2/stage3 arrays and output them
    {
        const Block = [256]u8;
        var stage2_blocks = std.AutoArrayHashMap(Block, void).init(allocator);
        defer stage2_blocks.deinit();

        const empty_block: Block = [_]u8{0} ** 256;
        try stage2_blocks.put(empty_block, {});
        const stage1_len = (0x10FFFF / 256) + 1;
        var stage1: [stage1_len]u8 = undefined;

        var codepoint: u21 = 0;
        var block: Block = undefined;
        while (codepoint <= 0x10FFFF) {
            const data_index = codepoint_to_index.get(codepoint) orelse 0;
            block[codepoint % 256] = data_index;

            codepoint += 1;
            if (codepoint % 256 == 0) {
                const result = try stage2_blocks.getOrPut(block);
                const index = result.index;
                stage1[(codepoint >> 8) - 1] = @intCast(index);
            }
        }

        const last_meaningful_block = std.mem.lastIndexOfNone(u8, &stage1, "\x00").?;
        const meaningful_stage1 = stage1[0 .. last_meaningful_block + 1];
        const codepoint_cutoff = (last_meaningful_block + 1) << 8;
        const multiple_codepoint_start: usize = unique_offsets.count();

        var index: usize = 0;
        const stage3_elems = unique_offsets.count() + mappings_to_index.count() * 3;
        var stage3 = try allocator.alloc(i24, stage3_elems);
        defer allocator.free(stage3);
        for (unique_offsets.keys()) |key| {
            stage3[index] = @intCast(key);
            index += 1;
        }
        for (mappings_to_index.keys()) |key| {
            stage3[index] = @intCast(key[0]);
            stage3[index + 1] = @intCast(key[1]);
            stage3[index + 2] = @intCast(key[2]);
            index += 3;
        }

        const stage2_elems = stage2_blocks.count() * 256;
        var stage2 = try allocator.alloc(u8, stage2_elems);
        defer allocator.free(stage2);
        for (stage2_blocks.keys(), 0..) |key, i| {
            @memcpy(stage2[i * 256 ..][0..256], &key);
        }

        // Write out compressed binary data file.
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
        // Table metadata.
        try writer.writeInt(u24, @intCast(codepoint_cutoff), endian);
        try writer.writeInt(u24, @intCast(multiple_codepoint_start), endian);
        // Stage 1
        try writer.writeInt(u16, @intCast(meaningful_stage1.len), endian);
        try writer.writeAll(meaningful_stage1);
        // Stage 2
        try writer.writeInt(u16, @intCast(stage2.len), endian);
        try writer.writeAll(stage2);
        // Stage 3
        try writer.writeInt(u16, @intCast(stage3.len), endian);
        for (stage3) |offset| try writer.writeInt(i24, offset, endian);
        // Changes when case folded
        // Min and max
        try writer.writeInt(u24, std.mem.min(u21, changes_when_casefolded_exceptions.items), endian);
        try writer.writeInt(u24, std.mem.max(u21, changes_when_casefolded_exceptions.items), endian);
        try writer.writeInt(u16, @intCast(changes_when_casefolded_exceptions.items.len), endian);
        for (changes_when_casefolded_exceptions.items) |cp| try writer.writeInt(u24, cp, endian);

        try out_comp.flush();
    }
}
