# Matrix Demo Performance Comparison

## Original Matrix Demo (matrix.wren)
- **Individual DOM Updates**: Each `updateText()` and `updateClass()` call yields individually
- **Per-Frame Yields**: ~2000+ individual yields for 80x24 terminal (2 updates per cell)
- **Context Switching**: Massive overhead from Wren↔Native transitions

```wren
// Original approach - thousands of individual yields
for (y in 0..._height) {
  for (x in 0..._width) {
    _cells[y][x][1].updateText(ch)     // Individual yield #1
    _cells[y][x][0].updateClass(cls)   // Individual yield #2
  }
}
// Result: 1920+ yields per frame for 80x24 terminal
```

## Batched Matrix Demo (matrix_batched.wren)  
- **Batched DOM Updates**: Collects all updates in array, submits once
- **Per-Frame Yields**: **1 single yield** per frame regardless of terminal size
- **Minimal Context Switching**: 99%+ reduction in Wren↔Native transitions

```wren
// Batched approach - single yield per frame
var domUpdates = []
for (y in 0..._height) {
  for (x in 0..._width) {
    domUpdates.add(updateTextRequest.new(textNodeId, ch))
    domUpdates.add(updateClassRequest.new(cellNodeId, cls))
  }
}
ring.submitAndWait(domUpdates)  // Single yield for ENTIRE frame!
// Result: 1 yield per frame regardless of size
```

## Performance Benefits

### Context Switching Reduction
- **Original**: 1920+ yields per frame (80x24 terminal)
- **Batched**: 1 yield per frame
- **Improvement**: 99.95%+ reduction in context switches

### Scalability
- **Original**: Performance degrades linearly with terminal size
- **Batched**: Performance stays constant regardless of terminal size
- **Large Terminals**: 200x50 terminal = 20,000 operations still = 1 yield

### Real-World Impact
- **WASM Deployment**: Massive reduction in JavaScript↔WASM boundary crossings
- **Native Performance**: Eliminates fiber scheduling overhead
- **Batched I/O**: Enables true async I/O patterns like io_uring

## Architecture Comparison

### Traditional FFI Approach (NOT used)
```
Wren → foreign call → Native
Wren → foreign call → Native  
[Repeat 2000+ times per frame]
```

### Fiberscript Yield-Only + Batching
```
Wren → collect requests → yield batch → Native processes all → resume
[Once per frame, regardless of operation count]
```

This demonstrates the power of the yield-only architecture combined with batching - achieving both clean high-level APIs and optimal low-level performance.