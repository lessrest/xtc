const std = @import("std");
const UnicodeData = @import("./unicode.zig");

pub const WrappedLine = struct {
    bytes: []const u8,
    width_cols: usize,
};

pub const WrappedLineIterator = struct {
    unicode: *const UnicodeData,
    text: []const u8,
    max_width_cols: usize,
    next_text_offset: usize = 0,
    current_line: []const u8 = "",
    current_line_offset: usize = 0,
    have_current_line: bool = false,

    pub fn init(unicode: *const UnicodeData, text: []const u8, max_width_cols: usize) WrappedLineIterator {
        return .{
            .unicode = unicode,
            .text = text,
            .max_width_cols = max_width_cols,
        };
    }

    pub fn next(self: *WrappedLineIterator) ?WrappedLine {
        while (true) {
            if (!self.have_current_line) {
                if (!self.loadNextSourceLine()) return null;
            }

            if (self.current_line.len == 0) {
                self.have_current_line = false;
                return .{ .bytes = "", .width_cols = 0 };
            }

            if (self.current_line_offset >= self.current_line.len) {
                self.have_current_line = false;
                continue;
            }

            return self.nextWrappedSegment();
        }
    }

    fn loadNextSourceLine(self: *WrappedLineIterator) bool {
        if (self.next_text_offset > self.text.len) return false;

        const line_start = self.next_text_offset;
        if (std.mem.indexOfScalarPos(u8, self.text, line_start, '\n')) |newline_at| {
            self.current_line = self.text[line_start..newline_at];
            self.next_text_offset = newline_at + 1;
        } else {
            self.current_line = self.text[line_start..];
            self.next_text_offset = self.text.len + 1;
        }

        self.current_line_offset = 0;
        self.have_current_line = true;
        return true;
    }

    fn nextWrappedSegment(self: *WrappedLineIterator) WrappedLine {
        if (self.max_width_cols == 0) {
            const line = self.current_line[self.current_line_offset..];
            self.current_line_offset = self.current_line.len;
            return .{ .bytes = line, .width_cols = self.unicode.monospacedTextWidth(line) };
        }

        const remaining = self.current_line[self.current_line_offset..];
        var word_iter = self.unicode.wordIterator(remaining);
        var line_width: usize = 0;
        var last_break_offset: ?usize = null;

        while (word_iter.next()) |seg| {
            const bytes = seg.bytes(remaining);
            const seg_w = self.unicode.monospacedTextWidth(bytes);

            if (line_width + seg_w > self.max_width_cols and line_width > 0) {
                const end = self.current_line_offset + (last_break_offset orelse seg.offset);
                const line = self.current_line[self.current_line_offset..end];
                self.current_line_offset += seg.offset;
                return .{ .bytes = line, .width_cols = self.unicode.monospacedTextWidth(line) };
            }

            line_width += seg_w;
            last_break_offset = seg.offset + seg.len;
        }

        const line = self.current_line[self.current_line_offset..];
        self.current_line_offset = self.current_line.len;
        const width = @min(line_width, self.unicode.monospacedTextWidth(line));
        return .{ .bytes = line, .width_cols = width };
    }
};

pub fn countWrappedLines(unicode: *const UnicodeData, text: []const u8, max_width_cols: usize) usize {
    var iter = WrappedLineIterator.init(unicode, text, max_width_cols);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    return count;
}
