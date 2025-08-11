//! XML trace log formatter for XTC debug output.
//! Converts structured XML trace logs into human-readable hierarchical format with ANSI colors.

const std = @import("std");
const xmlparse = @import("xmlparse.zig");
const ansi = @import("ansi.zig");
const tree_mod = @import("TreePrinter.zig");

const Formatter = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    ansi: ansi.ArrayListAnsiWriter,
    tree: tree_mod.TreePrinter,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
            .ansi = undefined, // Will be set after initialization
            .tree = tree_mod.TreePrinter.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.output.deinit();
        self.tree.deinit();
    }

    fn writeTreePrefix(self: *Self, is_last: bool) !void {
        try self.tree.writePrefix(is_last);
    }

    fn writeTreeVerticals(self: *Self) !void {
        try self.tree.writeVerticals();
    }

    fn tagIs(element: xmlparse.Element, tag: []const u8) bool {
        return std.mem.eql(u8, Self.getElementTag(element), tag);
    }

    fn getElementTag(element: xmlparse.Element) []const u8 {
        return element.tag_name.slice();
    }

    fn getElementAttr(element: xmlparse.Element, key: []const u8) ?[]const u8 {
        return element.attr(key);
    }

    fn getElementTextContent(element: xmlparse.Element) ?[]const u8 {
        const children = element.children();
        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .text => |text_idx| {
                    return text_idx.slice();
                },
                else => {},
            }
        }
        return null;
    }

    fn getTokensFromElement(element: xmlparse.Element) ?[]const u8 {
        const children = element.children();
        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .element => |child_element| {
                    if (Self.tagIs(child_element, "tokens")) {
                        return Self.getElementTextContent(child_element);
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn formatSpan(self: *Self, element: xmlparse.Element, is_last: bool) anyerror!void {
        // First pass: find info text
        var info_text: ?[]const u8 = null;
        const children = element.children();
        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .element => |child_element| {
                    if (Self.tagIs(child_element, "info")) {
                        info_text = Self.getElementTextContent(child_element);
                        break;
                    }
                },
                else => {},
            }
        }

        // Write span header
        try self.writeTreePrefix(is_last);
        try self.ansi.setBold();
        try self.ansi.setForegroundRgb(100, 149, 237); // Cornflower blue
        if (info_text) |text| {
            try self.ansi.writeAll(std.mem.trim(u8, text, " \t\n\r"));
        }
        try self.ansi.resetStyle();
        try self.ansi.writeAll("\n");

        // Count non-info children
        var non_info_children = std.ArrayList(xmlparse.Element).init(self.allocator);
        defer non_info_children.deinit();

        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .element => |child_element| {
                    if (!Self.tagIs(child_element, "info")) {
                        try non_info_children.append(child_element);
                    }
                },
                else => {},
            }
        }

        if (non_info_children.items.len == 0) return;

        try self.tree.enter();
        defer self.tree.exit();

        // Process each child in order
        for (non_info_children.items, 0..) |child_element, i| {
            const child_is_last = (i == non_info_children.items.len - 1);
            self.tree.setHasMore(!child_is_last);

            const tag = Self.getElementTag(child_element);
            if (std.mem.eql(u8, tag, "decision")) {
                try self.writeTreePrefix(child_is_last);
                try self.ansi.setForegroundRgb(255, 215, 0); // Gold
                if (Self.getElementTextContent(child_element)) |text| {
                    try self.ansi.writeAll(std.mem.trim(u8, text, " \t\n\r"));
                }
                try self.ansi.resetStyle();
                try self.ansi.writeAll("\n");
            } else if (std.mem.eql(u8, tag, "data")) {
                try self.formatDataGroup(child_element, child_is_last);
            } else if (std.mem.eql(u8, tag, "item")) {
                try self.formatStandaloneItem(child_element, child_is_last);
            } else if (std.mem.eql(u8, tag, "span")) {
                try self.formatSpan(child_element, child_is_last);
            }
        }
    }

    fn formatDataGroup(self: *Self, element: xmlparse.Element, is_last: bool) anyerror!void {
        const label = Self.getElementAttr(element, "label") orelse "data";
        const children = element.children();

        var items = std.ArrayList(xmlparse.Element).init(self.allocator);
        defer items.deinit();

        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .element => |child_element| {
                    if (Self.tagIs(child_element, "item")) {
                        try items.append(child_element);
                    }
                },
                else => {},
            }
        }

        try self.writeTreePrefix(is_last);
        try self.ansi.writeColoredText(label, 50, 205, 50); // Lime green

        var all_simple = true;
        for (items.items) |item| {
            if (!self.isSimpleItem(item)) {
                all_simple = false;
                break;
            }
        }

        if (all_simple) {
            try self.formatSimpleItemsWrapped(items.items, label.len);
        } else {
            try self.ansi.writeAll("\n");
            try self.tree.enter();
            defer self.tree.exit();

            for (items.items, 0..) |item, i| {
                const item_is_last = (i == items.items.len - 1);
                self.tree.setHasMore(!item_is_last);
                try self.formatDataGroupItem(item, item_is_last);
            }
        }
    }

    fn formatDataGroupItem(self: *Self, item: xmlparse.Element, is_last: bool) anyerror!void {
        const key = Self.getElementAttr(item, "key") orelse "item";

        if (self.isSimpleItem(item)) {
            try self.writeTreePrefix(is_last);
            try self.formatKeyValuePair(key, item);
        } else {
            // Complex item with nested elements
            try self.writeTreePrefix(is_last);
            try self.ansi.setForegroundRgb(0, 206, 209); // Dark turquoise
            try self.ansi.resetStyle();
            try self.ansi.setForegroundRgb(150, 150, 150); // Gray for field names
            try self.ansi.writeAll(key);
            try self.ansi.resetStyle();
            try self.ansi.writeAll("\n");

            try self.tree.enter();
            defer self.tree.exit();

            const children = item.children();
            for (children, 0..) |child_idx, i| {
                const node = child_idx.v();
                switch (node) {
                    .element => |child_element| {
                        const child_is_last = (i == children.len - 1);
                        self.tree.setHasMore(!child_is_last);

                        const tag = Self.getElementTag(child_element);
                        if (std.mem.eql(u8, tag, "data")) {
                            try self.formatDataGroup(child_element, child_is_last);
                        } else if (std.mem.eql(u8, tag, "span")) {
                            try self.formatSpan(child_element, child_is_last);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn formatSimpleItemsWrapped(self: *Self, items: []xmlparse.Element, label_length: usize) anyerror!void {
        const max_line_length = 70; // Target line length before wrapping
        var current_line_length: usize = 0;

        try self.ansi.writeAll("(");
        current_line_length += 1;

        for (items, 0..) |item, i| {
            const key = Self.getElementAttr(item, "key") orelse "item";
            const value_text = if (Self.getElementTextContent(item)) |text|
                std.mem.trim(u8, text, " \t\n\r")
            else
                "";

            // Calculate length of this item: "key value" (no colon)
            const item_length = key.len + 1 + value_text.len;
            const separator_length: usize = if (i > 0) 1 else 0;

            // Check if we need to wrap
            if (i > 0 and current_line_length + separator_length + item_length > max_line_length) {
                try self.ansi.writeAll("\n");
                try self.writeTreeVerticals();
                // Align to opening parenthesis: label_length + 1 for the "("
                for (0..label_length + 1) |_| {
                    try self.ansi.writeAll(" ");
                }
                // Calculate the width of tree verticals for proper line length tracking
                const tree_width = self.tree.indentColumns();
                current_line_length = tree_width + label_length + 1; // Reset for new line with alignment
            } else if (i > 0) {
                try self.ansi.writeAll(" ");
                current_line_length += separator_length;
            }

            // Write the item with color coding
            try self.ansi.setForegroundRgb(150, 150, 150); // Gray for field names
            try self.ansi.writeAll(key);
            try self.ansi.resetStyle();
            try self.ansi.writeAll(" "); // Space instead of colon
            try self.ansi.writeAll(value_text); // Default color for values
            current_line_length += item_length;
        }

        try self.ansi.writeAll(")\n");
    }

    fn isSimpleDataGroup(self: *Self, data_group: xmlparse.Element) bool {
        _ = self;
        const children = data_group.children();
        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .element => |child_element| {
                    // Check if this item has only text content (no nested elements)
                    const item_children = child_element.children();
                    for (item_children) |item_child_idx| {
                        const item_node = item_child_idx.v();
                        switch (item_node) {
                            .element => return false, // Has nested elements, not simple
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return true;
    }

    fn formatDataGroupInline(self: *Self, data_group: xmlparse.Element) !void {
        const label = Self.getElementAttr(data_group, "label") orelse "data";
        const children = data_group.children();

        var items = std.ArrayList(xmlparse.Element).init(self.allocator);
        defer items.deinit();

        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .element => |child_element| {
                    if (Self.tagIs(child_element, "item")) {
                        try items.append(child_element);
                    }
                },
                else => {},
            }
        }

        try self.ansi.setForegroundRgb(50, 205, 50); // Lime green
        try self.ansi.writeAll(label);
        try self.ansi.resetStyle();
        try self.ansi.writeAll("(");
        for (items.items, 0..) |item, i| {
            if (i > 0) try self.ansi.writeAll(", ");

            const key = Self.getElementAttr(item, "key") orelse "item";
            const value_text = if (Self.getElementTextContent(item)) |text|
                std.mem.trim(u8, text, " \t\n\r")
            else
                "";

            // Write with color coding
            try self.ansi.setForegroundRgb(150, 150, 150); // Gray for field names
            try self.ansi.writeAll(key);
            try self.ansi.resetStyle();
            try self.ansi.writeAll(" "); // Space instead of colon
            try self.ansi.writeAll(value_text); // Default color for values
        }
        try self.ansi.writeAll(")");
    }

    fn isSimpleItem(self: *Self, item: xmlparse.Element) bool {
        _ = self;
        const children = item.children();
        for (children) |child_idx| {
            const node = child_idx.v();
            switch (node) {
                .element => return false,
                else => {},
            }
        }
        return true;
    }

    fn formatItemInline(self: *Self, item: xmlparse.Element) anyerror!void {
        const key = Self.getElementAttr(item, "key") orelse "item";
        try self.ansi.writeColoredText(key, 150, 150, 150); // Gray for field names
        try self.ansi.writeAll(" "); // Space instead of colon

        // Check for tokens format
        if (Self.getTokensFromElement(item)) |tokens_text| {
            try self.ansi.writeAll(std.mem.trim(u8, tokens_text, " \t\n\r"));
        } else if (Self.getElementTextContent(item)) |text| {
            try self.ansi.writeAll(std.mem.trim(u8, text, " \t\n\r"));
        }
    }

    fn formatKeyValuePair(self: *Self, key: []const u8, item: xmlparse.Element) !void {
        try self.ansi.writeColoredText(key, 150, 150, 150); // Gray for field names
        try self.ansi.writeAll(" ");

        // Check for tokens format
        if (Self.getTokensFromElement(item)) |tokens_text| {
            try self.ansi.writeAll(std.mem.trim(u8, tokens_text, " \t\n\r"));
        } else if (Self.getElementTextContent(item)) |text| {
            try self.ansi.writeAll(std.mem.trim(u8, text, " \t\n\r"));
        }
        try self.ansi.writeAll("\n");
    }

    fn formatStandaloneItem(self: *Self, item: xmlparse.Element, is_last: bool) anyerror!void {
        const key = Self.getElementAttr(item, "key") orelse "item";

        if (self.isSimpleItem(item)) {
            try self.writeTreePrefix(is_last);
            try self.formatKeyValuePair(key, item);
        } else {
            // Check if this item contains only a single simple data group
            const children = item.children();
            var single_data_group: ?xmlparse.Element = null;
            var has_other_children = false;

            for (children) |child_idx| {
                const node = child_idx.v();
                switch (node) {
                    .element => |child_element| {
                        const tag = Self.getElementTag(child_element);
                        if (std.mem.eql(u8, tag, "data")) {
                            if (single_data_group == null) {
                                single_data_group = child_element;
                            } else {
                                has_other_children = true; // Multiple data groups
                            }
                        } else {
                            has_other_children = true; // Spans or other elements
                        }
                    },
                    else => {},
                }
            }

            // If it's a single simple data group, format inline
            if (single_data_group != null and !has_other_children and self.isSimpleDataGroup(single_data_group.?)) {
                try self.writeTreePrefix(is_last);
                try self.ansi.setForegroundRgb(0, 206, 209); // Dark turquoise
                try self.ansi.resetStyle();
                try self.ansi.setForegroundRgb(150, 150, 150); // Gray for field names
                try self.ansi.writeAll(key);
                try self.ansi.resetStyle();
                try self.ansi.writeAll(" ");
                try self.formatDataGroupInline(single_data_group.?);
                try self.ansi.writeAll("\n");
            } else {
                // Format with proper tree structure for complex items
                try self.writeTreePrefix(is_last);
                try self.ansi.setForegroundRgb(0, 206, 209); // Dark turquoise
                try self.ansi.resetStyle();
                try self.ansi.setForegroundRgb(150, 150, 150); // Gray for field names
                try self.ansi.writeAll(key);
                try self.ansi.resetStyle();
                try self.ansi.writeAll("\n");

                try self.tree.enter();
                defer self.tree.exit();

                for (children, 0..) |child_idx, i| {
                    const node = child_idx.v();
                    switch (node) {
                        .element => |child_element| {
                            const child_is_last = (i == children.len - 1);
                            self.tree.setHasMore(!child_is_last);

                            const tag = Self.getElementTag(child_element);
                            if (std.mem.eql(u8, tag, "data")) {
                                try self.formatDataGroup(child_element, child_is_last);
                            } else if (std.mem.eql(u8, tag, "span")) {
                                try self.formatSpan(child_element, child_is_last);
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }
};

pub fn formatLogXmlNoColor(allocator: std.mem.Allocator, log_bytes: []const u8) ![]u8 {
    // Find first XML-like tag boundary; accept either our span or an XML prolog
    const start = std.mem.indexOf(u8, log_bytes, "<span>") orelse blk: {
        if (std.mem.indexOf(u8, log_bytes, "<?xml")) |i| break :blk i;
        return error.InvalidFormat;
    };
    const xml_slice = log_bytes[start..];

    var xml_stream = std.io.fixedBufferStream(xml_slice);
    var doc = xmlparse.parse(allocator, "log.xml", xml_stream.reader()) catch |err| {
        return err;
    };
    defer doc.deinit();

    doc.acquire();
    defer doc.release();

    var fmt = Formatter.init(allocator);
    defer fmt.deinit();

    // Use no-color ANSI writer
    fmt.ansi = ansi.arrayListWriterNoColor(&fmt.output);
    fmt.tree.setWriter(fmt.ansi);

    try fmt.formatSpan(doc.root, true);

    // Return an owned copy of the buffer
    return allocator.dupe(u8, fmt.output.items);
}

pub fn formatLogXml(allocator: std.mem.Allocator, log_bytes: []const u8) ![]u8 {
    // Find first XML-like tag boundary; accept either our span or an XML prolog
    const start = std.mem.indexOf(u8, log_bytes, "<span>") orelse blk: {
        if (std.mem.indexOf(u8, log_bytes, "<?xml")) |i| break :blk i;
        return error.InvalidFormat;
    };
    const xml_slice = log_bytes[start..];

    var xml_stream = std.io.fixedBufferStream(xml_slice);
    var doc = xmlparse.parse(allocator, "log.xml", xml_stream.reader()) catch |err| {
        return err;
    };
    defer doc.deinit();

    doc.acquire();
    defer doc.release();

    var fmt = Formatter.init(allocator);
    defer fmt.deinit();

    // Fix the ansi writer after the struct is in its final location
    fmt.ansi = ansi.arrayListWriter(&fmt.output);
    fmt.tree.setWriter(fmt.ansi);

    try fmt.formatSpan(doc.root, true);

    // Return an owned copy of the buffer
    return allocator.dupe(u8, fmt.output.items);
}

test "format simple data group inline" {
    const log =
        \\<span>
        \\<info>Render</info>
        \\<data label="params">
        \\<item key="width">80</item>
        \\<item key="height">24</item>
        \\</data>
        \\</span>
    ;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const out = try formatLogXmlNoColor(al, log);
    defer al.free(out);

    const expected =
        \\Render
        \\└─ params(width 80 height 24)
        \\
    ;

    try std.testing.expectEqualStrings(expected, out);
}

test "format with decision and nested span" {
    const log =
        \\<span>
        \\  <info>Parent</info>
        \\  <decision>chose X</decision>
        \\  <data label="g">
        \\    <item key="a">x</item>
        \\    <item key="nested">
        \\      <span>
        \\        <info>Child</info>
        \\        <data label="c">
        \\          <item key="k">v</item>
        \\        </data>
        \\      </span>
        \\    </item>
        \\  </data>
        \\</span>
    ;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const out = try formatLogXmlNoColor(al, log);
    defer al.free(out);

    const expected =
        \\Parent
        \\├─ chose X
        \\└─ g
        \\   ├─ a x
        \\   └─ nested
        \\      └─ Child
        \\         └─ c(k v)
        \\
    ;

    try std.testing.expectEqualStrings(expected, out);
}
