// Stub Words module for WASM build
// This provides the same interface as the real Words module but with minimal functionality

const std = @import("std");

pub const WordIterator = struct {
    text: []const u8,
    pos: usize = 0,
    
    pub fn next(self: *WordIterator) ?WordSegment {
        if (self.pos >= self.text.len) return null;
        
        // Simple word breaking - just split on spaces for WASM
        while (self.pos < self.text.len and self.text[self.pos] == ' ') {
            self.pos += 1;
        }
        
        if (self.pos >= self.text.len) return null;
        
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != ' ') {
            self.pos += 1;
        }
        
        return WordSegment{ 
            .data = self.text[start..self.pos],
            .offset = start,
            .len = self.pos - start,
        };
    }
};

pub const WordSegment = struct {
    data: []const u8,
    offset: usize = 0,
    len: usize = 0,
    
    pub fn bytes(self: WordSegment, line: []const u8) []const u8 {
        _ = line;
        return self.data;
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
    return WordIterator{ .text = text };
}