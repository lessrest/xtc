# Integration Tests

This directory contains higher‑level verification of the project’s core
behaviors. Treat these as integration tests: scenarios that cross module
boundaries and validate that features work together (including rendering,
layout, CLI behavior, or scripting/runtime interactions). Unit tests for
individual modules should live inline within their Zig source files using
`test { ... }` blocks.

## Writing Tests

- Place new suites in files named `*.test.zig`.
- Keep tests semantic and concise. Favor describing observable behavior over
  implementation details.
- Use shared helpers in this directory to keep test bodies readable and
  high‑level.
- Prefer realistic inputs (small XML snippets, minimal scripts, or CLI args)
  with clear, easy‑to‑verify expectations.

## Running

- `zig build test --summary new` runs all integration and inline tests using
  the custom runner; artifacts go under `zig-out/`.
- Helpful environment variables:
  - `TEST_VERBOSE=true` for detailed output
  - `TEST_FAIL_FIRST=true` to stop on first failure
  - `TEST_FILTER=substring` to run a subset

As features land, grow this directory with additional suites that reflect
real‑world usage patterns and keep the tests expressive, minimal, and
maintainable.

