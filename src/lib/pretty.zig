const std = @import("std");

pub fn Pretty_(Data: type, N: comptime_int, Parts: [N]type) type {
    return struct {
        position: usize = 0,
        writer: *std.Io.Writer,

        const Self = @This();

        pub fn to(writer: *std.Io.Writer) Self {
            return Self{ .writer = writer };
        }

        pub fn print(writer: *std.Io.Writer, data: Data) !void {
            var self = Self.to(writer);
            try self.format(data);
        }

        pub fn num(comptime tag: std.meta.FieldEnum(Data)) type {
            return Pretty_(Data, N + 1, Parts ++ .{struct {
                pub fn write(self: anytype, data: Data) !void {
                    const x = @field(data, @tagName(tag));
                    try self.writer.print("{d}", .{x});
                    self.position += @as(usize, @intCast(std.fmt.count("{d}", .{x})));
                }
            }});
        }

        pub fn tab(n: comptime_int) type {
            return Pretty_(Data, N + 1, Parts ++ .{struct {
                pub fn write(self: anytype, _: Data) !void {
                    if (self.position < n) {
                        try self.writer.splatByteAll(' ', n - self.position);
                        self.position = n;
                    }
                }
            }});
        }

        pub fn str(tag: std.meta.FieldEnum(Data)) type {
            return Pretty_(Data, N + 1, Parts ++ .{struct {
                pub fn write(self: anytype, data: Data) !void {
                    const x = @field(data, @tagName(tag));
                    try self.writer.print("{s}", .{x});
                    self.position += @as(usize, @intCast(std.fmt.count("{s}", .{x})));
                }
            }});
        }

        pub fn format(self: *Self, data: Data) !void {
            inline for (Parts) |Part| {
                try Part.write(self, data);
            }
            try self.writer.writeAll("\n");
            self.position = 0;
        }

        pub fn flush(self: *Self) !void {
            try self.writer.flush();
        }
    };
}

pub fn Pretty(Data: type) type {
    return Pretty_(Data, 0, .{});
}

pub fn main() !void {
    const GadgetData = struct {
        idx: i32,
        name: []const u8,
    };

    const Line = Pretty(GadgetData)
        .num(.idx)
        .tab(6)
        .str(.name);

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try Line.print(&writer, .{ .idx = 10, .name = "thingy" });

    try std.testing.expectEqualStrings(
        \\10    thingy
        \\
    , writer.buffered());
}

test "basic pretty printing API" {
    const GadgetData = struct {
        idx: i32,
        name: []const u8,
    };

    const Line = Pretty(GadgetData)
        .num(.idx)
        .tab(6)
        .str(.name);

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try Line.print(&writer, .{ .idx = 10, .name = "thingy" });

    try std.testing.expectEqualStrings(
        \\10    thingy
        \\
    , writer.buffered());
}

test "without intermediate const" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try Pretty(struct {
        idx: i32,
        name: []const u8,
    })
        .num(.idx).tab(6).str(.name)
        .print(&writer, .{ .idx = 10, .name = "thingy" });

    try std.testing.expectEqualStrings(
        \\10    thingy
        \\
    , writer.buffered());
}

test "several items with the same printer" {
    const Line = Pretty(struct {
        idx: i32,
        name: []const u8,
    }).num(.idx).tab(6).str(.name);

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var output = Line.to(&writer);

    try output.format(.{ .idx = 10, .name = "thingy" });
    try output.format(.{ .idx = 20, .name = "other" });
    try output.format(.{ .idx = 30, .name = "third" });

    try std.testing.expectEqualStrings(
        \\10    thingy
        \\20    other
        \\30    third
        \\
    , writer.buffered());
}
