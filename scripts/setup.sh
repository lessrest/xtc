#!/usr/bin/env bash

# Setup script for xtc
# - Ensures Zig 0.14.1 is available (downloads portable build locally if needed)
# - Adds local vendor/zig to PATH via ~/.bashrc if not already present
# - Ensures git submodules are initialized (depth 1)

set -euo pipefail

REQUIRED_ZIG_VERSION="0.14.1"
ZIG_TARBALL_URL="https://ziglang.org/download/${REQUIRED_ZIG_VERSION}/zig-x86_64-linux-${REQUIRED_ZIG_VERSION}.tar.xz"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Try to use git to find repo root; fallback to script_dir/.. if not a git repo
if repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null); then
  REPO_ROOT="$repo_root"
else
  REPO_ROOT="$(cd "$script_dir/.." && pwd)"
fi

VENDOR_DIR="$REPO_ROOT/vendor"
mkdir -p "$VENDOR_DIR"

info() { echo -e "[setup] $*"; }
warn() { echo -e "[setup] WARNING: $*" >&2; }
die()  { echo -e "[setup] ERROR: $*" >&2; exit 1; }

have_required_zig=0
if command -v zig >/dev/null 2>&1; then
  zig_ver="$(zig version 2>/dev/null || echo "")"
  if [[ "$zig_ver" == "$REQUIRED_ZIG_VERSION" ]]; then
    have_required_zig=1
    info "Found system zig $zig_ver on PATH"
  else
    info "Found zig $zig_ver on PATH, but need $REQUIRED_ZIG_VERSION"
  fi
else
  info "zig not found on PATH"
fi

# Download/extract local Zig if needed
if [[ "$have_required_zig" -ne 1 ]]; then
  tarball_name="zig-x86_64-linux-${REQUIRED_ZIG_VERSION}.tar.xz"
  tarball_path="$VENDOR_DIR/$tarball_name"
  extracted_dir_name="zig-x86_64-linux-${REQUIRED_ZIG_VERSION}"
  extracted_dir_path="$VENDOR_DIR/$extracted_dir_name"
  target_link_version="$VENDOR_DIR/zig-${REQUIRED_ZIG_VERSION}"
  target_link_latest="$VENDOR_DIR/zig"

  if [[ ! -d "$extracted_dir_path" ]]; then
    info "Fetching Zig ${REQUIRED_ZIG_VERSION} portable toolchain..."
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail --retry 3 -o "$tarball_path" "$ZIG_TARBALL_URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$tarball_path" "$ZIG_TARBALL_URL"
    else
      die "Neither curl nor wget is available to download $ZIG_TARBALL_URL"
    fi

    info "Extracting $tarball_name into $VENDOR_DIR"
    tar -xJf "$tarball_path" -C "$VENDOR_DIR"
  else
    info "Zig archive already extracted at $extracted_dir_path"
  fi

  # Create/refresh symlinks for stable paths
  ln -sfn "$extracted_dir_path" "$target_link_version"
  ln -sfn "$target_link_version" "$target_link_latest"
  info "Local Zig available at $target_link_latest (-> $(readlink -f "$target_link_latest"))"

  # Add to PATH via ~/.bashrc if missing
  abs_vendor_zig="$target_link_latest"
  bashrc="$HOME/.bashrc"
  export_line="export PATH=\"$abs_vendor_zig:\$PATH\""
  if [[ -f "$bashrc" ]] && grep -Fq "$abs_vendor_zig" "$bashrc"; then
    info "~/.bashrc already contains vendor Zig path"
  else
    info "Adding vendor Zig path to ~/.bashrc"
    {
      echo ""
      echo "# Added by xtc/scripts/setup.sh on $(date +%F)"
      echo "$export_line"
    } >> "$bashrc"
    info "To use immediately in current shell: source \"$bashrc\" or export PATH=\"$abs_vendor_zig:\$PATH\""
  fi

  # Verify the newly installed Zig runs and reports the expected version
  vendor_zig_bin="$abs_vendor_zig/zig"
  if [[ ! -x "$vendor_zig_bin" ]]; then
    die "Vendor zig binary not found or not executable at $vendor_zig_bin"
  fi
  installed_ver="$($vendor_zig_bin version 2>/dev/null || true)"
  if [[ "$installed_ver" != "$REQUIRED_ZIG_VERSION" ]]; then
    die "Vendor zig reported version '$installed_ver', expected '$REQUIRED_ZIG_VERSION'"
  fi
  info "Verified vendor zig $installed_ver runs successfully"
fi

# Ensure vendor dir is gitignored
gitignore="$REPO_ROOT/.gitignore"
if [[ -f "$gitignore" ]]; then
  if ! grep -Fq "/vendor/" "$gitignore"; then
    echo "/vendor/" >> "$gitignore"
    info "Added /vendor/ to .gitignore"
  fi
else
  echo "/vendor/" > "$gitignore"
  info "Created .gitignore with /vendor/ entry"
fi

# Initialize / update git submodules with depth 1
if [[ -d "$REPO_ROOT/.git" ]]; then
  if [[ -f "$REPO_ROOT/.gitmodules" ]]; then
    info "Initializing/updating git submodules (depth 1)"
    git -C "$REPO_ROOT" submodule update --init --recursive --depth 1 --jobs 4
  else
    info "No .gitmodules found; skipping submodule init"
  fi
else
  warn "Not a git repository (no .git directory); skipping submodule init"
fi

# Ensure Bun is installed
if ! command -v bun >/dev/null 2>&1; then
  info "bun not found on PATH; installing via bun.sh"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://bun.sh/install | bash
  else
    warn "curl not available; skipping bun install"
  fi

  bun_install_dir="${BUN_INSTALL:-$HOME/.bun}"
  bun_bin="$bun_install_dir/bin/bun"
  if [[ -x "$bun_bin" ]]; then
    info "Installed bun at $bun_bin"
    bun_ver="$($bun_bin --version 2>/dev/null || true)"
    if [[ -n "$bun_ver" ]]; then
      info "Verified bun $bun_ver runs successfully"
    fi

    # Ensure bun path is in ~/.bashrc for subsequent shells
    bashrc="$HOME/.bashrc"
    bun_export_line='export BUN_INSTALL="$HOME/.bun"; export PATH="$BUN_INSTALL/bin:$PATH"'
    if [[ -f "$bashrc" ]] && grep -Fq 'BUN_INSTALL' "$bashrc"; then
      info "~/.bashrc already contains bun path"
    else
      info "Adding bun path to ~/.bashrc"
      {
        echo ""
        echo "# Added by xtc/scripts/setup.sh on $(date +%F)"
        echo "$bun_export_line"
      } >> "$bashrc"
      info "To use bun immediately in this shell: export BUN_INSTALL=\"$HOME/.bun\"; export PATH=\"$HOME/.bun/bin:$PATH\""
    fi
  else
    warn "bun install script ran, but bun not found at $bun_bin"
  fi
else
  info "Found bun on PATH ($(command -v bun))"
fi

# Perform an initial build to warm caches and verify the toolchain
zig_bin="$(command -v zig 2>/dev/null || true)"
if [[ -z "$zig_bin" ]]; then
  zig_candidate="$VENDOR_DIR/zig/zig"
  if [[ -x "$zig_candidate" ]]; then
    zig_bin="$zig_candidate"
  fi
fi
if [[ -n "$zig_bin" ]]; then
  info "Running initial zig build"
  (cd "$REPO_ROOT" && ZIG_NO_PROGRESS=1 "$zig_bin" build --summary new)
else
  warn "zig not found; skipping initial build"
fi

info "Setup complete."
