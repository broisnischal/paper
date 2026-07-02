# paper

A fast terminal wallpaper manager, built for **Omarchy** / Hyprland with
cross-platform support (Linux · macOS · Windows). Search the best online
wallpaper providers, preview thumbnails right in your terminal, generate
wallpapers with open AI models, and rotate them automatically on a schedule.

![demo](docs/demo.gif)

## Features

- 🔎 **Search** Wallhaven (no API key needed), Unsplash & Pexels (optional keys)
- 🖼️ **Inline previews** in an `fzf` picker via `chafa` (press `Ctrl-O` to open full image in `imv`)
- 🤖 **AI generation** via Hugging Face open models (default: `FLUX.1-schnell`) — `paper generate <prompt>`
- 🎲 **Random / category-based** picks, filtered to at least your screen resolution
- 📚 **Library** of everything you've downloaded (`~/Pictures/Wallpapers`)
- ⏰ **Auto-change** on a schedule — `hourly` / `daily` / `weekly` / custom — via a systemd user timer
- 🖥️ **Cross-platform apply**: Omarchy/swaybg/GNOME on Linux, `osascript` on macOS, PowerShell on Windows (Git Bash)

## Install

### One-liner (Linux / macOS / Git Bash)

```bash
curl -fsSL https://raw.githubusercontent.com/broisnischal/paper/master/install.sh | bash
```

Installs `paper` into `~/.local/bin`.

### Homebrew (macOS / Linux)

```bash
brew install broisnischal/paper/paper
```

This taps [`broisnischal/homebrew-paper`](https://github.com/broisnischal/homebrew-paper)
and pulls in `jq`, `fzf`, and `chafa` automatically.

### From source

```bash
git clone https://github.com/broisnischal/paper.git
cd paper
./install.sh
```

`install.sh` symlinks `bin/paper` into `~/.local/bin`. You can also grab a
prebuilt archive from a [release](../../releases).

| Platform | Notes |
|----------|-------|
| Linux | Full support (Omarchy, Hyprland/swaybg, GNOME) incl. systemd scheduler |
| macOS | `brew install broisnischal/paper/paper`; applies via System Events; schedule with launchd |
| Windows | Git Bash or WSL; applies via PowerShell; schedule with Task Scheduler |

### Dependencies

| Tool | Needed for | Install |
|------|-----------|---------|
| `curl`, `jq`, `fzf` | core | usually preinstalled on Omarchy |
| `chafa` | **inline image previews** | `sudo pacman -S chafa` / `brew install chafa` |
| `imv` | open full image (`Ctrl-O`) | preinstalled on Omarchy |
| `gum` | interactive key entry | preinstalled on Omarchy |
| `swaybg` / `omarchy` | applying the wallpaper | preinstalled on Omarchy |

> **What is `chafa`?** Terminals can't display a JPEG directly. `chafa` converts
> an image into colored terminal characters so the picture renders *inside* the
> `fzf` preview pane as you browse. Without it the picker still works — it just
> lists results with no thumbnails.

## Usage

```bash
paper mountains at night          # search, preview, pick, set
paper                             # prompt for a search term
paper random cyberpunk city       # grab a random match and set it now
paper --sort toplist minimal      # browse Wallhaven's top-rated
paper --categories 100 nature     # general only (100=gen 010=anime 001=people)
paper library                     # re-pick from your downloads
paper set ~/Pictures/foo.jpg      # set a local file
paper preview ~/Pictures/foo.jpg  # see an image rendered in the terminal
paper current                     # show the current wallpaper path
```

### AI generation

Generate a wallpaper from a text prompt using open models on the
[Hugging Face Inference API](https://huggingface.co/docs/api-inference) —
sized to your screen automatically:

```bash
paper config set-key huggingface <token>   # free: huggingface.co/settings/tokens
paper generate a cozy cabin in snowy mountains, golden hour
paper --model stabilityai/stable-diffusion-xl-base-1.0 generate neon tokyo street
paper config set-model <model-id>          # change the default model
```

Default model is `black-forest-labs/FLUX.1-schnell` (fast, high quality, open
weights). Any text-to-image model served by HF Inference works.

### API keys

Wallhaven works with no key. Add Unsplash / Pexels / Hugging Face keys to
unlock those sources:

```bash
paper config keys                 # interactive (recommended)
paper config set-key unsplash <key>
paper config                      # show config (keys masked)
```

Keys are stored in `~/.config/paper/config` (`chmod 600`). You can also use
env vars: `WALLHAVEN_API_KEY`, `UNSPLASH_API_KEY`, `PEXELS_API_KEY`, `HF_API_KEY`.

- Unsplash key: https://unsplash.com/developers → create an app → *Access Key*
- Pexels key: https://www.pexels.com/api/
- Hugging Face token: https://huggingface.co/settings/tokens (read access is enough)

### Auto-change (scheduler)

Rotate your wallpaper automatically with a systemd user timer:

```bash
paper auto daily nature           # a new nature wallpaper every day
paper auto hourly                 # fully random, every hour
paper auto weekly --categories 100
paper auto custom "*-*-* 08,20:00:00"   # 8am & 8pm daily
paper auto status                 # show schedule + next run
paper auto off                    # stop
```

Presets map to systemd `OnCalendar` keywords (`hourly`, `daily`, `weekly`).
Custom takes any [`OnCalendar`](https://www.freedesktop.org/software/systemd/man/systemd.time.html)
expression. `Persistent=true` means a missed change (laptop asleep) runs on
next wake.

## Uninstall

```bash
./install.sh --uninstall     # removes the symlink and disables the timer
brew uninstall paper         # if installed via Homebrew
```

Your config and downloaded wallpapers are left untouched.

## License

MIT © Nischal Dahal
