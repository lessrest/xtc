# Terminal Output Redesign Specification

## Problem Analysis

The current terminal output system (`treenest.zig`, `dank.zig`, `AnsiWriter.zig`) has several issues:

### Current Issues
- **Memory allocation**: Components allocate memory for formatting operations
- **Mixed responsibilities**: Tree structure, styling, ANSI output, and domain formatting intertwined
- **Complex APIs**: Many methods with overlapping functionality  
- **Inconsistent error handling**: Some methods ignore errors, others propagate
- **Hard to compose**: Monolithic components that try to do everything
- **Not testable**: Complex state makes unit testing difficult

### Usage Patterns
- Tracing/logging with hierarchical structure
- Test runner output with formatted results
- Stack trace dumping with source code snippets
- Debug output with tree-like visualization

## New Design Principles

1. **Separation of Concerns**: Separate tree structure, styling, and ANSI output
2. **Non-allocating**: Use stack buffers, streaming, or caller-provided buffers
3. **Composable**: Small, focused components that can be combined
4. **Simple APIs**: Few methods with clear responsibilities
5. **Correct Error Handling**: Consistent error propagation throughout
6. **Zero-cost Abstractions**: No runtime overhead for unused features

## Core Architecture

### 1. AnsiStreamer - ANSI Escape Sequence Generation
**Responsibility**: Generate ANSI escape sequences without allocation

```zig
pub const AnsiStreamer = struct {
    no_color: bool = false,
    
    // Non-allocating methods that write directly to provided writer
    pub fn resetStyle(writer: anytype) !void
    pub fn setForegroundRgb(writer: anytype, r: u8, g: u8, b: u8) !void
    pub fn setBold(writer: anytype) !void
    pub fn moveCursor(writer: anytype, row: u32, col: u32) !void
    // ... other ANSI operations
};
```

### 2. TreeFormatter - Tree Structure Rendering  
**Responsibility**: Format hierarchical tree structures without allocation

```zig
pub const TreeFormatter = struct {
    depth: u8 = 0,
    stack: [32]LevelState, // Fixed-size stack
    
    pub const LevelState = struct { has_more: bool };
    
    pub fn enter(self: *Self) !void
    pub fn exit(self: *Self) !void
    pub fn writeIndent(self: *Self, writer: anytype, is_last: bool) !void
    pub fn writeContinuation(self: *Self, writer: anytype) !void
};
```

### 3. StyleApplier - Style Management
**Responsibility**: Apply styles without allocation using streaming approach

```zig
pub const Style = packed struct {
    fg_r: u8 = 0, fg_g: u8 = 0, fg_b: u8 = 0, has_fg: bool = false,
    bg_r: u8 = 0, bg_g: u8 = 0, bg_b: u8 = 0, has_bg: bool = false,  
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const StyleApplier = struct {
    current: Style = .{},
    
    pub fn apply(self: *Self, writer: anytype, ansi: *AnsiStreamer, new_style: Style) !void
    pub fn reset(self: *Self, writer: anytype, ansi: *AnsiStreamer) !void
};
```

### 4. BufferedTerminal - Output Coordination
**Responsibility**: Coordinate the other components with optional buffering

```zig
pub fn BufferedTerminal(comptime Writer: type, comptime buffer_size: usize) type {
    return struct {
        writer: Writer,
        buffer: [buffer_size]u8,
        pos: usize = 0,
        
        ansi: AnsiStreamer,
        tree: TreeFormatter,
        style: StyleApplier,
        
        pub fn init(writer: Writer, no_color: bool) Self
        pub fn flush(self: *Self) !void
        pub fn writeStyled(self: *Self, text: []const u8, style: Style) !void
        pub fn enterTree(self: *Self) !void
        pub fn exitTree(self: *Self) !void
        pub fn writeTreeLine(self: *Self, text: []const u8, style: Style, is_last: bool) !void
    };
}
```

## API Usage Examples

### Basic Styled Output
```zig
var terminal = BufferedTerminal(File.Writer, 4096).init(stdout.writer(), false);

// Simple styled text
try terminal.writeStyled("Hello", .{ .fg_r = 255, .has_fg = true, .bold = true });

// Tree structure  
try terminal.enterTree();
try terminal.writeTreeLine("Root", .{}, false);
try terminal.enterTree();
try terminal.writeTreeLine("Child 1", .{ .fg_g = 200, .has_fg = true }, false);
try terminal.writeTreeLine("Child 2", .{ .fg_g = 200, .has_fg = true }, true);
try terminal.exitTree();
try terminal.exitTree();
```

### Domain-Specific Extensions
```zig
// Extensions built on top of core components
pub fn writeTestResult(terminal: anytype, name: []const u8, passed: bool) !void {
    const style = if (passed) 
        Style{ .fg_g = 200, .has_fg = true } 
    else 
        Style{ .fg_r = 200, .has_fg = true };
    const icon = if (passed) "✓" else "✗";
    
    try terminal.writeStyled(icon, style);
    try terminal.writeStyled(" ", .{});
    try terminal.writeStyled(name, .{});
}
```

## Migration Strategy

### Phase 1: Core Components
1. Implement `AnsiStreamer` 
2. Implement `TreeFormatter`
3. Implement `StyleApplier`
4. Implement `BufferedTerminal`
5. Write comprehensive tests

### Phase 2: Domain Extensions
1. Create domain-specific helper functions (test output, tracing, etc.)
2. Port existing `dank.zig` functionality as composable functions

### Phase 3: Incremental Migration  
1. Update `libansi.zig` to expose new API alongside old
2. Port test runner to new API
3. Port tracing usage sites  
4. Remove old components

## Benefits

1. **Memory Efficient**: No allocations in core paths
2. **Composable**: Components can be mixed and matched
3. **Testable**: Simple, focused components are easy to test
4. **Fast**: Direct streaming with minimal overhead
5. **Flexible**: Easy to extend with domain-specific functionality
6. **Maintainable**: Clear separation of concerns

## File Structure

```
src/lib/terminal/
├── AnsiStreamer.zig      # ANSI escape sequences
├── TreeFormatter.zig     # Tree structure rendering  
├── StyleApplier.zig      # Style management
├── BufferedTerminal.zig  # Coordinating component
├── helpers.zig           # Domain-specific helpers
└── terminal.zig          # Main module exports
```