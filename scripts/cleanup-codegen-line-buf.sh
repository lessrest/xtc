#!/usr/bin/env bash
set -euo pipefail

# Remove legacy line buffer declarations from zg codegen files migrated to 0.15
# Matches: var line_buf: [4096]u8 = undefined;

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. >/dev/null 2>&1 && pwd)"
cd "$repo_root"

shopt -s nullglob
mapfile -t files < <(rg -l "^\s*var\s+line_buf:\s*\[4096\]u8\s*=\s*undefined;\s*$" deps/zg/codegen)

if ((${#files[@]})); then
  for f in "${files[@]}"; do
    sed -i -E '/^\s*var\s+line_buf:\s*\[4096\]u8\s*=\s*undefined;\s*$/d' "$f"
    echo "[cleanup] removed line_buf in $f"
  done
else
  echo "[cleanup] no matching line_buf declarations found"
fi

