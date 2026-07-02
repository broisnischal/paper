#!/usr/bin/env bash
# Installer for wallpaper-cli — symlinks bin/wallpaper into ~/.local/bin.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$REPO_DIR/bin/wallpaper"
BIN_DST="$HOME/.local/bin/wallpaper"
TMR="wallpaper-auto.timer"

if [[ "${1:-}" == "--uninstall" ]]; then
  systemctl --user disable --now "$TMR" >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/wallpaper-auto.service" \
        "$HOME/.config/systemd/user/$TMR"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  [[ -L "$BIN_DST" ]] && rm -f "$BIN_DST"
  echo "Uninstalled. Config (~/.config/wallpaper) and wallpapers were kept."
  exit 0
fi

mkdir -p "$HOME/.local/bin"
chmod +x "$BIN_SRC"
ln -sfn "$BIN_SRC" "$BIN_DST"
echo "Installed: $BIN_DST -> $BIN_SRC"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "NOTE: add ~/.local/bin to your PATH." ;;
esac

command -v chafa >/dev/null 2>&1 || \
  echo "TIP: install chafa for inline image previews:  sudo pacman -S chafa"

echo "Done. Try:  wallpaper mountains"
