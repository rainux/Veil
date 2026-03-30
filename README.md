# Veil

A boring, vanilla Neovim GUI client for macOS — just like MacVim did for Vim.

Your Neovim config, rendered natively with AppKit, in proper macOS windows. Nothing more, nothing less.

## Features

- **Multi-window** — each window runs an independent neovim process. Cmd+N to create, Cmd+\` to cycle.
- **Tabs** — neovim's native tabline, switchable with Cmd+1 through Cmd+9.
- **Profile support** — Cmd+Shift+N to choose a different `NVIM_APPNAME` per window.
- **CJK & IME** — full input method support for Chinese, Japanese, Korean.
- **Metal rendering** — GPU-accelerated rendering with glyph texture atlas. Entire grid drawn in a single Metal draw call. Falls back to CoreText if Metal is unavailable.
- **System integration** — standard Edit/File menu actions, trackpad scrolling, window size persistence.

## Requirements

- macOS 14+
- Neovim 0.10+ (install via `brew install neovim`)

Veil uses your system-installed neovim. No bundled binary — you always get the latest version you chose to install.

## Build

Open `Veil.xcodeproj` in Xcode and run, or:

```
xcodebuild build -project Veil.xcodeproj -scheme Veil -destination 'platform=macOS'
```

## Usage

Veil reads your existing neovim configuration (`~/.config/nvim/`). Set `guifont` in your config to choose a font:

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

Everything else (including all Ctrl+key and other Cmd+key combinations) is sent directly to neovim as `<D-...>` or `<C-...>`. Map them in your config:

```lua
-- Example: Cmd+P to open a file picker
vim.keymap.set('n', '<D-p>', Snacks.picker.files)
```

## CLI

Veil ships a `veil` command inside the app bundle. Symlink it to your PATH:

    ln -s /Applications/Veil.app/Contents/bin/veil ~/.local/bin/veil
    ln -s /Applications/Veil.app/Contents/bin/gvim ~/.local/bin/gvim
    ln -s /Applications/Veil.app/Contents/bin/gvimdiff ~/.local/bin/gvimdiff

Then use it like nvim:

    veil file.txt
    veil -d file1.txt file2.txt
    gvimdiff file1.txt file2.txt    # same as veil -d

## Acknowledgments

Thanks to [VimR](https://github.com/qvacua/vimr) by Tae Won Ha — Veil learned a great deal from its implementation of the Neovim UI protocol, input handling, and macOS integration.

## License

MIT
