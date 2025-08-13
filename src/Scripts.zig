//! Scripts Module

s1: []u16 = undefined,
s2: []u8 = undefined,
s3: []u8 = undefined,

/// Scripts enum
pub const Script = enum {
    none,
    Adlam,
    Ahom,
    Anatolian_Hieroglyphs,
    Arabic,
    Armenian,
    Avestan,
    Balinese,
    Bamum,
    Bassa_Vah,
    Batak,
    Bengali,
    Bhaiksuki,
    Bopomofo,
    Brahmi,
    Braille,
    Buginese,
    Buhid,
    Canadian_Aboriginal,
    Carian,
    Caucasian_Albanian,
    Chakma,
    Cham,
    Cherokee,
    Chorasmian,
    Common,
    Coptic,
    Cuneiform,
    Cypriot,
    Cypro_Minoan,
    Cyrillic,
    Deseret,
    Devanagari,
    Dives_Akuru,
    Dogra,
    Duployan,
    Egyptian_Hieroglyphs,
    Elbasan,
    Elymaic,
    Ethiopic,
    Garay,
    Georgian,
    Glagolitic,
    Gothic,
    Grantha,
    Greek,
    Gujarati,
    Gunjala_Gondi,
    Gurmukhi,
    Gurung_Khema,
    Han,
    Hangul,
    Hanifi_Rohingya,
    Hanunoo,
    Hatran,
    Hebrew,
    Hiragana,
    Imperial_Aramaic,
    Inherited,
    Inscriptional_Pahlavi,
    Inscriptional_Parthian,
    Javanese,
    Kaithi,
    Kannada,
    Katakana,
    Kawi,
    Kayah_Li,
    Kharoshthi,
    Khitan_Small_Script,
    Khmer,
    Khojki,
    Khudawadi,
    Kirat_Rai,
    Lao,
    Latin,
    Lepcha,
    Limbu,
    Linear_A,
    Linear_B,
    Lisu,
    Lycian,
    Lydian,
    Mahajani,
    Makasar,
    Malayalam,
    Mandaic,
    Manichaean,
    Marchen,
    Masaram_Gondi,
    Medefaidrin,
    Meetei_Mayek,
    Mende_Kikakui,
    Meroitic_Cursive,
    Meroitic_Hieroglyphs,
    Miao,
    Modi,
    Mongolian,
    Mro,
    Multani,
    Myanmar,
    Nabataean,
    Nag_Mundari,
    Nandinagari,
    New_Tai_Lue,
    Newa,
    Nko,
    Nushu,
    Nyiakeng_Puachue_Hmong,
    Ogham,
    Ol_Chiki,
    Ol_Onal,
    Old_Hungarian,
    Old_Italic,
    Old_North_Arabian,
    Old_Permic,
    Old_Persian,
    Old_Sogdian,
    Old_South_Arabian,
    Old_Turkic,
    Old_Uyghur,
    Oriya,
    Osage,
    Osmanya,
    Pahawh_Hmong,
    Palmyrene,
    Pau_Cin_Hau,
    Phags_Pa,
    Phoenician,
    Psalter_Pahlavi,
    Rejang,
    Runic,
    Samaritan,
    Saurashtra,
    Sharada,
    Shavian,
    Siddham,
    SignWriting,
    Sinhala,
    Sogdian,
    Sora_Sompeng,
    Soyombo,
    Sundanese,
    Sunuwar,
    Syloti_Nagri,
    Syriac,
    Tagalog,
    Tagbanwa,
    Tai_Le,
    Tai_Tham,
    Tai_Viet,
    Takri,
    Tamil,
    Tangsa,
    Tangut,
    Telugu,
    Thaana,
    Thai,
    Tibetan,
    Tifinagh,
    Tirhuta,
    Todhri,
    Toto,
    Tulu_Tigalari,
    Ugaritic,
    Vai,
    Vithkuqi,
    Wancho,
    Warang_Citi,
    Yezidi,
    Yi,
    Zanabazar_Square,
};
const Scripts = @This();

pub fn init(allocator: Allocator) Allocator.Error!Scripts {
    var scripts = Scripts{};
    try scripts.setup(allocator);
    return scripts;
}

pub fn setup(scripts: *Scripts, allocator: Allocator) Allocator.Error!void {
    scripts.setupInner(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        }
    };
}

inline fn setupInner(scripts: *Scripts, allocator: mem.Allocator) !void {
    const decompressor = compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("scripts");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const endian = builtin.cpu.arch.endian();

    const s1_len: u16 = try reader.readInt(u16, endian);
    scripts.s1 = try allocator.alloc(u16, s1_len);
    errdefer allocator.free(scripts.s1);
    for (0..s1_len) |i| scripts.s1[i] = try reader.readInt(u16, endian);

    const s2_len: u16 = try reader.readInt(u16, endian);
    scripts.s2 = try allocator.alloc(u8, s2_len);
    errdefer allocator.free(scripts.s2);
    _ = try reader.readAll(scripts.s2);

    const s3_len: u16 = try reader.readInt(u8, endian);
    scripts.s3 = try allocator.alloc(u8, s3_len);
    errdefer allocator.free(scripts.s3);
    _ = try reader.readAll(scripts.s3);
}

pub fn deinit(self: *const Scripts, allocator: mem.Allocator) void {
    allocator.free(self.s1);
    allocator.free(self.s2);
    allocator.free(self.s3);
}

/// Lookup the Script type for `cp`.
pub fn script(self: Scripts, cp: u21) ?Script {
    const byte = self.s3[self.s2[self.s1[cp >> 8] + (cp & 0xff)]];
    if (byte == 0) return null;
    return @enumFromInt(byte);
}

test "script" {
    const self = try init(std.testing.allocator);
    defer self.deinit(std.testing.allocator);
    try testing.expectEqual(Script.Latin, self.script('A').?);
}

fn testAllocator(allocator: Allocator) !void {
    var prop = try Scripts.init(allocator);
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
