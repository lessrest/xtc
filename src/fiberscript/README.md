# Fiberscript

A Wren-based fiber runtime with cooperative scheduling and efficient syscall dispatch.

## Overview

Fiberscript is an embedded scripting system that uses the [Wren](https://wren.io/) programming language to provide cooperative multitasking through fibers. It features a ring-based async I/O system inspired by io_uring, with zero-overhead syscall marshalling and comptime-generated boilerplate elimination.

## Architecture

The system follows a clean pipeline from Wren scripts to native syscall implementations:

**Wren Fiber → Ring System → Trampoline → Syscall Implementation**

### Core Components

- **VM Context** (`vm_context.zig`) - Unified Wren VM management with fiber scheduling
- **Ring System** (`ring.wren`) - Async I/O abstraction for cooperative fiber scheduling  
- **Syscalls** (`syscalls.zig`) - Comptime-generated syscall dispatch system
- **Trampoline** - Control flow bridge between Wren fibers and native implementations

## The Ring Concept

The ring acts as a structured message passing system between Wren fibers and native code:

```wren
// Wren side: Submit work and yield
ring.post(request)
ring.push()  // Yield to trampoline
result = ring.pull()  // Resume with result
```

```zig
// Native side: Process submissions
const request = ring.grab();  // Get work from submission queue
const result = processRequest(request);
ring.give(result);  // Put result in completion queue
```

This enables cooperative multitasking where fibers yield control during I/O operations and resume when results are available.

## Syscalls System

The syscalls system uses Zig's comptime metaprogramming to generate all boilerplate from a single interface definition:

### 1. Define Syscalls Interface

```zig
pub fn MySyscalls(comptime Context: type) type {
    return struct {
        print: *const fn (*Context, struct { message: []const u8 }) []const u8,
        readFile: *const fn (*Context, struct { path: []const u8 }) []const u8,
        sleep: *const fn (*Context, struct { duration_ms: u64 }) void,
        
        pub fn Payload(comptime operation: std.meta.FieldEnum(@This())) type {
            // Extract payload type for compile-time validation
        }
    };
}
```

### 2. Implement Syscalls

```zig
const MyImpl = struct {
    pub fn print(ctx: *MyContext, payload: MySyscalls(MyContext).Payload(.print)) []const u8 {
        std.debug.print("{s}\n", .{payload.message});
        return payload.message;
    }
    // ... other implementations
};

// Bind with compile-time validation
const syscalls = bindSyscalls(MySyscalls(MyContext), MyImpl);
```

### 3. Generated Components

The system automatically generates:

- **Request Union** - Tagged union of all syscall payloads
- **Slot Parser** - Wren→Zig marshalling code  
- **Trampoline Dispatcher** - Syscall routing logic
- **Foreign Classes** - Zero-overhead Wren objects containing native structs
- **Wren Request Classes** - Clean inheritance hierarchy

### 4. Generated Wren API

```wren
// Base class with common patterns
class Request {
    submit() {
        ring.post(this)
        ring.push()
        return ring.pull()
    }
}

// Generated request classes
class printRequest is Request {
    construct new(message) { 
        super()
        _message = message 
    }
    message { _message }
}

// Clean usage
var result = printRequest.new("Hello, World!").submit()
```

## Key Features

### Comptime Generation
- **Single source of truth** - Interface definition drives everything
- **Zero runtime overhead** - All boilerplate generated at compile time
- **Type safety** - Full compile-time validation of implementations
- **Automatic marshalling** - No manual slot parsing or union construction

### Foreign Class System
- **Zero-copy marshalling** - Wren objects contain native structs directly
- **O(1) dispatch** - Operation IDs embedded in foreign objects
- **Type-safe constructors** - Parameters match native struct fields exactly

### Ring-based Async I/O
- **Cooperative scheduling** - Fibers yield during I/O operations
- **Structured messaging** - Clean separation of submission and completion
- **Trampoline pattern** - Efficient fiber resumption

### Context Parameterization
- **Dependency injection** - Syscalls parameterized by context type
- **Clean testing** - Mock contexts for unit tests
- **Modular design** - Easy to swap implementations

## Usage Example

```zig
// Define your context and syscalls
const MyContext = struct { /* ... */ };
const MySyscalls = MyAppSyscalls(MyContext);

// Generate all the components
const Request = RequestUnion(MySyscalls);
const Trampoline = generateTrampoline(MySyscalls, MyContext);
const RequestClasses = generateRequestClasses(MySyscalls);

// Set up runtime
var context = MyContext.init();
var trampoline = Trampoline{ .syscalls = my_impl, .context = &context };

// Generate Wren classes
const wren_code = try generateWrenConstants(MySyscalls, allocator);

// Integrate with VM and run fibers
```

## Files

- `vm_context.zig` - VM management and fiber scheduling
- `syscalls.zig` - Comptime syscall generation system  
- `vm.zig` - Core VM integration and request types
- `ring.wren` - Wren-side ring system implementation
- `slots.zig` - Wren slot manipulation utilities
- `wren.zig` - Wren C API bindings

## Testing

Run the test suite with:
```bash
zig build test
```

The syscalls system includes comprehensive tests covering:
- Request union generation
- Slot parsing  
- Trampoline dispatch
- Foreign class system
- Binding functor validation
- End-to-end integration

## Design Philosophy

Fiberscript emphasizes:

1. **Clean abstractions** - Ring system provides simple async patterns
2. **Zero overhead** - Comptime generation eliminates runtime costs  
3. **Type safety** - Compile-time validation catches errors early
4. **Ease of use** - Generated Wren classes provide clean APIs
5. **Bottom-up design** - TDD approach ensures robust foundations

The result is a fast, safe, and ergonomic bridge between high-level Wren scripts and low-level native implementations.