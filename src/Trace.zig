const std = @import("std");

const Trace = @This();

enabled: bool,
depth: usize,

pub fn init(enabled: bool) Trace {
    return .{
        .enabled = enabled,
        .depth = 0,
    };
}

fn getIndent(self: *const Trace) []const u8 {
    const spaces = "                                                                                ";
    const n = if (self.depth * 2 > spaces.len) spaces.len else self.depth * 2;
    return spaces[0..n];
}

fn escapeXml(self: anytype, str: []const u8) void {
    for (str) |c| {
        switch (c) {
            '<' => self.print("&lt;", .{}),
            '>' => self.print("&gt;", .{}),
            '&' => self.print("&amp;", .{}),
            '"' => self.print("&quot;", .{}),
            '\'' => self.print("&apos;", .{}),
            else => self.print("{c}", .{c}),
        }
    }
}

const StyleRow = @import("style.zig").StyleRow;

fn writeXmlValueInline(buf: []u8, value: anytype) []const u8 {
    const ValueType = @TypeOf(value);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (@typeInfo(ValueType)) {
        .int => writer.print("{d}", .{value}) catch return "",
        .float => writer.print("{d:.2}", .{value}) catch return "",
        .bool => writer.print("{}", .{value}) catch return "",
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                writer.writeAll("\"") catch return "";
                for (value) |c| {
                    switch (c) {
                        '<' => writer.writeAll("&lt;") catch return "",
                        '>' => writer.writeAll("&gt;") catch return "",
                        '&' => writer.writeAll("&amp;") catch return "",
                        '"' => writer.writeAll("&quot;") catch return "",
                        '\'' => writer.writeAll("&apos;") catch return "",
                        else => writer.writeByte(c) catch return "",
                    }
                }
                writer.writeAll("\"") catch return "";
            } else {
                writer.print("{any}", .{value}) catch return "";
            }
        },
        .array => |arr_info| {
            if (arr_info.child == u8) {
                for (value) |c| {
                    switch (c) {
                        '<' => writer.writeAll("&lt;") catch return "",
                        '>' => writer.writeAll("&gt;") catch return "",
                        '&' => writer.writeAll("&amp;") catch return "",
                        '"' => writer.writeAll("&quot;") catch return "",
                        '\'' => writer.writeAll("&apos;") catch return "",
                        else => writer.writeByte(c) catch return "",
                    }
                }
            } else {
                writer.print("{any}", .{value}) catch return "";
            }
        },
        .@"enum" => writer.print("{s}", .{@tagName(value)}) catch return "",
        .optional => {
            if (value) |v| {
                return writeXmlValueInline(buf, v);
            } else {
                writer.writeAll("null") catch return "";
            }
        },
        .@"struct" => {
            if (std.meta.hasMethod(ValueType, "trace")) {
                // For structs with trace methods, we can't inline them
                writer.writeAll("[complex]") catch return "";
            } else if (ValueType == StyleRow) {
                const allocator = std.heap.page_allocator;
                const tokens = @import("tailwind.zig").utilityTokensFromStyleRow(allocator, value) catch return "";
                writer.writeAll("<tokens>") catch return "";
                for (tokens) |token| {
                    writer.writeAll(token) catch return "";
                    writer.writeAll(" ") catch return "";
                }
                writer.writeAll("</tokens>") catch return "";
            } else {
                writer.print("{any}", .{value}) catch return "";
            }
        },
        else => writer.print("{any}", .{value}) catch return "",
    }

    return stream.getWritten();
}

fn writeXmlValue(self: *const Trace, value: anytype) void {
    const ValueType = @TypeOf(value);

    switch (@typeInfo(ValueType)) {
        .int => self.print("{d}", .{value}),
        .float => self.print("{d:.2}", .{value}),
        .bool => self.print("{}", .{value}),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                escapeXml(self, value);
            } else {
                self.print("{any}", .{value});
            }
        },
        .array => |arr_info| {
            if (arr_info.child == u8) {
                escapeXml(self, &value);
            } else {
                self.print("{any}", .{value});
            }
        },
        .@"enum" => self.print("{s}", .{@tagName(value)}),
        .optional => {
            if (value) |v| {
                writeXmlValue(self, v);
            } else {
                self.print("null", .{});
            }
        },
        .@"struct" => {
            if (std.meta.hasMethod(ValueType, "trace")) {
                value.trace(self);
            } else {
                self.print("{any}", .{value});
            }
        },
        else => self.print("{any}", .{value}),
    }
}

