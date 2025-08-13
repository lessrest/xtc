const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Process UnicodeData.txt
    var in_file = try std.fs.cwd().openFile("data/unicode/UnicodeData.txt", .{});
    defer in_file.close();
    var in_buf = std.io.bufferedReader(in_file.reader());
    const in_reader = in_buf.reader();

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
    var line_buf: [4096]u8 = undefined;

    lines: while (try in_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, line, ';');
        var cp: i24 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => cp = try std.fmt.parseInt(i24, field, 16),

                2 => if (line[0] == '<') continue :lines,

                12 => {
                    // Simple uppercase mapping
                    if (field.len == 0) continue :lines;
                    try writer.writeInt(i24, cp, endian);
                    const mapping = try std.fmt.parseInt(i24, field, 16);
                    try writer.writeInt(i24, mapping - cp, endian);
                },

                else => {},
            }
        }
    }

    try writer.writeInt(u24, 0, endian);
    try out_comp.flush();
}
