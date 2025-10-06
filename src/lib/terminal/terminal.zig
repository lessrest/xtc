//! Modern terminal output library for XTC
//! 
//! This module provides a composable, non-allocating approach to terminal output
//! with support for ANSI styling, tree structures, and buffered output.
//!
//! Key principles:
//! - Non-allocating: Core operations use no heap allocation
//! - Composable: Small, focused components that work together  
//! - Simple: Clear APIs with single responsibilities
//! - Efficient: Minimal ANSI output and optional buffering

const std = @import("std");

// === Core Components ===

pub const AnsiStreamer = @import("AnsiStreamer.zig").AnsiStreamer;
pub const TreeFormatter = @import("TreeFormatter.zig").TreeFormatter;
pub const StyleApplier = @import("StyleApplier.zig").StyleApplier;
pub const Style = @import("StyleApplier.zig").Style;
pub const Colors = @import("StyleApplier.zig").Colors;
pub const BufferedTerminal = @import("BufferedTerminal.zig").BufferedTerminal;

// === Convenience Types ===

pub const StdoutTerminal = @import("BufferedTerminal.zig").StdoutTerminal;
pub const TestTerminal = @import("BufferedTerminal.zig").TestTerminal;

// === Convenience Functions ===

pub const stdout = @import("BufferedTerminal.zig").stdout;
pub const arrayListTerminal = @import("BufferedTerminal.zig").arrayListTerminal;

// === Domain-Specific Helpers ===

/// Domain-specific helper functions built on top of the core components
pub const helpers = struct {
    /// Write a test result with appropriate icon and styling
    pub fn writeTestResult(terminal: anytype, name: []const u8, passed: bool) !void {
        const style = if (passed) Colors.green else Colors.red;
        const icon = if (passed) "✓" else "✗";
        
        try terminal.writeStyledText(icon, style);
        try terminal.writeText(" ");
        try terminal.writeLine(name);
    }

    /// Write a progress bar
    pub fn writeProgressBar(terminal: anytype, current: usize, total: usize, width: usize) !void {
        const filled = if (total > 0) (current * width) / total else 0;
        const empty = width - filled;

        try terminal.writeText("[");
        
        // Filled portion in green
        if (filled > 0) {
            var i: usize = 0;
            while (i < filled) : (i += 1) {
                try terminal.writeStyledText("█", Colors.green);
            }
        }
        
        // Empty portion in gray
        if (empty > 0) {
            var i: usize = 0; 
            while (i < empty) : (i += 1) {
                try terminal.writeStyledText("░", Colors.gray);
            }
        }
        
        try terminal.writeText("] ");
        
        // Use a temporary buffer for formatting the progress text
        var buf: [32]u8 = undefined;
        const progress_text = std.fmt.bufPrint(&buf, "{d}/{d}", .{ current, total }) catch "?/?";
        try terminal.writeText(progress_text);
    }

    /// Write a section header  
    pub fn writeSection(terminal: anytype, title: []const u8) !void {
        try terminal.enterTree();
        try terminal.writeTreeNode(title, Style.withBold(), false);
    }

    /// Write an error message with icon
    pub fn writeError(terminal: anytype, message: []const u8) !void {
        try terminal.writeStyledText("✗", Colors.red);
        try terminal.writeText(" ");
        try terminal.writeStyledLine(message, Colors.red);
    }

    /// Write a success message with icon  
    pub fn writeSuccess(terminal: anytype, message: []const u8) !void {
        try terminal.writeStyledText("✓", Colors.green);
        try terminal.writeText(" ");
        try terminal.writeStyledLine(message, Colors.green);
    }

    /// Write a warning message with icon
    pub fn writeWarning(terminal: anytype, message: []const u8) !void {
        try terminal.writeStyledText("⚠", Colors.yellow);
        try terminal.writeText(" ");  
        try terminal.writeStyledLine(message, Colors.yellow);
    }

    /// Write an info message with icon
    pub fn writeInfo(terminal: anytype, message: []const u8) !void {
        try terminal.writeStyledText("ℹ", Colors.cyan);
        try terminal.writeText(" ");
        try terminal.writeStyledLine(message, Colors.cyan);
    }
};

// === Tests ===

test "terminal module basic functionality" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, true); // no color for simpler testing

    try helpers.writeTestResult(&terminal, "sample test", true);
    try terminal.flush();

    try std.testing.expectEqualStrings("✓ sample test\n", buffer.items);
}

test "terminal module tree structure" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, true);

    try helpers.writeSection(&terminal, "Test Results");
    try helpers.writeTestResult(&terminal, "test 1", true);
    try helpers.writeTestResult(&terminal, "test 2", false);
    terminal.exitTree();
    try terminal.flush();

    const expected = 
        \\┌─ Test Results
        \\│  ✓ test 1
        \\│  ✗ test 2
        \\
    ;
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "terminal module progress bar" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, true); // no color for cleaner output

    try helpers.writeProgressBar(&terminal, 7, 10, 20);
    try terminal.flush();

    // Should show 14 filled chars out of 20, plus progress text
    try std.testing.expectEqualStrings("[██████████████░░░░░░] 7/10", buffer.items);
}

// === Integration Tests ===

test "terminal module complete workflow" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var terminal = arrayListTerminal(&buffer, true);

    // Test suite header
    try helpers.writeSection(&terminal, "Running Tests");
    
    // Individual test results
    try helpers.writeTestResult(&terminal, "test_addition", true);
    try helpers.writeTestResult(&terminal, "test_subtraction", true);  
    try helpers.writeTestResult(&terminal, "test_division", false);
    
    // Nested section
    try helpers.writeSection(&terminal, "Integration Tests");
    try helpers.writeTestResult(&terminal, "test_integration_1", true);
    terminal.exitTree(); // integration tests
    
    terminal.exitTree(); // main section
    
    // Summary
    try terminal.writeLine("");
    try helpers.writeProgressBar(&terminal, 3, 4, 20);
    try terminal.writeLine("");
    try helpers.writeWarning(&terminal, "1 test failed");

    try terminal.flush();

    // Verify the structure is reasonable (exact content would be quite long to match)
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Running Tests") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "test_addition") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "✗ test_division") != null);
}