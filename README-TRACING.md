# XTC Tracing System

XTC includes a comprehensive structured tracing system that provides detailed insights into the rendering pipeline.

## Generating Traces

Enable tracing by using the `--log` option:

```bash
# Trace XML rendering to a log file
zig-out/bin/xtc --xml '<root class="flex"><box class="w-4 h-2 bg-glyph-[a]"/></root>' --log trace.log

# Trace interactive mode (creates xtc.log by default)
zig-out/bin/xtc --log xtc.log
```

## Trace Format

Traces are generated in structured XML format with hierarchical spans:

```xml
<span>
  <info>Operation description</info>
  <item key="width" value="10"/>
  <item key="height" value="5"/>
  <decision>Algorithm decision made</decision>
  <span>
    <info>Child operation</info>
    <!-- nested spans -->
  </span>
</span>
```

## Formatting Traces

Use the included XSL stylesheet to convert raw XML traces into readable text format:

```bash
# Format a trace log
./format-trace.sh trace.log formatted-trace.txt

# Uses trace.xsl to transform XML to clean text format
```

## Trace Content

The tracing system captures:

- **Layout Engine**: Flexbox calculations, item positioning, size distribution
- **Paint System**: Background fills, border strokes, glyph rendering
- **Interactive Events**: User input, command processing, rendering cycles
- **Performance Metrics**: Node counts, operation counts, timing data
- **Algorithm Decisions**: Why certain paths were taken, optimizations applied

## Example Output

```
▶ Rendering XML to ASCII
  • width: 10  
  • height: 5
  ▶ Computing flexbox layout for container
    • container rect: layout.Rect{ .x = 0, .y = 0, .w = 10, .h = 5 }
    ▶ Processing flex item
      ⚡ Overriding natural width with explicit width from style
      • index: 0
      • id: #1
  ▶ Computing paint commands for display list
    • node count: 2
    • final op count: 1
    ▶ Painting node
      ▶ Emitting glyph tile fill
        • glyph id: 97
        • color: 4278190080
```

## Advanced Usage

For custom processing, parse the XML directly or modify `trace.xsl` for different output formats. The XML structure is designed to be stable and machine-parseable for analysis tools.