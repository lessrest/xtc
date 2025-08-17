# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

XTC is an experimental terminal UI compositor and layout engine written in Zig. It renders DOM structures (XML or programmatic) using Tailwind-like utility classes into ANSI terminal output, featuring a flexbox-based layout system and grapheme-aware text rendering.

## Build and Development Commands

```bash
# Build the project (creates zig-out/bin/xtc)
zig build

# Run all tests
zig build test

# Run the interactive demo
zig-out/bin/xtc --log xtc.log

# Test XML rendering (non-interactive)
zig-out/bin/xtc --xml '<root class="flex"><box class="w-4 h-2 bg-glyph-[a]"/></root>' --width 80 --height 24

# Debug mode with automatic trace formatting
zig-out/bin/xtc --log xtc.log --debug

# Install to local bin (optional)
make install
```

## Architecture Overview

The codebase follows a clean pipeline architecture:

**XML/DOM → Style → Layout → Paint → Raster → ANSI**

### Core Pipeline Components

1. **DOM & Styles** (`src/dom.zig`, `src/style.zig`)

   - Lightweight DOM with parent-child relationships
   - Style interning via `StyleTable` for memory efficiency
   - All styles stored in deduplicated `StyleRow` structs

2. **Tailwind Parser** (`src/tailwind.zig`)

   - Parses utility classes into `StyleRow` properties
   - Supports flexbox, sizing, spacing, borders, colors
   - OKLCH→sRGB color conversion for Tailwind palette

3. **Layout Engine** (`src/layout.zig`)

   - One-pass flexbox algorithm with grow distribution
   - Uses `BoxTree` (breadth-first construction for cache locality)
   - Integrates text measurement via `src/measure.zig`

4. **Paint System** (`src/paint.zig`)

   - Generates device-independent display list
   - Commands: `FillRect`, `StrokeRect`, `GlyphRun`
   - RGBA blending with Porter-Duff composition

5. **TTY Backend** (`src/tty.zig`)
   - Rasterizes to 2D grid with glyph interning
   - Minimal ANSI diff output for efficient updates
   - Unicode box-drawing character support

### Key Data Structures

- **Node**: DOM element stored in `MultiArrayList` for cache efficiency
- **StyleRow**: Packed struct containing all CSS-like properties
- **BoxTree**: Specialized `ContiguousTree` for layout data
- **Raster**: 2D grid of cells with glyph+color information
- **GlyphTable**: UTF-8 grapheme interning (0-255 reserved for ASCII)

## Testing Strategy

Tests are integrated in `src/lib.zig` using the `expectLayout()` helper that compares expected vs actual ASCII output.

```bash
# Run all tests
zig build test

# To add a test, follow the pattern in src/lib.zig
# Use bg-glyph-[x] utility classes for visual debugging
```

## Important Implementation Notes

### Memory Management

- Arena allocation for transient data
- Style and glyph interning for deduplication
- Single text arena in DOM for all text content

### Unicode Text Handling

- Uses `zg` library for grapheme clustering
- Proper display width calculation for CJK/emoji
- Grapheme-aware editing in live demo

### Performance Considerations

- Breadth-first BoxTree construction for cache locality
- Style interning reduces memory footprint
- Single-pass layout algorithm
- Minimal ANSI output via diffing

### Current Limitations

- Flexbox subset only (no shrink, wrap, or multi-line)
- Basic text rendering
- Breaking changes expected (research project)

## Common Development Tasks

### Adding New Utility Classes

1. Update parser in `src/tailwind.zig`
2. Add corresponding fields to `StyleRow` in `src/style.zig`
3. Implement layout behavior in `src/layout.zig`
4. Add paint commands if needed in `src/paint.zig`
5. Write tests in `src/lib.zig`

### Debugging Layout Issues

- Use `bg-glyph-[x]` classes to visualize element boundaries
- Check `xtc.log` for trace output (when using `--log`)
- Run tests with specific XML to isolate issues

### Debug Tracing

- Use `--debug` flag to enable automatic trace log formatting on exit
- Raw XML trace logs are written to the file specified by `--log` (default: `xtc.log`)
- The formatted output provides structured, hierarchical view of the rendering pipeline
- Data groups (created via `span.data("label").put().put().end()`) are displayed with 📊 icons
- Trace spans show the call hierarchy with ▶ markers and decisions with ⚡ markers

### Wren Scripting Integration

- **Wren VM**: Embedded scripting language for dynamic behavior
- Wren sources are in `deps/wren/`
- Zig wrapper in `src/wren.zig` and `src/wren_runner.zig`
- DOM manipulation via `src/wren_xml.zig`
- Foreign function bindings in `src/wren_wrappers/`
- Static build configuration in `build.zig`
