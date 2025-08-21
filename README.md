## XTC

Experimental terminal UI compositor and layout engine in Zig. It renders a DOM
(hand-built or parsed from XML) using Tailwind-like utility classes into an ANSI
TTY, with a flexbox-inspired layout model, grapheme-aware text shaping, and a
compact paint/display-list pipeline.

### Highlights

- **DOM + styles**: Small DOM with style interning for deduplication.
- **Tailwind-like classes**: Parse utility-class strings into a compact style
  representation. Includes flexbox subset, spacing, borders, width/height
  sizing, and a color palette defined via OKLCH/converted to sRGB.
- **Flex layout (subset)**: One-pass, row/column flex layout with justify/align
  and grow distribution.
- **Text shaping for TTY**: Grapheme-aware display-width measurement for
  monospaced terminals.
- **Paint pipeline**: Device-independent display list → ASCII/Unicode raster →
  minimal ANSI diff writer.
- **XML input (optional)**: Spec-compliant XML parser to build a DOM from
  markup.
- **Live demo**: An interactive, raw-mode line editor rendering to an alternate
  screen buffer to showcase incremental redraw.
- **Embedded scripting**: The original Wren integration is being replaced by a
  new Fiberscript runtime built on cooperative fibers.

### Status

This is a research/toy project. The layout and styling model intentionally
implements a small, coherent subset. Expect breaking changes.

## Quick start

### Prerequisites

- Zig 0.14.x (see `.minimum_zig_version` in `build.zig.zon`)
- No external C toolchain is required. Wren's C sources are built via Zig's
  own C toolchain during `zig build`.
- macOS or Linux terminal

Optional (already vendored):

- `deps/wren` is included as a submodule/vendor. If you cloned without
  submodules, run:

```sh
git submodule update --init --recursive
```

### Build

```sh
# From the repo root
zig build           # Debug build
zig build test      # Run unit tests
```

Artifacts are placed under `zig-out/`. The CLI binary is `zig-out/bin/xtc`.

### Run the demo

```sh
zig-out/bin/xtc --log xtc.log   # optional log file (default: xtc.log)
```

What you should see:

  - The app switches to the terminal's alternate screen and hides the cursor.
  - A simple UI is rendered with flexbox-like layout.
  - Basic line editing works (grapheme-aware input, history, arrows, Home/End,
    Delete, Ctrl-A/E/B/F/K/D/C). Exit with Ctrl-D on an empty line.

### Non-interactive XML rendering (for testing)

The CLI can also render an XML string to stdout and exit. This is useful for
tests and quick checks.

```sh
zig-out/bin/xtc --xml '<root class="flex"><box class="w-4 h-2 bg-glyph-[a]"/></root>' --width 8 --height 4
```

Expected shape (letters indicate filled cells):

```
aaaa
aaaa


```

## Using XML + classes

XTC can parse XML and map elements to DOM nodes, reading Tailwind-like classes
from the `class` attribute. Example XML files live in the repository.

Example (`simple-flex.xml`):

```xml
<?xml version="1.0" standalone="yes"?>
<root class="flex flex-row">
    <box class="w-10 h-3 border"/>
    <box class="w-6  h-3 border"/>
    <box class="w-4  h-3 border"/>
    <box class="w-8  h-3 border"/>
</root>
```

Library usage mirrors the test helper: parse XML → build DOM → layout → paint →
rasterize to ASCII.

## Scripting runtime

XTC embeds a lightweight scripting language for dynamic DOM manipulation. The
original implementation uses Wren, but a new Fiberscript runtime is actively
replacing it to provide cooperative fibers and batched syscalls. During the
transition both systems coexist, with Fiberscript taking an increasingly central
role. Documentation for the new runtime lives alongside its source.

## Supported utility classes (subset)

- **Display**: `flex`, `block`, `inline`, `inline-flex`
- **Direction**: `flex-row`, `flex-col`, `flex-row-reverse`, `flex-col-reverse`
- **Sizing (cells)**: `w-N`, `h-N` (use these; `flex-basis` is treated as auto
  and not exposed)
- **Grow**: `grow`, `grow-N`, `flex-1` (grow:1, shrink:1)
- **Borders**: `border`, `border-N` (width)
- **Justify content**: `justify-start`, `justify-end`, `justify-center`,
  `justify-between`, `justify-around`, `justify-evenly`
- **Align items**: `items-start`, `items-end`, `items-center`, `items-stretch`,
  `items-baseline`
- **Align self**: `self-start`, `self-end`, `self-center`, `self-stretch`
- **Padding**: `p-N`, `px-N`, `py-N`, `pl-N`, `pr-N`, `pt-N`, `pb-N`
- **Colors**: `text-…`, `bg-…`, `border-…` using Tailwind-like palette tokens
  (OKLCH → sRGB)
- **Test helper**: `bg-glyph-[x]` fills the border-box with glyph `x` (e.g.,
  `bg-glyph-[a]`)

Notes:

- Numeric units are terminal cells.

## Architecture in brief

1. Optional XML input is parsed into a DOM representation.
2. Styles are interned per unique class combination.
3. A flexbox-inspired layout engine builds a box tree and computes rectangles.
4. A paint stage emits device-independent operations such as backgrounds,
   borders and text runs.
5. The TTY backend rasterizes to ASCII/Unicode and writes minimal ANSI diffs.
6. Scripts embedded in XML `<script>` tags can manipulate the DOM during
   document construction.

## Development

### Common tasks

```sh
zig build           # build library and xtc CLI
zig build test      # run unit tests
make install        # optional: copy CLI to bin/xtc
```

CLI flags:

- `--log <file>`: append logs to file (default: `xtc.log`)
- `--xml <string>`: render the provided XML into ASCII and print to stdout, then
  exit
- `--width N`, `--height N`: viewport size for `--xml` mode (defaults 80x24)
- `--unicode-boxes` / `--no-unicode-boxes`: prefer Unicode box-drawing glyphs
  for borders (default on)
- `-h`, `--help`

### Border styles (Tailwind-like)

- `border` / `border-N`: sets border width in cells.
- `border-solid`, `border-double`, `border-dashed`: choose line styles. Line
  styles render with Unicode box drawing by default; ASCII is used when
  `--no-unicode-boxes` is set.
- `border-block`: non-CSS extension; draws borders as filled blocks using
  background fills of the specified border color.

## Roadmap (selected)

- Flexbox completeness: shrink, wrap, multi-line align-content, min/max
  constraints
- Rich text: whitespace modes, wrapping strategies, ellipsis
- Overflow clipping and z-index paint ordering
- Performance: arenas, caching, fewer allocations in hot paths

See in-code TODOs for additional ideas and areas of work.

## Licensing and attribution

- The XML parser is derived from `zig-xml` by Meghan Denny (MPL-2.0). See
  `ATTRIBUTION.md` and `LICENSES/MPL-2.0.txt`.
- Other code in this repository may be under different terms; consult the
  repository’s `LICENSES/` and file headers.
