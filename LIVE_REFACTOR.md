# Live Mode Refactoring

## Problems with Original `live.zig`

1. **Monolithic function**: The main `run()` function was 400+ lines
2. **Mixed concerns**: Terminal management, rendering, input handling, clock management all jumbled together  
3. **Procedural sprawl**: No clear data flow or state management
4. **Hidden dependencies**: State scattered across multiple variables
5. **Poor testability**: Can't test components in isolation
6. **Unclear lifecycle**: Setup/teardown mixed with runtime logic

## New Architecture

### Core Concepts

```
┌──────────────────────────────────────────┐
│              LiveSession                 │
│  (Central state container)               │
│  - document, renderer, wren, clocks      │
└──────────────────────────────────────────┘
                    ▲
                    │
┌──────────────────────────────────────────┐
│              EventLoop                   │
│  (Coordinates components)                │
│  - Polls input                          │
│  - Checks resize                        │  
│  - Processes clocks                     │
│  - Triggers renders                     │
└──────────────────────────────────────────┘
        ▲               ▲               ▲
        │               │               │
┌──────────┐    ┌──────────┐    ┌──────────┐
│ Terminal │    │  Input   │    │  Clocks  │
│          │    │  Reader  │    │          │
└──────────┘    └──────────┘    └──────────┘
```

### Key Improvements

#### 1. **LiveSession** - Single source of truth
```zig
pub const LiveSession = struct {
    allocator: std.mem.Allocator,
    document: *dom.Dom,
    renderer: renderer.Renderer,
    wren_runner: *WrenRunner,
    clock_registry: *clock.ClockRegistry,
    root_id: dom.DomNodeId,
    trace: Trace,
    
    // Clear, focused methods
    pub fn render(self: *LiveSession) !void
    pub fn handleResize(self: *LiveSession, width: usize, height: usize) !void  
    pub fn processClock(self: *LiveSession) !bool
    pub fn handleKeypress(self: *LiveSession, key: u8) !void
};
```

#### 2. **Terminal** - Encapsulated terminal management
```zig
pub const Terminal = struct {
    pub fn enterLiveMode(self: *Terminal) !void  // Setup
    pub fn exitLiveMode(self: *Terminal) void    // Cleanup
    pub fn getSize() [2]usize                     // Query
};
```

#### 3. **EventLoop** - Clear control flow
```zig
pub const EventLoop = struct {
    pub fn run(self: *EventLoop) !void {
        while (true) {
            // 1. Check resize
            // 2. Process clocks  
            // 3. Read input with timeout
            // 4. Handle events
        }
    }
};
```

#### 4. **DocumentLoader** - Unified loading interface
```zig
pub const DocumentLoader = struct {
    pub fn loadXmlFile(self: *DocumentLoader, path: []const u8) !LoadResult
    pub fn loadWrenFile(self: *DocumentLoader, path: []const u8) !LoadResult
    pub fn createDefault(self: *DocumentLoader) !LoadResult
};
```

### Benefits

1. **Testability**: Each component can be tested in isolation
2. **Composability**: Components can be mixed and matched
3. **Clarity**: Each struct has a single, clear purpose
4. **Maintainability**: Changes are localized to relevant components
5. **Extensibility**: Easy to add new input sources, render targets, etc.

### Simplified Main Flow

```zig
pub fn run(allocator: std.mem.Allocator, xml_path: ?[]const u8, wren_path: ?[]const u8) !void {
    // 1. Setup tracing
    // 2. Initialize terminal 
    // 3. Initialize components
    // 4. Load document
    // 5. Configure viewport
    // 6. Create renderer
    // 7. Create session
    // 8. Initial render
    // 9. Start clocks
    // 10. Run event loop
}
```

Each step is now clear, purposeful, and delegated to the appropriate abstraction.

## Migration Path

1. Keep existing `live.zig` working
2. Develop new components alongside
3. Gradually move functionality to new components
4. Switch over once feature-complete
5. Remove old code

## Future Improvements

- **Plugin system**: Components could be plugins
- **Event bus**: Decouple components further
- **State machine**: Formalize state transitions
- **Command pattern**: Undo/redo support
- **Async I/O**: Non-blocking input/output