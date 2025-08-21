## XTC

Experimental terminal UI compositor and layout engine in Zig. It renders a DOM
(hand‑built or parsed from XML) using utility‑class style strings into an ANSI
TTY, with a flexbox‑inspired layout model and grapheme‑aware text shaping.

Status: active research; the surface may change.

## Quick Start

- Dependencies: Zig 0.14.x and a Unix‑like terminal. To bootstrap toolchains
  locally, run `./scripts/setup.sh`.

### Build and Test

```sh
# From the repo root
zig build --summary new            # build (Debug)
zig build test --summary new       # run tests
# or via Make
make                               # same as zig build --summary new
make test                          # same as zig build test --summary new
```

Artifacts are placed under `zig-out/` (CLI at `zig-out/bin/xtc`).

### Run

Interactive demo:

```sh
zig-out/bin/xtc --log xtc.log
```

Non‑interactive XML render (useful for testing):

```sh
zig-out/bin/xtc --xml '<root class="flex"><box class="w-4 h-2 bg-glyph-[a]"/></root>' --width 8 --height 4
```

## Development Notes

- Inline unit tests live beside Zig modules; broader integration tests live in
  `src/test/`.
- Web demo and WASM bindings live under `web/` with a Bun‑based build. See
  `build.zig` and comments in `web/` for details.

## Licensing and Attribution

- Portions derived from third‑party projects; see `ATTRIBUTION.md` and
  `LICENSES/` for terms.
