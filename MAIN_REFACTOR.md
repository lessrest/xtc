# Main.zig Refactoring

## Original Problems

The original `main.zig` was a 280+ line monolith that:
- Mixed CLI parsing with business logic
- Duplicated rendering logic for XML and Wren inputs
- Had no clear separation between one-shot and live modes
- Handled logging, panic recovery, and debug formatting inline
- Made testing nearly impossible

## New Architecture

```
main.zig (30 lines)
    ├── Boot: Memory allocation
    └── Delegate: Application.run()

app.zig (Application)
    ├── Parse: CLI arguments via cli.zig
    ├── Setup: Logging configuration
    ├── Route: Mode selection
    ├── Live: Delegate to live.zig
    └── OneShot: Delegate to one_shot.zig

cli.zig (Argument Parser)
    ├── Structured Args type
    ├── Input detection (file vs string)
    ├── Mode inference
    └── Help text generation

one_shot.zig (OneShotSession)
    ├── Component initialization
    ├── Document loading via DocumentLoader
    ├── Single render to stdout
    └── Clean resource management

logging.zig (Centralized Logging)
    ├── Global log file management
    ├── Custom log function
    └── Panic handler for terminal cleanup
```

## Key Abstractions

### 1. CLI Module - Structured Argument Parsing
```zig
pub const Args = struct {
    mode: Mode,              // live or one_shot
    input: Input,            // xml/wren file/string/default
    output: OutputConfig,    // width, height
    log_path: ?[]const u8,
    debug_mode: bool,
};

pub const Input = union(enum) {
    xml_file: []const u8,
    xml_string: []const u8,
    wren_file: []const u8,
    wren_string: []const u8,
    default: void,
};
```

### 2. Application - Central Coordinator
```zig
pub const Application = struct {
    allocator: std.mem.Allocator,
    args: cli.Args,
    log_file: ?std.fs.File,
    
    pub fn run(self: *Application) !void {
        // Setup → Route → Execute → Cleanup
    }
};
```

### 3. OneShotSession - Clean One-Shot Rendering
```zig
pub const OneShotSession = struct {
    pub fn run(self: *OneShotSession, input: cli.Input) !void {
        // Initialize → Load → Render → Exit
    }
};
```

### 4. Main.zig - Pure Boot Module
```zig
pub fn main() !void {
    // 1. Setup memory
    // 2. Create application
    // 3. Run application
    // 4. Cleanup
}
```

## Benefits

### Separation of Concerns
- **main.zig**: Boot and memory management only
- **cli.zig**: All argument parsing logic
- **app.zig**: Application coordination and routing
- **one_shot.zig**: One-shot rendering logic
- **logging.zig**: All logging concerns

### Testability
Each module can be tested independently:
- Test CLI parsing without running the app
- Test one-shot rendering without CLI
- Test application routing without I/O

### Extensibility
- Add new input formats: Extend `cli.Input`
- Add new modes: Extend `cli.Mode` and `app.run()`
- Add new output targets: Modify `OneShotSession`

### Clarity
The flow is now completely linear and obvious:
```
Parse Args → Setup Logging → Route to Mode → Execute → Cleanup
```

## Migration Benefits

1. **Reduced Complexity**: 280+ lines → 30 lines in main.zig
2. **Better Error Handling**: Each layer handles its own errors
3. **Resource Management**: Clear ownership and cleanup
4. **Mode Parity**: Live and one-shot use same components
5. **Future-Proof**: Easy to add new features without touching main

## Usage Examples

```bash
# One-shot XML rendering
xtc --xml layout.xml --width 100 --height 30

# Live mode with XML
xtc --live --xml layout.xml

# One-shot Wren script
xtc --wren script.wren

# Live mode (default when no input)
xtc

# Debug mode with trace formatting
xtc --xml test.xml --debug --log trace.log
```

## Next Steps

1. Replace old main.zig with main_refactored.zig
2. Update build.zig to use new structure
3. Add unit tests for each module
4. Consider async I/O for better performance
5. Add more output formats (JSON, HTML, etc.)