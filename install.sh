#!/usr/bin/env bash
# Installer for paper — the native (Zig) wallpaper manager.
#
# From a clone:                     ./install.sh        # builds from source if zig is present
# Straight from the internet:
#   curl -fsSL https://raw.githubusercontent.com/broisnischal/paper/master/install.sh | bash
#
# With a source checkout + zig, this builds an optimized binary. Otherwise it
# downloads the prebuilt binary for your platform from the latest release.
set -euo pipefail

REPO="broisnischal/paper"
BIN_DIR="$HOME/.local/bin"
BIN_DST="$BIN_DIR/paper"

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

mkdir -p "$BIN_DIR"

# Detect the platform triple used by release assets.
detect_asset() {
  local os arch
  case "$(uname -s)" in
    Linux)              os=linux ;;
    Darwin)             os=macos ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
  if [[ "$os" == windows ]]; then echo "paper-${os}-${arch}.zip"; else echo "paper-${os}-${arch}.tar.gz"; fi
}

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"

if [[ -n "$SRC_DIR" && -f "$SRC_DIR/build.zig" ]] && command -v zig >/dev/null 2>&1; then
  echo "Building paper from source with zig…"
  ( cd "$SRC_DIR" && zig build -Doptimize=ReleaseFast )
  install -m 0755 "$SRC_DIR/zig-out/bin/paper" "$BIN_DST"
  echo "Installed: $BIN_DST (built from source)"
else
  [[ -n "$SRC_DIR" && -f "$SRC_DIR/build.zig" ]] && \
    echo "zig not found — downloading a prebuilt binary instead (install zig to build from source)."
  asset="$(detect_asset)"
  url="https://github.com/$REPO/releases/latest/download/$asset"
  echo "Downloading $asset from the latest release…"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/$asset"
  case "$asset" in
    *.zip)    (cd "$tmp" && unzip -qo "$asset") ;;
    *.tar.gz) tar -C "$tmp" -xzf "$tmp/$asset" ;;
  esac
  bin="$(find "$tmp" -type f \( -name 'paper' -o -name 'paper.exe' \) | head -n1)"
  [[ -n "$bin" ]] || { echo "could not find paper binary in $asset" >&2; exit 1; }
  install -m 0755 "$bin" "$BIN_DST"
  echo "Installed: $BIN_DST (prebuilt)"
fi

# Clean up the pre-rename symlink if it points at this tool.
[[ -L "$BIN_DIR/wallpaper" ]] && rm -f "$BIN_DIR/wallpaper"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "NOTE: add ~/.local/bin to your PATH." ;;
esac

# paper handles HTTP/JSON natively; these tools remain optional for the UX.
missing=()
for t in fzf chafa; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if ((${#missing[@]})); then
  case "$(uname -s)" in
    Darwin) echo "TIP: for the picker & inline previews:  brew install ${missing[*]}" ;;
    *)      echo "TIP: for the picker & inline previews:  sudo pacman -S ${missing[*]}" ;;
  esac
fi

echo "Done. Try:  paper mountains"
