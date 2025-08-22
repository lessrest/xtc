#!/usr/bin/env bash

# Setup script for xtc
# - Ensures Zig 0.15.1 is available (downloads portable build)
# - When run as root: installs globally to /usr/local/bin
# - When run as regular user: installs locally and adds vendor/zig to PATH via ~/.bashrc
# - Ensures git submodules are initialized (depth 1)
# - Sets TERM=dumb when running zig build

set -euo pipefail

REQUIRED_ZIG_VERSION="0.15.1"

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
mkdir -p "$INSTALL_DIR/bin"

warn() { echo -e "[setup] WARNING: $*" >&2; }
die()  { echo -e "[setup] ERROR: $*" >&2; exit 1; }

install_zig_version() {
  local ver="$1"
  local url="https://ziglang.org/download/${ver}/zig-x86_64-linux-${ver}.tar.xz"
  local tarball_name="zig-x86_64-linux-${ver}.tar.xz"
  local tarball_path="$INSTALL_DIR/$tarball_name"
  local extracted_dir_name="zig-x86_64-linux-${ver}"
  local extracted_dir_path="$INSTALL_DIR/$extracted_dir_name"
  local version_link="$INSTALL_DIR/zig-${ver}"
  local version_bin_link
  if [[ $IS_ROOT -eq 1 ]]; then
    version_bin_link="$INSTALL_DIR/bin/zig-${ver}"
  else
    version_bin_link="$INSTALL_DIR/bin/zig-${ver}"
  fi

  if [[ ! -d "$extracted_dir_path" ]]; then
    info "Fetching Zig ${ver} portable toolchain..."
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail --retry 3 -o "$tarball_path" "$url"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$tarball_path" "$url"
    else
      die "Neither curl nor wget is available to download $url"
    fi
    info "Extracting $tarball_name into $INSTALL_DIR"
    tar -xJf "$tarball_path" -C "$INSTALL_DIR"
  else
    info "Zig ${ver} archive already extracted"
  fi

  ln -sfn "$extracted_dir_path" "$version_link"
  ln -sfn "$version_link/zig" "$version_bin_link"
  info "Linked $version_bin_link -> $(readlink -f "$version_bin_link")"

  # Verify
  if [[ ! -x "$version_bin_link" ]]; then
    die "Zig ${ver} binary not found at $version_bin_link"
  fi
  local reported
  reported="$($version_bin_link version 2>/dev/null || true)"
  if [[ "$reported" != "$ver" ]]; then
    die "Zig reported '$reported', expected '$ver' at $version_bin_link"
  fi
  info "Verified zig-$ver runs successfully"
}

# Ensure required zig and extra zig are installed side-by-side
install_zig_version "$REQUIRED_ZIG_VERSION"

# Maintain a default 'zig' symlink to REQUIRED_ZIG_VERSION
ln -sfn "$INSTALL_DIR/bin/zig-${REQUIRED_ZIG_VERSION}" "$INSTALL_DIR/bin/zig"
info "Default zig -> $(readlink -f "$INSTALL_DIR/bin/zig")"

# Add vendor/bin (or /usr/local/bin) to PATH via ~/.bashrc for local install
if [[ $IS_ROOT -eq 0 ]]; then
  bashrc="$HOME/.bashrc"
  export_line="export PATH=\"$INSTALL_DIR/bin:\$PATH\""
  if [[ -f "$bashrc" ]] && grep -Fq "$INSTALL_DIR/bin" "$bashrc"; then
    info "~/.bashrc already contains vendor bin path"
  else
    info "Adding vendor bin path to ~/.bashrc"
    {
      echo ""
      echo "# Added by xtc/scripts/setup.sh on $(date +%F)"
      echo "$export_line"
    } >> "$bashrc"
    info "To use immediately: export PATH=\"$INSTALL_DIR/bin:\$PATH\""
  fi
else
  info "Running as root - /usr/local/bin already on PATH"
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

# Perform an initial build to warm caches and verify the default toolchain
zig_bin="$(command -v zig 2>/dev/null || true)"
if [[ -n "$zig_bin" ]]; then
  info "Running initial zig build"
  (cd "$REPO_ROOT" && TERM=dumb ZIG_NO_PROGRESS=1 "$zig_bin" build --summary new)
else
  warn "zig not found; skipping initial build"
fi

info "Setup complete."
