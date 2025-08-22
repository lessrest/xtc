Zig 0.15 Migration Plan (xtc + deps/zg)

Overview

- New std.Io.Reader/Writer: concrete ring-buffered interfaces with vtable below the buffer. Old generic readers/writers are deprecated.
- Adapter API: old streams can be wrapped via `adaptToNewApi(&.{})` to get a `*std.Io.Reader`/`*std.Io.Writer`.
- std.fs.File.Reader/Writer: concrete types that memoize file state and fulfill the new interfaces.
- Printing: `std.io.getStdOut().writer().print()` replaced by buffered `std.fs.File.stdout().writer(&buf)`; use `&state.interface` and remember to `flush()`.
- Flate rework: `std.compress.flate` redesigned; compression removed; decompression via `std.compress.flate.Decompress` producing a new `*std.Io.Reader`.
- Language/library churn: `usingnamespace` removed; formatting API changes; ArrayList default unmanaged.

Scope: migrate both `deps/zg` and `xtc` to Zig 0.15.1, with a focus on I/O changes and any language/library removals that affect this repo.

References

- 0.15.1 release notes: Writergate, Adapter API, New Reader/Writer API, std.fs.File.Reader/Writer, printing upgrade, flate changes.

Plan of Record

1) Toolchain bump
- Update scripts and docs to install/use Zig 0.15.x.
- Verify build options and targets (musl default still OK; see OS minimums in release notes).

2) I/O migration strategy
- Readers/Writers are no longer generic; callers supply the buffer; use `&state.interface` to obtain `*std.Io.Reader`/`*std.Io.Writer`.
- For legacy producers (e.g., `std.io.fixedBufferStream(...).reader()`), use the Adapter API: `var a = old.reader().adaptToNewApi(&.{}); const r: *std.Io.Reader = &a.new_interface;` until native 0.15 helpers exist.
- Prefer new `std.fs.File.Reader`/`Writer` for file handles: `var state = file.reader(&buf); const r: *std.Io.Reader = &state.interface;` and symmetric for writing.
- Replace `readUntilDelimiterOrEof` usages with the new `takeDelimiterExclusive` loop and updated error handling.

3) deps/zg specifics
- Zstd data path: continue building `.zst` artifacts and embedding them.
- Reader creation from embedded bytes now uses a shared helper module `zstdembed` that yields a `*std.Io.Reader` over decompressed bytes.
  - For Zig 0.15, update the helper to construct and expose a `*std.Io.Reader` using the new API surface. Examples to target:
    - File reader pattern: `var rstate = file.reader(&buf); const r: *std.Io.Reader = &rstate.interface;`
    - Flate example in notes: `var decomp: std.compress.flate.Decompress = .init(reader, .zlib, &buf); const r: *std.Io.Reader = &decomp.reader;`
  - If zstd exposes a `.reader` field (similar to flate), prefer `&dz.reader`; otherwise adapt.
- Replace all `buf.reader()` usages with either:
  - zstdembed-created `*std.Io.Reader`, or
  - for non-compressed `fixedBufferStream`, adapt old reader: `var a = fbs.reader().adaptToNewApi(&.{}); const r = &a.new_interface;`.
- Remove `std.io.bufferedReader` and `std.io.bufferedWriter` – the buffer is now part of the Reader/Writer interface.
- Audit for remaining `std.compress.flate` usage – none expected after zstd switch.

4) xtc specifics
- Standard output printing:
  - Before: `std.io.getStdOut().writer().print(...)`.
  - After: allocate a buffer and use `std.fs.File.stdout().writer(&buf)`:
    - `var buf: [1024]u8 = undefined;`
    - `var wstate = std.fs.File.stdout().writer(&buf);`
    - `const out: *std.Io.Writer = &wstate.interface;`
    - `try out.print("...", .{});`
    - `try out.flush();`
