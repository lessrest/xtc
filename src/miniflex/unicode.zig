const std = @import("std");
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");
const Words = @import("Words");

graphemes: *Graphemes,
display_width: *DisplayWidth,
words: *Words,

pub fn init(allocator: std.mem.Allocator) !@This() {
    const this = @This(){
        .graphemes = try allocator.create(Graphemes),
        .display_width = try allocator.create(DisplayWidth),
        .words = try allocator.create(Words),
    };

    try Graphemes.setup(this.graphemes, allocator);
    try DisplayWidth.setupWithGraphemes(this.display_width, allocator, this.graphemes.*);
    try Words.setup(this.words, allocator);

    return this;
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.graphemes.deinit(allocator);
    self.display_width.deinit(allocator);
    self.words.deinit(allocator);
    allocator.destroy(self.graphemes);
    allocator.destroy(self.display_width);
    allocator.destroy(self.words);
    self.* = undefined;
}

pub fn monospacedTextWidth(self: *const @This(), text: []const u8) usize {
    return self.display_width.strWidth(text);
}

pub fn graphemeClusterIterator(self: *const @This(), text: []const u8) Graphemes.Iterator {
    return self.graphemes.iterator(text);
}

pub fn wordIterator(self: *const @This(), text: []const u8) Words.Iterator {
    return self.words.iterator(text);
}
