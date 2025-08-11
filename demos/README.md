# XTC Demos

Collection of demos showcasing XTC's features.

## Running Demos

```bash
# From the project root after building:

# Run XML-based demos
zig-out/bin/xtc --xml demos/tetris_clock.xml --live

# Run standalone Wren scripts (no XML needed!)
zig-out/bin/xtc --wren demos/standalone_demo.wren
zig-out/bin/xtc --wren demos/clock_demo.wren --live
```

## Featured Demos

### Standalone Wren Scripts (No XML!)
- `standalone_demo.wren` - Creates entire UI from Wren code
- `clock_demo.wren` - Animated clock gallery built purely in Wren

### Games
- `tetris_clock.xml` - Tetris with clock-based timing (60 FPS drop timer)
- `tetris_simple.wren` - Simpler tetris without clock timing

### Animations
- `waves.xml` - 60 FPS wave animation (now actually runs at 60 FPS!)
- `orbit.xml` - Planets orbiting animation
- `starfield.xml` - Twinkling stars using clock pulses
- `matrix.xml` - Matrix rain effect
- `spiral.xml` - Spiral pattern

### Clock System Tests
- `test_clock.xml` - Various clock visual styles (spinner, progress, pulse, counter)
- `simple_spinner.xml` - Single 60 FPS spinner for performance testing
- `clock_grid.xml` - Grid of clocks

### Input Tests
- `test_keypress*.xml` - Various keyboard input handling demos

## Performance Note

The waves animation now runs at true 60 FPS after fixing the Words.init() bug that was decompressing the Unicode database on every text paint operation!