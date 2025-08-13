const std = @import("std");

pub const Options = struct {
    enabled: bool = false,
    max_depth: ?usize = null,
};

pub fn GenericTracer(comptime WriterType: type) type {
    return struct {
        const Self = GenericTracer(WriterType);

        writer: WriterType,
        max_depth: usize,
        depth: usize,

        pub fn init(writer: WriterType, options: Options) Self {
            const max_depth = if (!options.enabled)
                0
            else if (options.max_depth) |limit|
                limit
            else
                std.math.maxInt(usize);

            return .{
                .writer = writer,
                .max_depth = max_depth,
                .depth = 0,
            };
        }

        pub fn silent(self: Self) Self {
            return Self.init(self.writer, .{ .enabled = false });
        }

        pub fn unlimited(self: Self) Self {
            return Self.init(self.writer, .{
                .enabled = true,
                .max_depth = std.math.maxInt(usize),
            });
        }

        pub fn limited(self: Self, max_depth: usize) Self {
            return Self.init(self.writer, .{
                .enabled = true,
                .max_depth = max_depth,
            });
        }

        pub fn disabled(self: Self) bool {
            return self.max_depth == 0 or self.depth >= self.max_depth;
        }

        fn getIndent(self: Self) []const u8 {
            const spaces = "                                                                                ";
            const n = if (self.depth * 2 > spaces.len) spaces.len else self.depth * 2;
            return spaces[0..n];
        }

        fn escapeXml(writer: WriterType, str: []const u8) void {
            for (str) |c| {
                switch (c) {
                    '<' => writer.writeAll("&lt;") catch {},
                    '>' => writer.writeAll("&gt;") catch {},
                    '&' => writer.writeAll("&amp;") catch {},
                    '"' => writer.writeAll("&quot;") catch {},
                    '\'' => writer.writeAll("&apos;") catch {},
                    else => writer.writeByte(c) catch {},
                }
            }
        }

        pub fn print(self: Self, comptime format: []const u8, args: anytype) void {
            if (self.disabled()) return;
            self.writer.print(format, args) catch {};
            self.writer.writeByte('\n') catch {};
        }

        pub fn info(self: Self, comptime description: []const u8) void {
            if (self.disabled()) return;
            const indent = self.getIndent();
            self.print("{s}<info>{s}</info>", .{ indent, description });
        }

        pub fn decision(self: Self, comptime description: []const u8) void {
            if (self.disabled()) return;
            const indent = self.getIndent();
            self.print("{s}<decision>{s}</decision>", .{ indent, description });
        }

        pub fn note(self: Self, comptime description: []const u8) void {
            if (self.disabled()) return;
            const indent = self.getIndent();
            self.print("{s}<note>{s}</note>", .{ indent, description });
        }

        fn writeXmlValueInline(buf: []u8, value: anytype) []const u8 {
            const ValueType = @TypeOf(value);

            var stream = std.io.fixedBufferStream(buf);
            const w = stream.writer();

            switch (@typeInfo(ValueType)) {
                .int => w.print("{d}", .{value}) catch return "",
                .float => w.print("{d:.2}", .{value}) catch return "",
                .bool => w.print("{}", .{value}) catch return "",
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        w.writeAll("\"") catch return "";
                        for (value) |c| {
                            switch (c) {
                                '<' => w.writeAll("&lt;") catch return "",
                                '>' => w.writeAll("&gt;") catch return "",
                                '&' => w.writeAll("&amp;") catch return "",
                                '"' => w.writeAll("&quot;") catch return "",
                                '\'' => w.writeAll("&apos;") catch return "",
                                else => w.writeByte(c) catch return "",
                            }
                        }
                        w.writeAll("\"") catch return "";
                    } else {
                        w.print("{any}", .{value}) catch return "";
                    }
                },
                .array => |arr_info| {
                    if (arr_info.child == u8) {
                        for (value) |c| {
                            switch (c) {
                                '<' => w.writeAll("&lt;") catch return "",
                                '>' => w.writeAll("&gt;") catch return "",
                                '&' => w.writeAll("&amp;") catch return "",
                                '"' => w.writeAll("&quot;") catch return "",
                                '\'' => w.writeAll("&apos;") catch return "",
                                else => w.writeByte(c) catch return "",
                            }
                        }
                    } else {
                        w.print("{any}", .{value}) catch return "";
                    }
                },
                .@"enum" => w.print("{s}", .{@tagName(value)}) catch return "",
                .optional => {
                    if (value) |v| {
                        return writeXmlValueInline(buf, v);
                    } else {
                        w.writeAll("null") catch return "";
                    }
                },
                .@"struct" => {
                    if (std.meta.hasMethod(ValueType, "trace")) {
                        // For structs with trace methods, we can't inline them
                        w.writeAll("[complex]") catch return "";
                    } else if (@hasDecl(@import("tailwind.zig"), "utilityTokensFromStyleRow") and ValueType == @import("style.zig").StyleRow) {
                        const allocator = std.heap.page_allocator;
                        const tokens = @import("tailwind.zig").utilityTokensFromStyleRow(allocator, value) catch return "";
                        w.writeAll("<tokens>") catch return "";
                        for (tokens) |token| {
                            w.writeAll(token) catch return "";
                            w.writeAll(" ") catch return "";
                        }
                        w.writeAll("</tokens>") catch return "";
                    } else {
                        w.print("{any}", .{value}) catch return "";
                    }
                },
                else => w.print("{any}", .{value}) catch return "",
            }

            return stream.getWritten();
        }

        fn writeXmlValue(self: *Self, value: anytype) void {
            const ValueType = @TypeOf(value);

            switch (@typeInfo(ValueType)) {
                .int => self.print("{d}", .{value}),
                .float => self.print("{d:.2}", .{value}),
                .bool => self.print("{}", .{value}),
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        escapeXml(self.writer, value);
                        self.writer.writeByte('\n') catch {};
                    } else {
                        self.print("{any}", .{value});
                    }
                },
                .array => |arr_info| {
                    if (arr_info.child == u8) {
                        escapeXml(self.writer, &value);
                        self.writer.writeByte('\n') catch {};
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

        pub fn put(self: *Self, comptime key: []const u8, value: anytype) *Self {
            if (self.disabled()) return self;

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

        pub const DataScope = struct {
            trace: *Self,
            started: bool,

            pub fn put(self: *const DataScope, comptime key: []const u8, value: anytype) *const DataScope {
                if (self.started) {
                    _ = self.trace.put(key, value);
                }
                return self;
            }

            pub fn end(self: *const DataScope) void {
                if (!self.started) return;
                self.trace.depth -= 1;
                if (!self.trace.disabled()) {
                    const indent = self.trace.getIndent();
                    self.trace.print("{s}</data>", .{indent});
                }
            }
        };

        pub fn data(self: *Self, comptime label: []const u8) DataScope {
            if (self.disabled()) {
                return DataScope{ .trace = self, .started = false };
            }

            const would_be_disabled = (self.depth + 1) >= self.max_depth;
            if (would_be_disabled) {
                return DataScope{ .trace = self, .started = false };
            }

            const indent = self.getIndent();
            self.print("{s}<data label=\"{s}\">", .{ indent, label });
            self.depth += 1;

            return DataScope{
                .trace = self,
                .started = true,
            };
        }

        pub fn enter(self: *Self) void {
            if (self.disabled()) return;

            // Check if the child would be disabled before printing
            const would_be_disabled = (self.depth + 1) >= self.max_depth;

            if (!would_be_disabled) {
                const indent = self.getIndent();
                self.print("{s}<span>", .{indent});
            }

            self.depth += 1;
        }

        pub fn exit(self: *Self) void {
            if (self.depth == 0) return;

            self.depth -= 1;

            if (self.disabled()) return;

            const indent = self.getIndent();
            self.print("{s}</span>", .{indent});
        }
    };
}

// The default Trace type that everyone uses
pub const Trace = GenericTracer(std.fs.File.Writer);

pub fn file(f: std.fs.File, options: Options) Trace {
    return GenericTracer(std.fs.File.Writer).init(f.writer(), options);
}

// ============ Tests ============

test "trace messages are written to the output stream in XML format" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const TestTrace = GenericTracer(@TypeOf(stream.writer()));

    var trace = TestTrace.init(stream.writer(), .{ .enabled = true });
    trace.info("test message");

    const output = stream.getWritten();
    try std.testing.expectEqualStrings("<info>test message</info>\n", output);
}

test "trace output respects maximum depth setting and omits deeper messages" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const TestTrace = GenericTracer(@TypeOf(stream.writer()));

    var trace = TestTrace.init(stream.writer(), .{ .enabled = true, .max_depth = 2 });
    trace.enter();
    trace.info("depth 1");
    trace.enter();
    trace.info("should not appear");
    trace.exit();
    trace.exit();

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "depth 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "should not appear") == null);
}

test "trace data builder creates structured key-value groups in the output" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const TestTrace = GenericTracer(@TypeOf(stream.writer()));

    var trace = TestTrace.init(stream.writer(), .{ .enabled = true });
    const scope = trace.data("test-data");
    _ = scope.put("key1", @as(i32, 42))
        .put("key2", "value");
    scope.end();

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "<data label=\"test-data\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "key1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</data>") != null);
}
