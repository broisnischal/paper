#!/usr/bin/env bash
# Installer for paper — installs the `paper` CLI into ~/.local/bin.
#
# From a clone / extracted release:   ./install.sh
# Straight from the internet:
#   curl -fsSL https://raw.githubusercontent.com/broisnischal/paper/master/install.sh | bash
set -euo pipefail

REPO="broisnischal/paper"
RAW_URL="https://raw.githubusercontent.com/$REPO/master/bin/paper"
BIN_DST="$HOME/.local/bin/paper"
TMR="paper-auto.timer"

if [[ "${1:-}" == "--uninstall" ]]; then
  for unit in paper-auto wallpaper-auto; do
    systemctl --user disable --now "$unit.timer" >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/$unit.service" \
          "$HOME/.config/systemd/user/$unit.timer"
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  rm -f "$BIN_DST" "$HOME/.local/bin/wallpaper"
  echo "Uninstalled. Config (~/.config/paper) and wallpapers were kept."
  exit 0
fi

mkdir -p "$HOME/.local/bin"

# Local checkout (or extracted release archive) → symlink; otherwise download.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "$SRC_DIR" && -f "$SRC_DIR/bin/paper" ]]; then
  chmod +x "$SRC_DIR/bin/paper"
  ln -sfn "$SRC_DIR/bin/paper" "$BIN_DST"
  echo "Installed: $BIN_DST -> $SRC_DIR/bin/paper"
else
  echo "Downloading paper from github.com/$REPO…"
  curl -fsSL "$RAW_URL" -o "$BIN_DST"
  chmod +x "$BIN_DST"
  echo "Installed: $BIN_DST"
fi

# Clean up the pre-rename symlink if it points at this tool
[[ -L "$HOME/.local/bin/wallpaper" ]] && rm -f "$HOME/.local/bin/wallpaper"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "NOTE: add ~/.local/bin to your PATH." ;;
esac

if ! command -v chafa >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin) echo "TIP: install deps for previews & picking:  brew install jq fzf chafa" ;;
    *)      echo "TIP: install chafa for inline image previews:  sudo pacman -S chafa" ;;
  esac
fi

echo "Done. Try:  paper mountains"
