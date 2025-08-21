# Migration Plan: Terminal Output Redesign

## Overview

This document outlines the migration plan from the current messy terminal output system (`treenest.zig`, `dank.zig`, `AnsiWriter.zig`) to the new clean, composable architecture.

## Current Usage Analysis

Based on code analysis, the current system is used in:

### 1. Tracing/Logging (`src/layout.zig`, `src/dom.zig`, etc.)
- **Current**: `Trace = @import("ansi").FileTrace`
- **Pattern**: Hierarchical debug output with `trace.enter()`, `trace.exit()`, `trace.put()`, `trace.fields()`
- **Volume**: Heavy usage across layout engine, DOM manipulation

### 2. Test Runner (`src/lib/test_runner.zig`)
- **Current**: Complex usage of `TreeNest` and `Dank` for formatted test output
- **Pattern**: Test results, stack traces, progress indicators, colored output
- **Volume**: Moderate usage in test infrastructure

### 3. Stack Trace Dumping (`src/lib/libansi.zig`)
- **Current**: `dumpConciseStackTrace()` using `tree.dk()` methods
- **Pattern**: Source code display, file paths, syntax highlighting
- **Volume**: Error handling paths

### 4. General Debug Output (various files)
- **Current**: Ad-hoc usage of `tree.info()`, `tree.note()`, etc.
- **Pattern**: Simple styled output for debugging
- **Volume**: Light usage scattered throughout

## Migration Strategy

### Phase 1: Foundation (Week 1)
**Goal**: Establish new system alongside old system

1. **Create new terminal module** ✅
   - [x] `src/lib/terminal/` directory structure
   - [x] Core components (`AnsiStreamer`, `TreeFormatter`, `StyleApplier`, `BufferedTerminal`)
   - [x] Main module with convenience functions and helpers
   - [x] Comprehensive test coverage

2. **Integration with existing build system**
   - [ ] Update `build.zig` to include new terminal module
   - [ ] Add new module to `src/lib/libansi.zig` exports
   - [ ] Ensure compatibility with existing imports

### Phase 2: New Tracing API (Week 2)
**Goal**: Create drop-in replacement for tracing functionality

1. **Create trace wrapper**
   ```zig
   // src/lib/terminal/TraceWrapper.zig
   pub fn TraceWrapper(comptime Writer: type) type {
       return struct {
           terminal: BufferedTerminal(Writer, 4096),
           
           pub fn enter(self: *Self) !void { try self.terminal.enterTree(); }
           pub fn exit(self: *Self) void { self.terminal.exitTree(); }
           pub fn put(self: *Self, comptime key: []const u8, value: anytype) !void {
               // Format key-value pair and write as tree line
           }
           pub fn fields(self: *Self, comptime label: []const u8, data: anytype) !void {
               // Write structured data section
           }
       };
   }
   ```

2. **Update import aliases**
   ```zig
   // src/lib/libansi.zig
   pub const FileTrace = terminal.TraceWrapper(std.fs.File.Writer);
   // Keep old aliases working during migration
   pub const nest = @import("treenest.zig"); // deprecated
   ```

### Phase 3: Test Runner Migration (Week 3)  
**Goal**: Convert test runner to new API

1. **Create test output helpers**
   ```zig
   // src/lib/terminal/TestHelpers.zig
   pub fn writeTestSuite(terminal: anytype, name: []const u8) !void { ... }
   pub fn writeTestCase(terminal: anytype, name: []const u8, result: TestResult) !void { ... }
   pub fn writeStackTrace(terminal: anytype, stack_trace: std.builtin.StackTrace) !void { ... }
   ```

2. **Update test runner**
   - Replace `TreeNest` usage with `BufferedTerminal`
   - Replace `Dank` helpers with new helper functions  
   - Maintain exact same output format for compatibility

### Phase 4: Stack Trace Migration (Week 4)
**Goal**: Convert stack trace dumping

1. **Create stack trace helpers**
   ```zig
   // src/lib/terminal/StackTraceHelpers.zig  
   pub fn writeSourceBlock(terminal: anytype, code: []const u8, highlight_line: ?u64, highlight_col: ?u64) !void { ... }
   pub fn writeStackFrame(terminal: anytype, file: []const u8, line: u64, col: u64, func: []const u8) !void { ... }
   ```

2. **Update libansi.zig functions**
   - Convert `dumpConciseStackTrace()` to use new API
   - Maintain visual output format

### Phase 5: General Usage Migration (Week 5)
**Goal**: Convert remaining usage sites

1. **Create migration helpers**
   ```zig
   // Temporary compatibility shims
   pub fn legacyInfo(terminal: anytype, message: []const u8) !void {
       try terminal.helpers.writeInfo(terminal, message);
   }
   ```

2. **Convert each usage site**
   - Replace `trace.info()`, `trace.note()` calls
   - Update import statements  
   - Test each conversion

### Phase 6: Cleanup (Week 6)
**Goal**: Remove old system

1. **Remove deprecated files**
   - [ ] Delete `src/lib/treenest.zig` (650 lines removed)
   - [ ] Delete `src/lib/dank.zig` (471 lines removed)  
   - [ ] Update `src/lib/AnsiWriter.zig` (remove redundant parts)

2. **Clean up imports**
   - Remove deprecated exports from `libansi.zig`
   - Update all import statements
   - Remove compatibility shims

3. **Final testing**
   - Run full test suite
   - Visual regression testing for output formats
   - Performance benchmarking

## Risk Mitigation

### Compatibility Risks
- **Risk**: Output format changes break automation/scripts
- **Mitigation**: Exact format preservation during migration, extensive testing

### Performance Risks  
- **Risk**: New system slower than old system
- **Mitigation**: Benchmarking at each phase, optimize BufferedTerminal buffer sizes

### Integration Risks
- **Risk**: Build system issues with new module structure
- **Mitigation**: Gradual integration, maintain old system until fully migrated

## Success Criteria

1. **Code Quality**
   - [ ] Reduce total lines of code by >50% (current: ~1400 lines, target: <700)
   - [ ] All components have >90% test coverage
   - [ ] Zero allocation in core hot paths (tracing)

2. **API Quality**
   - [ ] Simple APIs: core components have <10 public methods each
   - [ ] Composable: can mix and match components easily
   - [ ] Consistent error handling throughout

3. **Performance**
   - [ ] No performance regression in tracing benchmarks
   - [ ] Memory usage reduced (no allocations in core paths)
   - [ ] Build time not significantly impacted

4. **Maintainability**
   - [ ] Clear separation of concerns
   - [ ] Easy to add new domain-specific helpers
   - [ ] Comprehensive documentation and examples

## Timeline Summary

- **Week 1**: Foundation established ✅
- **Week 2**: Tracing API replacement
- **Week 3**: Test runner migration  
- **Week 4**: Stack trace migration
- **Week 5**: General usage migration
- **Week 6**: Cleanup and removal of old system

Total effort: ~6 weeks for complete migration while maintaining compatibility.