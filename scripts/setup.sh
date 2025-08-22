#!/usr/bin/env bash

# Setup script for xtc
# - Ensures Zig 0.14.1 is available (downloads portable build)
# - When run as root: installs globally to /usr/local/bin
# - When run as regular user: installs locally and adds vendor/zig to PATH via ~/.bashrc
# - Ensures git submodules are initialized (depth 1)
# - Sets TERM=dumb when running zig build

set -euo pipefail

REQUIRED_ZIG_VERSION="0.14.1"
ZIG_TARBALL_URL="https://ziglang.org/download/${REQUIRED_ZIG_VERSION}/zig-x86_64-linux-${REQUIRED_ZIG_VERSION}.tar.xz"

# Check if running as root
IS_ROOT=0
if [[ $EUID -eq 0 ]]; then
  IS_ROOT=1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Try to use git to find repo root; fallback to script_dir/.. if not a git repo
if repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null); then
  REPO_ROOT="$repo_root"
else
  REPO_ROOT="$(cd "$script_dir/.." && pwd)"
fi

# Set installation directory based on user privileges
if [[ $IS_ROOT -eq 1 ]]; then
  INSTALL_DIR="/usr/local"
  info() { echo -e "[setup] (root) $*"; }
else
  INSTALL_DIR="$REPO_ROOT/vendor"
  info() { echo -e "[setup] $*"; }
fi
mkdir -p "$INSTALL_DIR"

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

# Download/extract Zig if needed
if [[ "$have_required_zig" -ne 1 ]]; then
  tarball_name="zig-x86_64-linux-${REQUIRED_ZIG_VERSION}.tar.xz"
  tarball_path="$INSTALL_DIR/$tarball_name"
  extracted_dir_name="zig-x86_64-linux-${REQUIRED_ZIG_VERSION}"
  extracted_dir_path="$INSTALL_DIR/$extracted_dir_name"
  
  if [[ $IS_ROOT -eq 1 ]]; then
    target_link_version="$INSTALL_DIR/zig-${REQUIRED_ZIG_VERSION}"
    target_link_latest="$INSTALL_DIR/bin/zig"
    # Ensure /usr/local/bin exists
    mkdir -p "$INSTALL_DIR/bin"
  else
    target_link_version="$INSTALL_DIR/zig-${REQUIRED_ZIG_VERSION}"
    target_link_latest="$INSTALL_DIR/zig"
  fi

  if [[ ! -d "$extracted_dir_path" ]]; then
    info "Fetching Zig ${REQUIRED_ZIG_VERSION} portable toolchain..."
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail --retry 3 -o "$tarball_path" "$ZIG_TARBALL_URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$tarball_path" "$ZIG_TARBALL_URL"
    else
      die "Neither curl nor wget is available to download $ZIG_TARBALL_URL"
    fi

    info "Extracting $tarball_name into $INSTALL_DIR"
    tar -xJf "$tarball_path" -C "$INSTALL_DIR"
  else
    info "Zig archive already extracted at $extracted_dir_path"
  fi

  # Create/refresh symlinks for stable paths
  ln -sfn "$extracted_dir_path" "$target_link_version"
  
  if [[ $IS_ROOT -eq 1 ]]; then
    # For root, create a symlink from /usr/local/bin/zig to the actual binary
    ln -sfn "$extracted_dir_path/zig" "$target_link_latest"
    info "Global Zig installed at $target_link_latest (-> $(readlink -f "$target_link_latest"))"
  else
    ln -sfn "$target_link_version" "$target_link_latest"
    info "Local Zig available at $target_link_latest (-> $(readlink -f "$target_link_latest"))"
  fi

  # Add to PATH via ~/.bashrc if missing (skip for root since /usr/local/bin should be in PATH)
  if [[ $IS_ROOT -eq 0 ]]; then
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
  else
    info "Running as root - Zig installed globally, /usr/local/bin should already be in PATH"
  fi

  # Verify the newly installed Zig runs and reports the expected version
  if [[ $IS_ROOT -eq 1 ]]; then
    zig_bin="$target_link_latest"
  else
    zig_bin="$target_link_latest/zig"
  fi
  
  if [[ ! -x "$zig_bin" ]]; then
    die "Zig binary not found or not executable at $zig_bin"
  fi
  installed_ver="$($zig_bin version 2>/dev/null || true)"
  if [[ "$installed_ver" != "$REQUIRED_ZIG_VERSION" ]]; then
    die "Zig reported version '$installed_ver', expected '$REQUIRED_ZIG_VERSION'"
  fi
  
  if [[ $IS_ROOT -eq 1 ]]; then
    info "Verified global zig $installed_ver runs successfully"
  else
    info "Verified vendor zig $installed_ver runs successfully"
  fi
fi

# Ensure vendor dir is gitignored (only for local installations)
if [[ $IS_ROOT -eq 0 ]]; then
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
  if [[ $IS_ROOT -eq 1 ]]; then
    zig_candidate="/usr/local/bin/zig"
  else
    zig_candidate="$REPO_ROOT/vendor/zig/zig"
  fi
  if [[ -x "$zig_candidate" ]]; then
    zig_bin="$zig_candidate"
  fi
fi
if [[ -n "$zig_bin" ]]; then
  info "Running initial zig build"
  (cd "$REPO_ROOT" && TERM=dumb ZIG_NO_PROGRESS=1 "$zig_bin" build --summary new)
else
  warn "zig not found; skipping initial build"
fi

info "Setup complete."
