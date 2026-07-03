#!/usr/bin/env bash
# paper installer — native (Zig) wallpaper manager.
#
#   curl -fsSL https://raw.githubusercontent.com/broisnischal/paper/master/install.sh | bash
#
# From a source checkout with zig installed, this builds an optimized binary;
# otherwise it downloads the prebuilt binary for your platform from the latest
# release. Optional UX tools (fzf, chafa) are installed via your package
# manager unless PAPER_SKIP_DEPS=1.
set -euo pipefail

REPO="broisnischal/paper"
BIN_DIR="$HOME/.local/bin"
BIN_DST="$BIN_DIR/paper"

# ---- uninstall -------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
  for unit in paper-auto wallpaper-auto; do
    systemctl --user disable --now "$unit.timer" >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/$unit.service" \
          "$HOME/.config/systemd/user/$unit.timer"
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  rm -f "$BIN_DST" "$BIN_DIR/wallpaper"
  echo "Uninstalled. Config (~/.config/paper) and wallpapers were kept."
  exit 0
fi

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }

# ---- platform detection ----------------------------------------------------
case "$(uname -s)" in
  Linux)               OS=linux ;;
  Darwin)              OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) warn "unsupported OS: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) warn "unsupported arch: $(uname -m)"; exit 1 ;;
esac

# ---- optional dependencies (picker + previews) -----------------------------
# Elevate only when needed and possible.
SUDO=""
if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

install_deps() {
  [[ "${PAPER_SKIP_DEPS:-0}" == "1" ]] && return 0
  local want=(fzf chafa) missing=()
  for t in "${want[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  info "Installing optional tools: ${missing[*]} (skip with PAPER_SKIP_DEPS=1)"
  if command -v brew >/dev/null 2>&1; then
    brew install "${missing[@]}" || warn "brew install failed — install manually: ${missing[*]}"
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -S --needed --noconfirm "${missing[@]}" || warn "pacman failed — install manually: ${missing[*]}"
  elif command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq && $SUDO apt-get install -y "${missing[@]}" || warn "apt failed — install manually: ${missing[*]}"
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "${missing[@]}" || warn "dnf failed — install manually: ${missing[*]}"
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y "${missing[@]}" || warn "zypper failed — install manually: ${missing[*]}"
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add "${missing[@]}" || warn "apk failed — install manually: ${missing[*]}"
  elif command -v scoop >/dev/null 2>&1; then
    scoop install "${missing[@]}" || warn "scoop failed — install manually: ${missing[*]}"
  else
    warn "no known package manager — install manually: ${missing[*]}"
  fi
}

# ---- install the binary ----------------------------------------------------
mkdir -p "$BIN_DIR"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"

if [[ -n "$SRC_DIR" && -f "$SRC_DIR/build.zig" ]] && command -v zig >/dev/null 2>&1; then
  info "Building paper from source with zig…"
  ( cd "$SRC_DIR" && zig build -Doptimize=ReleaseFast )
  install -m 0755 "$SRC_DIR/zig-out/bin/paper" "$BIN_DST"
  info "Installed: $BIN_DST (built from source)"
else
  [[ -n "$SRC_DIR" && -f "$SRC_DIR/build.zig" ]] && \
    warn "zig not found — downloading a prebuilt binary instead (install zig to build from source)."
  if [[ "$OS" == windows ]]; then asset="paper-${OS}-${ARCH}.zip"; else asset="paper-${OS}-${ARCH}.tar.gz"; fi
  url="https://github.com/$REPO/releases/latest/download/$asset"
  info "Downloading $asset…"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/$asset"
  case "$asset" in
    *.zip)    (cd "$tmp" && unzip -qo "$asset") ;;
    *.tar.gz) tar -C "$tmp" -xzf "$tmp/$asset" ;;
  esac
  bin="$(find "$tmp" -type f \( -name paper -o -name paper.exe \) | head -n1)"
  [[ -n "$bin" ]] || { warn "could not find paper binary in $asset"; exit 1; }
  install -m 0755 "$bin" "$BIN_DST"
  info "Installed: $BIN_DST (prebuilt)"
fi

# Clean up the pre-rename symlink if it points at this tool.
[[ -L "$BIN_DIR/wallpaper" ]] && rm -f "$BIN_DIR/wallpaper"

install_deps

# ---- PATH check ------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "add ~/.local/bin to your PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.$(basename "${SHELL:-bash}")rc" ;;
esac

# libpaper ships a /usr/bin/paper; if the shell has it cached, our binary is shadowed.
if command -v hash >/dev/null 2>&1; then hash -r 2>/dev/null || true; fi
if command -v paper >/dev/null 2>&1 && [[ "$(command -v paper)" != "$BIN_DST" ]]; then
  warn "another 'paper' (\"$(command -v paper)\", likely libpaper) is ahead in PATH."
  warn "run 'hash -r' (bash) or 'rehash' (zsh), or open a new terminal."
fi

info "Done. Try:  paper mountains"