fn makeXmlAttributeName(buf: []u8, key: []const u8) []const u8 {
    // Convert space-separated field names to hyphenated for XML attributes
    var j: usize = 0;
    for (key) |c| {
        if (j >= buf.len) break;
        if (c == ' ') {
            buf[j] = '-';
        } else {
            buf[j] = c;
        }
        j += 1;
    }
    return buf[0..j];
}

pub fn print(self: *const Trace, comptime format: []const u8, args: anytype) void {
    if (!self.enabled) return;
    std.log.info(format, args);
}

pub fn info(self: *const Trace, comptime description: []const u8) void {
    if (!self.enabled) return;
    const indent = self.getIndent();
    std.log.info("{s}<info>{s}</info>", .{ indent, description });
}

pub fn decision(self: *const Trace, comptime description: []const u8) void {
    if (!self.enabled) return;
    const indent = self.getIndent();
    std.log.info("{s}<decision>{s}</decision>", .{ indent, description });
}

pub fn note(self: *const Trace, comptime description: []const u8) void {
    if (!self.enabled) return;
    const indent = self.getIndent();
    std.log.info("{s}<note>{s}</note>", .{ indent, description });
}

pub fn put(self: *const Trace, comptime key: []const u8, value: anytype) *const Trace {
    if (!self.enabled) return self;

    const indent = self.getIndent();
    const ValueType = @TypeOf(value);

    // Check if this is a complex struct that has its own trace method
    const hasTraceMethod = switch (@typeInfo(ValueType)) {
        .@"struct" => std.meta.hasMethod(ValueType, "trace"),
        else => false,
    };

    if (hasTraceMethod) {
        // Complex value - use nested trace output
        self.print("{s}<item key=\"{s}\">", .{ indent, key });
        writeXmlValue(self, value);
        self.print("</item>", .{});
    } else {
        // Simple value - inline without newlines
        var buf: [256]u8 = undefined;
        const inline_value = writeXmlValueInline(&buf, value);
        self.print("{s}<item key=\"{s}\">{s}</item>", .{ indent, key, inline_value });
    }

    return self;
}

pub const SpanBuilder = struct {
    trace: *const Trace,
    label: []const u8,

    pub fn put(self: *const SpanBuilder, comptime key: []const u8, value: anytype) *const SpanBuilder {
        if (!self.trace.enabled) return self;
        _ = self.trace.put(key, value);
        return self;
    }

    pub fn end(self: *const SpanBuilder) void {
        if (!self.trace.enabled) return;
        const indent = self.trace.getIndent();
        std.log.info("{s}</data>", .{indent});
    }
};

pub fn data(self: *const Trace, comptime label: []const u8) SpanBuilder {
    if (!self.enabled) return SpanBuilder{ .trace = self, .label = label };
    const indent = self.getIndent();
    std.log.info("{s}<data label=\"{s}\">", .{ indent, label });
    return SpanBuilder{ .trace = self, .label = label };
}

pub fn exit(self: *const Trace) void {
    if (!self.enabled) return;

    // Write closing tag with proper indentation
    const indent = if (self.depth > 0) blk: {
        const parent_trace = Trace{
            .enabled = self.enabled,
            .depth = self.depth - 1,
        };
        break :blk parent_trace.getIndent();
    } else self.getIndent();

    std.log.info("{s}</span>", .{indent});
}

pub fn enter(self: *const Trace) Trace {
    if (!self.enabled) return Trace{ .enabled = false, .depth = 0 };
    const child = Trace{
        .enabled = self.enabled,
        .depth = self.depth + 1,
    };

    if (self.enabled) {
        const indent = self.getIndent();
        // Write a simple span opening tag
        std.log.info("{s}<span>", .{indent});
    }

    return child;
}
