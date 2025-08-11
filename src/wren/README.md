# XTC Wren Scripting Engine

Wren is XTC's embedded scripting language for creating dynamic, interactive terminal UIs. It provides a clean, object-oriented API for DOM manipulation, event handling, and component creation.

## Architecture

```
src/wren/
├── vm.zig          # Wren VM bindings and FFI integration
├── runner.zig      # High-level script runner with DOM context
├── dom.zig         # DOM manipulation API for Wren
├── xml.zig         # XML-to-DOM with embedded scripts
├── events.zig      # Event system integration
├── modules.zig     # Module registry for dynamic loading
├── test_dom.zig    # DOM integration tests
└── modules/        # Wren modules
    ├── dom.wren    # Core DOM classes (Document, Element)
    └── editor.wren # Text editor component
```

## Core Components

### VM Integration (`vm.zig`)
Low-level Wren VM bindings with Zig's compile-time FFI generation. Handles:
- Foreign class/method registration
- Memory management
- Type conversions between Zig and Wren

### Script Runner (`runner.zig`)
High-level runner that sets up a complete scripting environment:
- Initializes VM with DOM context
- Loads core modules (dom, editor)
- Manages event handlers and callbacks
- Provides foreign methods for DOM manipulation

### DOM Module (`modules/dom.wren`)
Clean object-oriented API for DOM manipulation:

```wren
import "dom" for Document, Element

// Create elements
var title = Document.createElement("text-blue-400 text-center")
title.append(Document.createText("Hello XTC!"))
Document.root.append(title)

// Handle events
Document.addEventListener("keypress", Fn.new { |event|
    System.print("Key pressed: %(event["key"])")
})
```

### Event System
Bidirectional event flow between DOM and Wren:
- DOM events trigger Wren callbacks
- Wren can dispatch synthetic events
- Automatic handle management prevents GC issues

## Usage Examples

### Standalone Script
```wren
import "dom" for Document, Element

// Style the root
Document.root.updateClass("flex flex-col bg-black text-white p-4")

// Create interactive elements
var button = Document.createElement("bg-blue-500 hover:bg-blue-600 p-2")
button.append(Document.createText("Click me!"))
Document.root.append(button)

// Add interactivity
button.addEventListener("click", Fn.new { |event|
    button.updateClass("bg-green-500")
})
```

### XML with Embedded Scripts
```xml
<root class="flex flex-col">
    <text id="counter">Count: 0</text>
    <script>
        var count = 0
        var counter = Document.getElementById("counter")
        
        Document.addEventListener("keypress", Fn.new { |e|
            count = count + 1
            counter.updateText("Count: %(count)")
        })
    </script>
</root>
```

### Component Creation
```wren
import "editor" for Editor

// Create a text editor component
var container = Document.createElement("border p-2")
Document.root.append(container)

var editor = Editor.new(container)
editor.setText("Type here...")

// Handle submitted text
Document.addEventListener("keypress", Fn.new { |event|
    var result = editor.handleKey(event["key"])
    if (result != null) {
        System.print("Submitted: %(result)")
    }
})
```

## Module System

### Core Modules

**`dom`** - DOM manipulation and event handling
- `Document` class for document-level operations
- `Element` class for node manipulation
- Event registration and dispatch

**`editor`** - Text editing component
- Line editor with cursor navigation
- Keyboard shortcuts (Ctrl+A/E, arrows)
- Submit on Enter

### Creating Custom Modules

1. Create a `.wren` file in `src/wren/modules/`
2. Export a class with your API:

```wren
// modules/custom.wren
class MyComponent {
    construct new(container) {
        _container = container
        setupUI()
    }
    
    setupUI() {
        // Build your component
    }
}
```

3. Load in runner.zig:
```zig
try this.vm.interpret("custom", @embedFile("modules/custom.wren"));
```

## Foreign Function Interface

### Registering Zig Functions

In `runner.zig`, expose Zig functions to Wren:

```zig
pub const Modules = struct {
    pub const mymodule = struct {
        pub const MyClass = struct {
            pub fn myMethod(vm: *wren.c.WrenVM, ctx: *ScriptContext, arg: []const u8) void {
                // Zig implementation
            }
        };
    };
};
```

### Type Conversions

The VM automatically converts between Wren and Zig types:
- `Num` ↔ `f64`, `u32`, `i32`
- `String` ↔ `[]const u8`
- `Bool` ↔ `bool`
- Foreign classes ↔ Zig IDs/handles

## Best Practices

1. **Import Classes, Not Variables**: Follow Wren's paradigm of importing classes rather than global instances
2. **Memory Management**: The runner handles Wren handle lifecycle - don't manually release handles
3. **Event Cleanup**: Event handlers are automatically cleaned up on runner deinit
4. **Error Handling**: Use `vm.interpret()` which returns errors instead of aborting
5. **Performance**: Minimize FFI calls by batching DOM operations

## Testing

Run tests with:
```bash
zig build test
```

Key test files:
- `test_dom.zig` - DOM manipulation and script execution
- `../test_events.zig` - Event system integration

## Integration Points

The Wren engine integrates with:
- **Live Mode** (`../live.zig`) - Hot reload and interactive development
- **XML Parser** (`../xmlparse.zig`) - `<script>` tag execution
- **Event System** (`../events.zig`) - Keyboard/mouse input handling
- **DOM** (`../dom.zig`) - Direct manipulation of the render tree