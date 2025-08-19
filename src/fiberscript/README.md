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

The ring acts as a high-performance async I/O system inspired by Linux io_uring. It uses circular buffers for batched submission and completion, minimizing syscall overhead and enabling efficient cooperative multitasking.

### Ring Architecture

- **Submission Queue (SQ)**: Circular buffer for batching request submissions
- **Completion Queue (CQ)**: Circular buffer for batching operation completions  
- **Operation Tracking**: Maps operation IDs to waiting fibers
- **Batch Processing**: Submit/complete multiple operations in single calls

### Wren API

```wren
// Create ring with 64-entry SQ and CQ
var ring = Ring.new(64, 64)

// Single operation
var opId = ring.submit(request)
ring.flush()
ring.wait(1)
var completions = ring.reap(1)

// Batch operations (efficient)
var opIds = ring.submitBatch([req1, req2, req3])
ring.flush()
ring.wait(opIds.count)
var completions = ring.reap(opIds.count)

// High-level convenience
var completions = ring.submitAndWait([req1, req2, req3])
```

### Native Integration

```zig
// Trampoline processes batched submissions
const requests = ring.grabBatch(32);
for (requests) |request| {
    const result = processRequest(request);
    completions.append(.{ ._opId = request._opId, .result = result });
}
ring.completeBatch(completions);
```

This enables true batched async I/O where multiple operations can be submitted and processed together, dramatically improving performance for I/O-heavy workloads.

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

### Core System
- `vm_context.zig` - VM management and fiber scheduling
- `syscalls.zig` - Comptime syscall generation system  
- `vm.zig` - Core VM integration and request types
- `ring.wren` - Wren-side ring system implementation
- `slots.zig` - Wren slot manipulation utilities
- `wren.zig` - Wren C API bindings

### Demo Applications
- `../demos/matrix.wren` - Original matrix demo (individual DOM updates)
- `../demos/matrix_batched.wren` - Batched matrix demo (99%+ performance improvement)
- `../demos/waves.wren` - Wave animation with particles and stars
- `../demos/performance_comparison.md` - Detailed performance analysis

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

Fiberscript emphasizes a **yield-only architecture** that avoids traditional foreign function calls entirely:

### Yield-Only Design

Instead of direct Wren→Zig foreign calls, **all** native operations use cooperative yielding:

```wren
// Traditional FFI approach (NOT used):
foreign static nativePrint(message)  // Direct call, context switching

// Fiberscript approach - yield-only:
printRequest.new("hello").submit()   // Yield to ring, batch with others
```

### Benefits of Yield-Only Architecture

1. **Minimal Context Switching** - Batch hundreds of operations in single yield
2. **Cooperative Scheduling** - Fibers yield voluntarily, no preemption overhead  
3. **Efficient Batching** - DOM updates, I/O operations batch naturally
4. **Predictable Performance** - No hidden FFI costs or unexpected blocking

### Real-World Use Case: Matrix Animation Performance

The matrix digital rain demo showcases the dramatic performance benefits of batched operations:

**Original approach (individual updates):**
```wren
// Traditional: thousands of individual foreign calls per frame
for (y in 0..._height) {
  for (x in 0..._width) {
    _cells[y][x][1].updateText(ch)     // Individual yield
    _cells[y][x][0].updateClass(cls)   // Individual yield
  }
}
// Result: 1920+ yields per frame for 80x24 terminal
```

**Fiberscript batched approach:**
```wren
// Collect all updates for the frame
var domUpdates = []
for (y in 0..._height) {
  for (x in 0..._width) {
    domUpdates.add(updateTextRequest.new(textNodeId, ch))
    domUpdates.add(updateClassRequest.new(cellNodeId, cls))
  }
}

// Submit entire frame as single batch
ring.submitAndWait(domUpdates)  // Single yield for ENTIRE frame!
```

**Performance transformation:**
- **Before**: 1920+ context switches per frame (80x24 terminal)
- **After**: 1 context switch per frame (regardless of size)
- **Improvement**: 99.95%+ reduction in overhead
- **Scalability**: 200x50 terminal = 20,000 operations still = 1 yield

This demonstrates how fiberscript transforms performance-critical animations from unusable (thousands of foreign calls) to optimal (single batched operation) while maintaining clean, readable code.

### WebAssembly Deployment

The entire system compiles to WebAssembly with a custom WASI implementation:

- **Wren VM + Fiberscript** → WASM module
- **TypeScript WASI runtime** handles syscall interface
- **Browser integration** via yielding to JavaScript event loop
- **Same batching benefits** apply in web environments

### Core Principles

1. **Yield-only communication** - No direct foreign calls, everything through cooperative yielding
2. **Batched efficiency** - Minimize context switches through intelligent batching
3. **Cooperative scheduling** - Fibers control their own execution timing
4. **Cross-platform deployment** - Same code runs native and in WebAssembly
5. **Type-safe generation** - Comptime validation with zero runtime overhead

The result is a uniquely efficient runtime that achieves both high-level expressiveness and low-level performance through architectural discipline.