const std = @import("std");
const AnsiStreamer = @import("AnsiStreamer.zig").AnsiStreamer;

/// Compact style representation (64 bits total)
pub const Style = packed struct {
    // Foreground color (24 bits + 1 flag)
    fg_r: u8 = 0,
    fg_g: u8 = 0, 
    fg_b: u8 = 0,
    has_fg: bool = false,
    
    // Background color (24 bits + 1 flag)
    bg_r: u8 = 0,
    bg_g: u8 = 0,
    bg_b: u8 = 0,
    has_bg: bool = false,
    
    // Text attributes (4 bits)
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    
    // Padding to align to 64 bits
    _pad: u4 = 0,

    pub fn init() Style {
        return .{};
    }

    pub fn withForeground(r: u8, g: u8, b: u8) Style {
        return .{ .fg_r = r, .fg_g = g, .fg_b = b, .has_fg = true };
    }

    pub fn withBackground(r: u8, g: u8, b: u8) Style {
        return .{ .bg_r = r, .bg_g = g, .bg_b = b, .has_bg = true };
    }

    pub fn withBold() Style {
        return .{ .bold = true };
    }

    pub fn withDim() Style {
        return .{ .dim = true };
    }

    pub fn withItalic() Style {
        return .{ .italic = true };
    }

    pub fn withUnderline() Style {
        return .{ .underline = true };
    }

    pub fn equals(self: Style, other: Style) bool {
        const self_int: u64 = @bitCast(self);
        const other_int: u64 = @bitCast(other);
        return self_int == other_int;
    }
};

/// Non-allocating style applier
/// Tracks current style state and applies minimal ANSI sequences
pub const StyleApplier = struct {
    current: Style = .{},

    pub fn init() StyleApplier {
        return .{};
    }

    /// Apply a style, outputting only the necessary ANSI sequences
    pub fn apply(self: *StyleApplier, writer: anytype, ansi: *AnsiStreamer, new_style: Style) !void {
        const old_style = self.current;
        
        // If styles are identical, no work needed
        if (new_style.equals(old_style)) return;

        // Check if we need to reset first
        const needs_reset = 
            // Turning off attributes requires reset
            (old_style.bold and !new_style.bold) or
            (old_style.dim and !new_style.dim) or  
            (old_style.italic and !new_style.italic) or
            (old_style.underline and !new_style.underline) or
            // Color removal requires reset
            (old_style.has_fg and !new_style.has_fg) or
            (old_style.has_bg and !new_style.has_bg);

        if (needs_reset) {
            try ansi.resetStyle(writer);
            self.current = .{};
        }

        // Apply new foreground color
        if (new_style.has_fg and 
            (!self.current.has_fg or 
             self.current.fg_r != new_style.fg_r or
             self.current.fg_g != new_style.fg_g or 
             self.current.fg_b != new_style.fg_b)) {
            try ansi.setForegroundRgb(writer, new_style.fg_r, new_style.fg_g, new_style.fg_b);
        }

        // Apply new background color  
        if (new_style.has_bg and
            (!self.current.has_bg or
             self.current.bg_r != new_style.bg_r or
             self.current.bg_g != new_style.bg_g or
             self.current.bg_b != new_style.bg_b)) {
            try ansi.setBackgroundRgb(writer, new_style.bg_r, new_style.bg_g, new_style.bg_b);
        }

        // Apply attributes
        if (new_style.bold and !self.current.bold) {
            try ansi.setBold(writer);
        }
        if (new_style.dim and !self.current.dim) {
            try ansi.setDim(writer);
        }
        if (new_style.italic and !self.current.italic) {
            try ansi.setItalic(writer);
        }
        if (new_style.underline and !self.current.underline) {
            try ansi.setUnderline(writer);
        }

        // Update current style
        self.current = new_style;
    }

    /// Reset to no style
    pub fn reset(self: *StyleApplier, writer: anytype, ansi: *AnsiStreamer) !void {
        try ansi.resetStyle(writer);
        self.current = .{};
    }

    /// Get current style (for inspection/debugging)
    pub fn getCurrentStyle(self: *const StyleApplier) Style {
        return self.current;
    }
};

// === Convenience Functions ===

/// Common color constants
pub const Colors = struct {
    pub const red = Style.withForeground(255, 0, 0);
    pub const green = Style.withForeground(0, 200, 0);
    pub const blue = Style.withForeground(0, 0, 255);
    pub const yellow = Style.withForeground(200, 200, 0);
    pub const cyan = Style.withForeground(0, 200, 200);
    pub const magenta = Style.withForeground(200, 0, 200);
    pub const white = Style.withForeground(255, 255, 255);
    pub const gray = Style.withForeground(150, 150, 150);
    pub const dim_gray = Style.withForeground(100, 100, 100);
};

// === Tests ===

test "Style creation and comparison" {
    const style1 = Style.withForeground(255, 0, 0);
    const style2 = Style.withForeground(255, 0, 0);
    const style3 = Style.withForeground(0, 255, 0);

    try std.testing.expect(style1.equals(style2));
    try std.testing.expect(!style1.equals(style3));
}

test "StyleApplier basic operations" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = AnsiStreamer.init(false);
    var applier = StyleApplier.init();

    // Apply red foreground
    const red_style = Style.withForeground(255, 0, 0);
    try applier.apply(buffer.writer(), &ansi, red_style);
    
    // Should output foreground color code
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;0m", buffer.items);

    // Clear buffer
    buffer.clearRetainingCapacity();

    // Apply same style again - should output nothing
    try applier.apply(buffer.writer(), &ansi, red_style);
    try std.testing.expectEqualStrings("", buffer.items);
}

test "StyleApplier reset behavior" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = AnsiStreamer.init(false);
    var applier = StyleApplier.init();

    // Apply bold red
    const bold_red = Style{ .fg_r = 255, .has_fg = true, .bold = true };
    try applier.apply(buffer.writer(), &ansi, bold_red);
    
    buffer.clearRetainingCapacity();

    // Apply plain text (should reset then apply nothing)  
    const plain = Style{};
    try applier.apply(buffer.writer(), &ansi, plain);
    
    try std.testing.expectEqualStrings("\x1b[0m", buffer.items);
}

test "StyleApplier incremental changes" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var ansi = AnsiStreamer.init(false);
    var applier = StyleApplier.init();

    // Apply red
    try applier.apply(buffer.writer(), &ansi, Style.withForeground(255, 0, 0));
    buffer.clearRetainingCapacity();

    // Change to blue (should only change color, not reset)
    try applier.apply(buffer.writer(), &ansi, Style.withForeground(0, 0, 255));
    try std.testing.expectEqualStrings("\x1b[38;2;0;0;255m", buffer.items);
    
    buffer.clearRetainingCapacity();

    // Add bold (should add bold without changing color)
    try applier.apply(buffer.writer(), &ansi, Style{ .fg_r = 0, .fg_g = 0, .fg_b = 255, .has_fg = true, .bold = true });
    try std.testing.expectEqualStrings("\x1b[1m", buffer.items);
}