- File reads/writes: migrate to `std.fs.File.Reader/Writer` as above; eliminate `bufferedReader`/`bufferedWriter`.
- Adapter usage: for any APIs still returning old readers/writers (3rd-party or older std helpers), apply `adaptToNewApi(&.{})`.

5) Language updates impacting repo
- `usingnamespace` removal:
  - Current usage: `src/lib/libansi.zig`.
  - Migration options:
    - Create a container that explicitly re-exports needed decls:
      ```zig
      pub const Ansi = @import("AnsiWriter.zig");
      pub const TreePrinter = @import("TreePrinter.zig");
      // update imports at call sites to use libansi.Ansi, libansi.TreePrinter
      ```
    - Or build a wrapper struct with `pub usingnamespace` replaced by explicit `pub const`/`pub fn` shims.
- Formatting changes:
  - If any custom `format` methods exist, add `{f}` when invoking them; adjust to the simplified options API per notes.
  - Formatted printing no longer performs Unicode processing; ensure call sites don’t rely on it.
- ArrayList default unmanaged:
  - If code relied on managed flavor by default, switch to `ArrayListManaged` or initialize unmanaged explicitly with allocator where needed.

6) Compile & test
- zig build (xtc root) should generate `.zst` for zg and embed; confirm no reliance on removed APIs.
- zig build test – ensure passing (30+ tests currently pass on 0.14).

7) Cleanup
- Remove any dead compatibility code (e.g., temporary adapters) once everything uses the new interfaces directly.
- Update README.md with the Zig version bump and brief note on the zstd and I/O changes.

File-by-File Touch List (anticipated)

- deps/zg/src/lib/zstd_embed.zig: update to expose `*std.Io.Reader` for 0.15 (may change `.reader()` → `.reader` field or use adapter).
- deps/zg/src/*: switch all places that read embedded data to use `zstdembed.open(...)` result and a `*std.Io.Reader`.
- src/lib/libansi.zig: replace `usingnamespace` with explicit exports.
- src/*: update printing to use new writer pattern where applicable; remove any uses of `std.io.bufferedReader/Writer`.

Code Patterns (0.15.1)

- File read:
  ```zig
  var buf: [4096]u8 = undefined;
  var rstate = file.reader(&buf);
  const r: *std.Io.Reader = &rstate.interface;
  while (r.takeDelimiterExclusive('\n')) |line| { /* ... */ }
  ```

- Stdout write:
  ```zig
  var buf: [1024]u8 = undefined;
  var wstate = std.fs.File.stdout().writer(&buf);
  const out: *std.Io.Writer = &wstate.interface;
  try out.print("hello: {s}\n", .{"world"});
  try out.flush();
  ```

- Old → New adapter:
  ```zig
  var old = std.io.fixedBufferStream(bytes).reader();
  var a = old.adaptToNewApi(&.{});
  const r: *std.Io.Reader = &a.new_interface;
  ```

- Flate decompression (for reference):
  ```zig
  var zbuf: [std.compress.flate.max_window_len]u8 = undefined;
  var decomp: std.compress.flate.Decompress = .init(reader, .zlib, &zbuf);
  const r: *std.Io.Reader = &decomp.reader;
  ```

Risks & Mitigations

- Widespread breakage from I/O changes: stage work in small PRs per module and rely on adapters temporarily.
- `usingnamespace` removal: fix early to reduce churn.
- External tools/CI images pinned to 0.14: update our bootstrap (`scripts/setup.sh`) first.

Checklist

- [ ] Bump toolchain to 0.15.1; verify local builds.
- [ ] Replace `usingnamespace` in `src/lib/libansi.zig`.
- [ ] Update `zstdembed` to produce `*std.Io.Reader` with 0.15 API.
- [ ] Migrate zg readers to use `zstdembed` + new Reader methods.
- [ ] Update stdout/file printing in xtc to new API; add flush.
- [ ] Replace any bufferedReader/Writer usage.
- [ ] Audit formatting calls for `{f}` and spec changes.
- [ ] Run `zig build` and `zig build test`; fix regressions.

