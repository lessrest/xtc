# Repository Guidelines

## Project Structure

- `src/`: Zig sources. Inline unit tests live next to code; broader integration tests live under `src/test/`.
- `demos/`, `web/`, `deps/`, `scripts/`: Examples, web demo, vendored deps, and utilities. See `README.md` for current details.
- Build outputs go to `zig-out/`. Build steps and options are defined in `build.zig`.

## Build, Test, Develop

- Bootstrap: `./scripts/setup.sh` installs the expected Zig and Bun if needed and runs an initial `zig build`.
- Build: `TERM=dumb ZIG_NO_PROGRESS=1 zig build --summary new` for a clean, non-interactive log (`TERM=dumb` and `ZIG_NO_PROGRESS` disable terminal control sequences). `ZIG_NO_PROGRESS=1 make` maps to this.
- Test: `TERM=dumb ZIG_NO_PROGRESS=1 zig build test --summary new` runs inline + integration tests. `ZIG_NO_PROGRESS=1 make test` maps to this.
- Run: after building, use `zig-out/bin/xtc` (see `--help` and `README.md` for flags and examples).

## Coding Style

- Target Zig 0.15.1. Format with `zig fmt` before committing.
- Prefer small, focused modules and clear names; keep helpers in `src/lib/` when shared.
- Keep diffs tight and avoid drive‑by refactors in unrelated areas.
- For Wren code, avoid single-line control flow like `if (...) return x`; use braces and newlines for all blocks.

## Testing

- Integration tests belong in `src/test/` as `*.test.zig` and should exercise end‑to‑end behavior. Keep them semantic and concise.
- Unit‑level checks belong inline in modules using `test { ... }` blocks.

## Commits & PRs

- Use imperative, descriptive commit messages. Group related changes.
- For PRs: explain the rationale and user impact, link issues when relevant, and include a brief test plan. Ensure `zig build` and `zig build test` pass locally.

## Notes

- Avoid committing secrets or machine‑specific settings. When in doubt, prefer what `README.md` and `build.zig` currently document.
