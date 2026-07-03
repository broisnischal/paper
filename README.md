<div align="center">

# paper

**A fast, native wallpaper manager for your terminal.**

Search the best wallpaper sites, preview thumbnails inline, generate art with
open AI models, and rotate your wallpaper on a schedule — all from a single
self-contained binary.

[Install](#install) · [Usage](#usage) · [AI generation](#ai-generation) · [Auto-change](#auto-change) · [FAQ](#faq)

[![CI](https://github.com/broisnischal/paper/actions/workflows/ci.yml/badge.svg)](https://github.com/broisnischal/paper/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/broisnischal/paper?color=25c65f)](https://github.com/broisnischal/paper/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

![demo](docs/demo.gif)

</div>

## Features

- **Search** Wallhaven (no key), Unsplash & Pexels (optional keys)
- **Works with zero extra tools** — a built-in numbered picker out of the box; add `fzf` + `chafa` for a fuzzy picker with inline thumbnail previews
- **Auto-sized results** — detects your screen resolution (Hyprland, X11, Windows, macOS) and filters to wallpapers that fit
- **AI generation** — `paper generate <prompt>` via open Hugging Face models
- **Library** of everything you've downloaded (`~/Pictures/Wallpapers`)
- **Auto-change** on a schedule — hourly / daily / weekly / custom
- **Cross-platform apply** — Omarchy/swaybg/GNOME on Linux, System Events on macOS, PowerShell on Windows

Written in [Zig](https://ziglang.org): HTTPS and JSON are handled in-process, so
there's **no `curl` or `jq` dependency**, thumbnails download concurrently, and
startup is instant.

## Install

### One line (Linux · macOS · Git Bash)

```bash
curl -fsSL https://raw.githubusercontent.com/broisnischal/paper/master/install.sh | bash
```

Downloads the prebuilt binary for your platform into `~/.local/bin`. It also
tries to install the optional picker tools (`fzf`, `chafa`) with your package
manager — but they aren't required: without them `paper` shows a simple numbered
menu. Skip the extras with `PAPER_SKIP_DEPS=1`.

**Windows:** run it in Git Bash (or WSL). The one-liner installs `paper.exe`;
the numbered picker works with nothing else installed.

### Homebrew (macOS · Linux)

```bash
brew install broisnischal/paper/paper
```

### From source

Requires [Zig 0.16+](https://ziglang.org/download/).

```bash
git clone https://github.com/broisnischal/paper.git
cd paper
./install.sh          # builds an optimized binary and installs it
```

During development, run it directly with `zig build run -- mountains`.

> Make sure `~/.local/bin` is on your `PATH`. See the [FAQ](#faq) if the `paper`
> command runs the wrong program.

## Usage

```bash
paper mountains at night          # search, preview, pick, set
paper                             # prompt for a search term
paper random cyberpunk city       # grab a random match and set it now
paper library                     # re-pick from your downloads
paper set ~/Pictures/foo.jpg      # set a local file
paper preview ~/Pictures/foo.jpg  # render an image in the terminal
paper current                     # show the current wallpaper path
```

<details>
<summary><b>Options & search tuning</b></summary>

```
-s, --source <name>    wallhaven (default) | unsplash | pexels
-c, --categories <b>   wallhaven bitmask general/anime/people (default 111)
-p, --purity <b>       wallhaven bitmask sfw/sketchy/nsfw     (default 100)
    --sort <mode>      relevance | random | toplist | views | favorites | date_added
-n, --limit <N>        number of results to fetch (default 24)
    --atleast <WxH>    minimum resolution (default: your screen)
    --model <id>       Hugging Face model for 'generate'
    --no-preview       list without thumbnail previews
```

```bash
paper --sort toplist minimal      # browse Wallhaven's top-rated
paper --categories 100 nature     # general only (100=gen 010=anime 001=people)
```

</details>

## AI generation

Generate a wallpaper from a prompt using open models on the
[Hugging Face Inference API](https://huggingface.co/docs/api-inference), sized
to your screen automatically:

```bash
paper config set-key huggingface <token>   # free: huggingface.co/settings/tokens
paper generate a cozy cabin in snowy mountains, golden hour
paper --model stabilityai/stable-diffusion-xl-base-1.0 generate neon tokyo street
```

The default model is `black-forest-labs/FLUX.1-schnell` (fast, high quality,
open weights). Change it with `paper config set-model <id>`.

## API keys

Wallhaven works with no key. Add Unsplash / Pexels / Hugging Face keys to unlock
those sources:

```bash
paper config keys                 # interactive (recommended)
paper config set-key unsplash <key>
paper config                      # show config (keys masked)
```

Keys live in `~/.config/paper/config` (`chmod 600`) or the environment
(`WALLHAVEN_API_KEY`, `UNSPLASH_API_KEY`, `PEXELS_API_KEY`, `HF_API_KEY`).

- Unsplash: https://unsplash.com/developers → create an app → *Access Key*
- Pexels: https://www.pexels.com/api/
- Hugging Face: https://huggingface.co/settings/tokens (read access is enough)

## Auto-change

Rotate your wallpaper automatically with a systemd user timer:

```bash
paper auto daily nature           # a new nature wallpaper every day
paper auto hourly                 # fully random, every hour
paper auto custom "*-*-* 08,20:00:00"   # 8am & 8pm daily
paper auto status                 # show schedule + next run
paper auto off                    # stop
```

`Persistent=true` means a change missed while asleep runs on next wake. On
macOS / Windows, use `launchd` / Task Scheduler to run `paper random`.

## Compatibility

| Platform | Notes |
|----------|-------|
| Linux    | Full support (Omarchy, Hyprland/swaybg, GNOME) incl. the systemd scheduler |
| macOS    | Applies via System Events; schedule with launchd |
| Windows  | Git Bash or WSL; applies via PowerShell; schedule with Task Scheduler |

## Uninstall

```bash
paper auto off               # stop the scheduler
./install.sh --uninstall     # remove the binary and timer
brew uninstall paper         # if installed via Homebrew
```

Your config and downloaded wallpapers are left untouched.

## FAQ

<details>
<summary><b>I typed <code>paper</code> and it printed "Letter: 8.5x11 in"</b></summary>

That's `libpaper`'s `/usr/bin/paper`, not this tool. Your shell cached the old
location. Run `hash -r` (bash) or `rehash` (zsh), or open a new terminal.
`~/.local/bin` must come before `/usr/bin` on your `PATH`.

</details>

<details>
<summary><b>Do I need <code>curl</code> or <code>jq</code>?</b></summary>

No. HTTP (with TLS) and JSON are built into the binary. `fzf` and `chafa` are
optional and only power the interactive picker and inline previews.

</details>

<details>
<summary><b>What is <code>chafa</code>?</b></summary>

Terminals can't display a JPEG directly. `chafa` converts an image into colored
terminal characters so the picture renders inside the `fzf` preview pane. Without
it the picker still works — it just lists results with no thumbnails.

</details>

## Contributing

Issues and PRs welcome. Build with `zig build`, run the smoke tests with
`zig build test`.

## License

MIT © [Nischal Dahal](https://github.com/broisnischal)
