// Stub Words module for WASM build
// This provides the same interface as the real Words module but with minimal functionality

const std = @import("std");

pub const WordIterator = struct {
    text: []const u8,
    codepoint_iter: std.unicode.Utf8Iterator,

    pub fn init(text: []const u8) WordIterator {
        return WordIterator{
            .text = text,
            .codepoint_iter = std.unicode.Utf8View.initUnchecked(text).iterator(),
        };
    }

    pub fn next(self: *WordIterator) ?WordSegment {
        // We should yield all parts of the text, including whitespace.
        // Each run of whitespace should be yielded as a single segment.

        const start = self.codepoint_iter.i;
        while (true) {
            const codepoint = self.codepoint_iter.peek(1);
            if (codepoint.len == 0) {
                break;
            } else if (codepoint[0] == ' ') {
                break;
            } else if (codepoint[0] == '\n') {
                break;
            }

            _ = self.codepoint_iter.nextCodepoint();
        }

        return WordSegment{
            .offset = start,
            .len = self.codepoint_iter.i - start,
        };
    }
};

pub const WordSegment = struct {
    offset: usize = 0,
    len: usize = 0,

    pub fn bytes(self: WordSegment, line: []const u8) []const u8 {
        return line[self.offset .. self.offset + self.len];
    }
};

// Module acts as the Words type itself
pub fn init(allocator: std.mem.Allocator) !@This() {
    _ = allocator;
    return @This(){};
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
}

pub fn iterator(self: *const @This(), text: []const u8) WordIterator {
    _ = self;
    return WordIterator.init(text);
}
