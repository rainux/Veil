# Veil

<p align="center">
  <img src="Veil/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="Veil">
</p>

A quiet, vanilla Neovim GUI for macOS — in the tradition of MacVim.

Your Neovim config, in proper macOS windows with Metal GPU rendering. Nothing more, nothing less. Fast startup, fast multi-tab session loading.

### Why a GUI instead of the terminal?

- **Cmd+1/2/3 to switch tabs**: in a terminal, these shortcuts conflict with the terminal emulator. Veil gives them directly to Neovim's tabpages, zero configuration.
- **Cmd+\` to cycle windows**: each window is an independent Neovim session. Instantly switch between projects in the same space, or spread them across spaces and displays.

No terminal keybinding hacks, no tmux layers. Just Neovim in a native macOS window.

## Features

- **Multi-window**: each window runs an independent Neovim process. Cmd+N to create, Cmd+\` to cycle.
- **Tabs**: Neovim's native tabline, switchable with Cmd+1 through Cmd+9.
- **Profile support**: Cmd+Shift+N to choose a different `NVIM_APPNAME` per window.
- **CJK & IME**: full input method support for Chinese, Japanese, Korean.
- **Metal rendering**: GPU-accelerated rendering with glyph texture atlas. Entire grid drawn in a single Metal draw call. Falls back to CoreText if Metal is unavailable.
- **System integration**: standard Edit/File menu actions, trackpad scrolling, window size persistence.

<p align="center">
  <img src="screenshots/main.png" alt="Veil screenshot">
</p>

## Requirements

- macOS 14+
- Neovim 0.10+ (install via `brew install neovim`)

Veil uses your system-installed Neovim. No bundled binary, you always get the latest version you chose to install.

## Install

Download `Veil.zip` from [Releases](https://github.com/rainux/Veil/releases), unzip, and move `Veil.app` to `/Applications`. Then remove the quarantine attribute so macOS doesn't block it:

```bash
xattr -cr /Applications/Veil.app
```

## Build

Open `Veil.xcodeproj` in Xcode and run, or:

```
make                # Release build
make debug          # Debug build
make test           # Run unit tests
make install        # Release build + install to /Applications
make clean          # Clean build artifacts
make lsp            # Generate buildServer.json for SourceKit-LSP
```

For Neovim/editor LSP support, run `make lsp` after cloning to generate `buildServer.json` (requires [xcode-build-server](https://github.com/nicklockwood/xcode-build-server)).

## Usage

Veil reads your existing Neovim configuration (`~/.config/nvim/`). Set `guifont` in your config to choose a font:

```lua
vim.o.guifont = 'Maple Mono NF CN:h16'
```

### Keyboard

These Cmd+key shortcuts are handled by Veil:

| Key         | Action                                |
| ----------- | ------------------------------------- |
| Cmd+N       | New window                            |
| Cmd+Shift+N | New window with profile picker        |
| Cmd+W       | Close tab (or window if only one tab) |
| Cmd+Shift+W | Close window                          |
| Cmd+Q       | Quit                                  |
| Cmd+S       | Save (`:w`)                           |
| Cmd+Z       | Undo (`u`)                            |
| Cmd+Shift+Z | Redo (`Ctrl+R`)                       |
| Cmd+C/X/V   | Copy/Cut/Paste (system clipboard)     |
| Cmd+A       | Select all                            |
| Cmd+M       | Minimize                              |
| Cmd+\`      | Cycle windows                         |
| Cmd+1-9     | Switch tab (9 = last)                 |
| Cmd+Ctrl+F  | Toggle full screen                    |

Everything else (including other Cmd+key and all Ctrl+key combinations) is sent directly to Neovim as `<D-...>` or `<C-...>`. Map them in your config:

```lua
-- Example: Cmd+P to open a file picker
vim.keymap.set('n', '<D-p>', Snacks.picker.files)
```

## CLI

Veil ships CLI commands inside the app bundle: `veil`, plus `gvim` and `gvimdiff` as traditional aliases (`gvimdiff` is equivalent to `veil -d`). Symlink them to your PATH:

```bash
ln -s /Applications/Veil.app/Contents/bin/veil ~/.local/bin/veil
ln -s /Applications/Veil.app/Contents/bin/gvim ~/.local/bin/gvim
ln -s /Applications/Veil.app/Contents/bin/gvimdiff ~/.local/bin/gvimdiff
```

Then use it like nvim:

```bash
veil file.txt
veil -d file1.txt file2.txt
gvimdiff file1.txt file2.txt    # same as veil -d
```

If Veil is already running, the CLI forwards files to the existing instance (opens a new window) instead of launching a second copy.

### Multiple nvim configs

Each window can run a different Neovim configuration. Use `NVIM_APPNAME` from the CLI or Cmd+Shift+N from the GUI to select which config directory under `~/.config/` nvim uses:

```bash
NVIM_APPNAME=astronvim veil              # launch Veil with astronvim config
NVIM_APPNAME=nvim-nvchad gvim file.txt   # open file with NvChad config
```

Create shell aliases for configs you use often:

```bash
alias gvi='NVIM_APPNAME=nvim-nvchad gvim'
gvi file.txt                             # just works, fresh launch or new window
```

## Acknowledgments

Thanks to [VimR](https://github.com/qvacua/vimr) by Tae Won Ha. Veil learned a great deal from its implementation of the Neovim UI protocol, input handling, and macOS integration.

## License

MIT
