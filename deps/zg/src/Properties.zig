//! Properties module

core_s1: []u16 = undefined,
core_s2: []u8 = undefined,
props_s1: []u16 = undefined,
props_s2: []u8 = undefined,
num_s1: []u16 = undefined,
num_s2: []u8 = undefined,

const Properties = @This();

pub fn init(allocator: Allocator) Allocator.Error!Properties {
    var props = Properties{};
    try props.setup(allocator);
    return props;
}

pub fn setup(props: *Properties, allocator: Allocator) Allocator.Error!void {
    props.setupInner(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
}

inline fn setupInner(props: *Properties, allocator: Allocator) !void {
    const decompressor = compress.flate.inflate.decompressor;
    const endian = builtin.cpu.arch.endian();

    // Process DerivedCoreProperties.txt
    const core_bytes = @embedFile("core_props");
    var core_fbs = std.io.fixedBufferStream(core_bytes);
    var core_decomp = decompressor(.raw, core_fbs.reader());
    var core_reader = core_decomp.reader();

    const core_stage_1_len: u16 = try core_reader.readInt(u16, endian);
    props.core_s1 = try allocator.alloc(u16, core_stage_1_len);
    errdefer allocator.free(props.core_s1);
    for (0..core_stage_1_len) |i| props.core_s1[i] = try core_reader.readInt(u16, endian);

    const core_stage_2_len: u16 = try core_reader.readInt(u16, endian);
    props.core_s2 = try allocator.alloc(u8, core_stage_2_len);
    errdefer allocator.free(props.core_s2);
    _ = try core_reader.readAll(props.core_s2);

    // Process PropList.txt
    const props_bytes = @embedFile("props");
    var props_fbs = std.io.fixedBufferStream(props_bytes);
    var props_decomp = decompressor(.raw, props_fbs.reader());
    var props_reader = props_decomp.reader();

    const stage_1_len: u16 = try props_reader.readInt(u16, endian);
    props.props_s1 = try allocator.alloc(u16, stage_1_len);
    errdefer allocator.free(props.props_s1);
    for (0..stage_1_len) |i| props.props_s1[i] = try props_reader.readInt(u16, endian);

    const stage_2_len: u16 = try props_reader.readInt(u16, endian);
    props.props_s2 = try allocator.alloc(u8, stage_2_len);
    errdefer allocator.free(props.props_s2);
    _ = try props_reader.readAll(props.props_s2);

    // Process DerivedNumericType.txt
    const num_bytes = @embedFile("numeric");
    var num_fbs = std.io.fixedBufferStream(num_bytes);
    var num_decomp = decompressor(.raw, num_fbs.reader());
    var num_reader = num_decomp.reader();

    const num_stage_1_len: u16 = try num_reader.readInt(u16, endian);
    props.num_s1 = try allocator.alloc(u16, num_stage_1_len);
    errdefer allocator.free(props.num_s1);
    for (0..num_stage_1_len) |i| props.num_s1[i] = try num_reader.readInt(u16, endian);

    const num_stage_2_len: u16 = try num_reader.readInt(u16, endian);
    props.num_s2 = try allocator.alloc(u8, num_stage_2_len);
    errdefer allocator.free(props.num_s2);
    _ = try num_reader.readAll(props.num_s2);
}

pub fn deinit(self: *const Properties, allocator: Allocator) void {
    allocator.free(self.core_s1);
    allocator.free(self.core_s2);
    allocator.free(self.props_s1);
    allocator.free(self.props_s2);
    allocator.free(self.num_s1);
    allocator.free(self.num_s2);
}

/// True if `cp` is a mathematical symbol.
pub fn isMath(self: Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is an alphabetic character.
pub fn isAlphabetic(self: Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is a valid identifier start character.
pub fn isIdStart(self: Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

/// True if `cp` is a valid identifier continuation character.
pub fn isIdContinue(self: Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 8 == 8;
}

/// True if `cp` is a valid extended identifier start character.
pub fn isXidStart(self: Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 16 == 16;
}

/// True if `cp` is a valid extended identifier continuation character.
pub fn isXidContinue(self: Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 32 == 32;
}

/// True if `cp` is a whitespace character.
pub fn isWhitespace(self: Properties, cp: u21) bool {
    return self.props_s2[self.props_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is a hexadecimal digit.
pub fn isHexDigit(self: Properties, cp: u21) bool {
    return self.props_s2[self.props_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is a diacritic mark.
pub fn isDiacritic(self: Properties, cp: u21) bool {
    return self.props_s2[self.props_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

/// True if `cp` is numeric.
pub fn isNumeric(self: Properties, cp: u21) bool {
    return self.num_s2[self.num_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is a digit.
pub fn isDigit(self: Properties, cp: u21) bool {
    return self.num_s2[self.num_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is decimal.
pub fn isDecimal(self: Properties, cp: u21) bool {
    return self.num_s2[self.num_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

test "Props" {
    const self = try init(testing.allocator);
    defer self.deinit(testing.allocator);

    try testing.expect(self.isHexDigit('F'));
    try testing.expect(self.isHexDigit('a'));
    try testing.expect(self.isHexDigit('8'));
    try testing.expect(!self.isHexDigit('z'));

    try testing.expect(self.isDiacritic('\u{301}'));
    try testing.expect(self.isAlphabetic('A'));
    try testing.expect(!self.isAlphabetic('3'));
    try testing.expect(self.isMath('+'));

    try testing.expect(self.isNumeric('\u{277f}'));
    try testing.expect(self.isDigit('\u{2070}'));
    try testing.expect(self.isDecimal('3'));

    try testing.expect(!self.isNumeric('1'));
    try testing.expect(!self.isDigit('2'));
    try testing.expect(!self.isDecimal('g'));
}

fn testAllocator(allocator: Allocator) !void {
    var prop = try Properties.init(allocator);
    prop.deinit(allocator);
}

test "Allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testAllocator, .{});
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
