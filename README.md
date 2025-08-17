## XTC

Experimental terminal UI compositor and layout engine in Zig. It renders a DOM
(hand-built or parsed from XML) using Tailwind-like utility classes into an ANSI
TTY, with a flexbox-inspired layout model, grapheme-aware text shaping, and a
compact paint/display-list pipeline.

### Highlights

- **DOM + styles**: Small DOM with style interning for deduplication
  (`src/dom.zig`, `src/style.zig`).
- **Tailwind-like classes**: Parse utility-class strings into a compact
  `StyleRow` (`src/tailwind.zig`). Includes flexbox subset, spacing, borders,
  width/height sizing, and a color palette defined via OKLCH/converted to sRGB.
- **Flex layout (subset)**: One-pass, row/column flex layout with justify/align,
  grow distribution, and stable order (`src/layout.zig`).
- **Text shaping for TTY**: Grapheme cluster iteration and display-width
  measurement for monospaced terminals (via `zg` dependency).
- **Paint pipeline**: Device-independent display list → ASCII/Unicode raster →
  minimal ANSI diff writer (`src/paint.zig`, `src/tty.zig`).
- **XML input (optional)**: Spec-compliant XML parser (derived from `zig-xml`)
  to build a DOM from markup (`src/xmlparse.zig`, `src/xml.zig`).
- **Live demo**: An interactive, raw-mode line editor rendering to an alternate
  screen buffer to showcase incremental redraw (`src/live.zig`, `src/main.zig`).
- **Embedded Wren scripting**: Lightweight scripting language for dynamic DOM
  manipulation and interactive behavior (`src/wren.zig`, `src/wren_runner.zig`).

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
- A simple UI driven by `src/live.zig` is rendered with flexbox-like layout.
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
from the `class` attribute. See the example XML files in the repo:

- `simple-flex.xml`
- `nested-flex.xml`
- `text-cards.xml`

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
rasterize to ASCII. See `src/lib.zig` tests for end-to-end examples.

## Wren Scripting

XTC embeds the Wren scripting language for dynamic DOM manipulation. Scripts can be embedded directly in XML documents using `<script>` tags and are executed during document construction.

### How it works

1. **Wren VM Integration**: The Zig wrapper (`src/wren.zig`) provides:

   - Memory management with tracked allocations
   - Automatic FFI generation from Zig structs
   - Type-safe bindings between Wren and Zig
   - Error handling and stack management

2. **DOM Bindings**: Scripts can manipulate the DOM through foreign functions:

   - Create elements with styles: `DOM.createElement("flex w-10")`
   - Create text nodes: `DOM.createText("Hello")`
   - Append children: `DOM.appendChild(parent, child)`
   - Access the root element: `DOM.root()`

3. **Script Context**: Each script has access to:

   - `self`: The element containing the script
   - `document`: Global document object with helper methods
   - DOM manipulation functions via the `DOM` class

4. **XML Integration**: When parsing XML with embedded scripts:
   - Scripts are extracted from `<script>` elements
   - Each script runs in a sandboxed context with access to its parent element
   - Scripts execute in document order during parsing
   - Errors are caught and reported without crashing the parser

### Example with Wren script

```xml
<?xml version="1.0" standalone="yes"?>
<root class="flex flex-col">
    <script>
        // Create dynamic content
        var box = document.createElement("w-20 h-4 bg-blue-500")
        self.append(box)

        var text = document.createText("Generated by Wren!")
        box.append(text)
    </script>
</root>
```

### Implementation details

The Wren integration uses compile-time reflection to automatically generate:

- Foreign method bindings from Zig function signatures
- Type conversions between Wren and Zig types
- Module and class definitions in Wren from Zig structs

This approach minimizes boilerplate while maintaining type safety across the language boundary.

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

1. XML (optional) → `Document` (`src/xmlparse.zig`) → DOM (`src/xml.zig`,
   `src/dom.zig`)
2. Styles are interned per unique `StyleRow` (`src/style.zig`) parsed from
   classes (`src/tailwind.zig`).
3. Layout builds a `BoxTree` and computes rects using a flexbox-like algorithm
   (`src/layout.zig`).
4. Paint emits device-independent ops: backgrounds, borders, text runs
   (`src/paint.zig`).
5. TTY backend rasterizes to ASCII/Unicode and emits minimal ANSI diffs
   (`src/tty.zig`, used by `src/live.zig`).
6. Wren scripts embedded in XML `<script>` tags can manipulate the DOM
   dynamically during document construction.

Key modules:

- `src/dom.zig` — DOM and style table
- `src/style.zig` — style data model
- `src/tailwind.zig` — class parser and emitter
- `src/layout.zig` — flex-like layout engine
- `src/measure.zig` — intrinsic sizing/text measurement helpers
- `src/paint.zig` — display list + text shaping
- `src/tty.zig` — raster and ANSI renderer
- `src/xmlparse.zig`, `src/xml.zig` — XML parsing and DOM mapping
- `src/live.zig`, `src/main.zig` — interactive demo CLI
- `src/wren.zig` — Wren VM Zig wrapper with FFI generation
- `src/wren_runner.zig` — Script runner with DOM integration
- `src/wren_xml.zig` — XML-to-DOM builder with script execution
- `src/wren_wrappers/` — Wren-side DOM manipulation helpers

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

See in-code TODOs, e.g., `src/measure.zig`.

## Licensing and attribution

- The entirety of `src/xmlparse.zig` is derived from `zig-xml` by Meghan Denny
  (MPL-2.0). See `ATTRIBUTION.md` and `LICENSES/MPL-2.0.txt`.
- Other code in this repository may be under different terms; consult the
  repository’s `LICENSES/` and file headers.
