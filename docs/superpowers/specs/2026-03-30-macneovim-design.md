# MacNeovim Design Spec

A minimal, responsive macOS GUI client for Neovim. Multi-window, tab-aware, built on AppKit.

## Goals

1. **Multi-window** — each window is an independent neovim process/session, switchable via standard macOS window cycling
2. **Tab support** — GUI tab bar maps 1:1 to neovim tabpages, Cmd+1/2/3 for fast switching
3. **Responsiveness** — first-class architectural constraint, not afterthought optimization
4. **Minimal** — a boring, vanilla GUI experience, just like MacVim provided for Vim.

## Non-Goals

- Cross-platform support
- SwiftUI
- Fancy animations or visual effects

## Architecture Overview

```
┌─────────────────────────────────────────┐
│               NSApplication             │
│  ┌─────────────────┐ ┌───────────────┐  │
│  │ WindowDocument A │ │WindowDocument B│  │  NSDocument-based
│  │ WindowController │ │WindowController│  │  per-window autonomy
│  └────────┬────────┘ └───────┬───────┘  │
└───────────┼──────────────────┼──────────┘
            │                  │
  ┌─────────▼─────────┐  ┌────▼──────────────┐
  │  NvimChannel      │  │  NvimChannel       │  actor, off-main-thread
  │  NvimProcess      │  │  NvimProcess       │  msgpack-rpc over pipes
  │  ↓                │  │  ↓                 │
  │  Grid (class)     │  │  Grid (class)      │  @MainActor, mutable
  │  ↓                │  │  ↓                 │
  │  NvimView         │  │  NvimView          │  layer-backed rendering
  │  TablineView      │  │  TablineView       │  maps nvim tabpages
  │  ↓                │  │  ↓                 │
  │  GlyphCache       │  │  GlyphCache        │  CoreText → CGImage cache
  └───────────────────┘  └───────────────────┘
       fully isolated         fully isolated
```

Each window is fully autonomous. Window lifecycle managed by NSDocument framework.

## Threading Model

Two domains:

- **NvimChannel actor** — off main thread. Handles msgpack encode/decode, pipe I/O,
  event parsing. Produces `AsyncStream<NvimEvent>`.
- **Main actor** — everything else. The `for await` loop in WindowDocument consumes
  events on the main actor. Grid mutation, NvimView rendering, input handling all run
  on the main actor, because grid updates and rendering must be serialized with user input.

Msgpack parsing (the expensive part) runs on the NvimChannel actor. The main actor
only does grid array updates and layer/glyph composition — both fast with proper caching.

## Module Design

### NvimProcess

Manages the neovim process lifecycle.

- Launches nvim with `--embed` (pipe-based RPC via stdin/stdout)
- Binary resolution: user-configured path → system PATH
- Exposes stdin/stdout/stderr pipes for NvimChannel
- Sets up environment: login shell env + `NVIM_APPNAME` + additional envs
- Clean shutdown: sends quit command, waits for process exit, kills if timeout

### NvimChannel

Actor. Handles all msgpack-rpc communication with one neovim process.

```swift
actor NvimChannel {
    func start(inPipe: Pipe, outPipe: Pipe) async throws
    func send(key: String) async
    func command(_ cmd: String) async throws
    func request(_ method: String, params: [MessagePackValue]) async throws -> MessagePackValue

    var events: AsyncStream<NvimEvent> { get }
}
```

- Owns msgpack encoding/decoding, runs off main thread
- Parses raw `redraw` notifications into typed `NvimEvent` enum
- `NvimEvent` covers: `gridLine`, `gridScroll`, `gridResize`, `gridClear`, `gridCursorGoto`,
  `flush`, `modeChange`, `modeInfoSet`, `hlAttrDefine`, `defaultColorsSet`,
  `tablineUpdate`, `setTitle`, `bell`, `optionSet`, `mouseOn`, `mouseOff`, etc.
- Request-response correlation for API calls (nvim_command, nvim_eval, etc.)
- Uses MessagePack.swift library for serialization
- On `start()`, calls `nvim_ui_attach` with options: `ext_linegrid: true`, `ext_tabline: true`
  (no `ext_multigrid` — neovim splits are rendered natively within the grid)

### Grid

`@MainActor` reference type. In-memory representation of the neovim screen.

```swift
@MainActor
final class Grid {
    private(set) var cells: [[Cell]]
    private(set) var size: GridSize           // rows x cols
    private(set) var cursorPosition: Position
    private(set) var cursorShape: CursorShape
    private(set) var dirtyRows: IndexSet
    private(set) var attributes: [Int: CellAttributes]
    private(set) var flatCharIndices: [[Int]]  // per-cell character index for IME

    func apply(_ event: NvimEvent)
    func clearDirty()
}
```

- `Cell`: character string + attribute ID + UTF-16 length (cached for text input)
- `CellAttributes`: foreground, background, special color, bold/italic/underline/undercurl/
  strikethrough flags, reverse flag
- `apply()` handles gridLine, gridScroll, gridResize, gridClear, hlAttrDefine, defaultColorsSet
- Accumulates dirty rows; Renderer reads dirty state then calls `clearDirty()`
- Scroll optimization: shifts cell arrays in-place, marks only newly exposed rows as dirty
- `flatCharIndices`: maintained on every grid mutation, maps grid positions to linear character
  indices. Required for `NSTextInputClient` conformance (IME positioning).

Class because the grid is large (10,000+ cells for a typical terminal) and owned
exclusively by one WindowDocument — copying on every flush would be wasteful.

### NvimView

NSView subclass. Renders the grid content and handles input.

**Rendering:**
- Layer-backed view (`wantsLayer = true`)
- Renders dirty rows into row-sized CGImages using CoreText + GlyphCache
- Sets row CGImages as `CALayer.contents` — GPU composites the final frame
- Scroll: repositions existing layers, renders only newly exposed rows
- Wide characters (CJK): rendered spanning two cell widths within the row image
- Cursor rendered as overlay layer with shape from Grid.cursorShape
- On window resize: calculates new grid dimensions from pixel size / cell size,
  sends `nvim_ui_try_resize` via NvimChannel, waits for grid_resize + full redraw

**Input — NSTextInputClient conformance:**
- NvimView itself conforms to `NSTextInputClient`
- Key event flow:
  1. `keyDown()` calls `self.inputContext?.handleEvent(event)`
  2. If IME is composing: `setMarkedText()` / `insertText()` callbacks handle composition
  3. If no IME / direct input: detected via `keyDownDone` flag pattern,
     key is sent directly to nvim via `NvimChannel.send(key:)`
- Marked text (IME composition): rendered as overlay at cursor position using
  `Grid.flatCharIndices` for coordinate mapping
- `firstRect(forCharacterRange:)` and `characterIndex(for:)` implemented using
  Grid's flat character index array
- Meta key detection: Ctrl/Cmd/Alt modified keys bypass IME and go directly to nvim

**Mouse:**
- Scroll wheel: sends nvim scroll events
- Click: sends mouse button + grid position via nvim `input_mouse` API
- Drag: sends mouse drag events for visual selection
- No trackpad pinch-to-zoom in MVP

### GlyphCache

Caches rendered glyph images to avoid redundant CoreText work.

```swift
class GlyphCache {
    func image(for text: String, font: NSFont, foreground: Int, background: Int,
               traits: FontTrait) -> CGImage
}
```

- Key: (text + resolved font including bold/italic variant + foreground + background + traits)
- Attribute ID not used as key — visual attributes are resolved to concrete values
- CoreText (CTLine/CTFont) renders glyph on first miss
- FIFO eviction when cache exceeds size limit (default 8192 entries)
- Shared per NvimView instance (not cross-window)
- Font change invalidates entire cache

### TablineView

Custom NSView for the tab bar.

- Driven by `tablineUpdate` event from NvimChannel
- Displays tabpage titles, highlights selected tabpage
- `onSelect` callback sends `:tabnext N` via NvimChannel
- Cmd+1/2/3 implemented as NSMenuItem key equivalents at WindowController level
- Minimal custom drawing, respects neovim colorscheme

### WindowDocument (NSDocument)

One document = one neovim session = one window.

```swift
@MainActor
class WindowDocument: NSDocument {
    var profile: Profile = .default
    private var nvimProcess: NvimProcess!
    private var channel: NvimChannel!
    private let grid = Grid()
}
```

- `makeWindowControllers()` creates WindowController with NvimView + TablineView
- Starts NvimProcess with selected Profile, connects NvimChannel
- Core event loop (runs on main actor):

```swift
func startEventLoop() async {
    for await event in channel.events {
        grid.apply(event)
        if case .flush = event {
            nvimView.render(grid)
            grid.clearDirty()
        }
        if case .tablineUpdate(let tabs) = event {
            tablineView.update(tabs)
        }
    }
    // Stream ended = nvim process exited
    close()
}
```

**Window close lifecycle:**

Multiple paths, all converge to clean shutdown:

1. **Nvim exits on its own** (`:qa!`) — AsyncStream ends → `close()` called → NSDocument
   removes window
2. **User clicks close button** — `canClose(withDelegate:)` checks for dirty buffers via
   `nvim_get_modified_bufs()`. If dirty, shows save/discard alert. On confirm, sends `:qa!`
   to nvim, waits for process exit, then allows close.
3. **Nvim crashes** (SIGKILL/etc) — AsyncStream ends abruptly → same as path 1, window
   closes with optional "nvim exited unexpectedly" notification
4. **Cmd+Q (app quit)** — `applicationShouldTerminate` iterates all documents, each follows
   path 2. `NSApplication.TerminateReply.terminateLater` used for async coordination.

### WindowController (NSWindowController)

- Lays out NvimView + TablineView in the window
- Routes Cmd+1/2/3 via menu item key equivalents to NvimChannel
- Handles window title from `setTitle` event
- On window resize: triggers NvimView resize flow

### Profile

Represents an NVIM_APPNAME configuration.

```swift
struct Profile: Codable, Hashable {
    let name: String          // directory name under ~/.config/
    var displayName: String   // user-facing label

    static let `default` = Profile(name: "nvim", displayName: "Default")
}
```

- Scanned from `$XDG_CONFIG_HOME` (default `~/.config/`) directories containing nvim config
  (init.lua, init.vim, or lua/ directory)
- New window: Cmd+N shows lightweight popover to pick Profile
- Cmd+Shift+N: create window with last-used Profile (skip picker)
- Stored in UserDefaults as last-used preference

## Neovim Binary Strategy

MVP priority order:
1. User-configured path in preferences (if set and valid)
2. System nvim from PATH

Bundled binary support deferred to post-MVP.

## Responsiveness Strategy

### Input Latency (target: < 8ms to send, < 16ms to display)
- keyDown → NvimChannel.send(): direct call to actor, minimal overhead
- NvimChannel encodes msgpack and writes to pipe immediately

### Rendering (target: one frame for typical edits)
- Layer-backed: GPU composites cached layers, CPU only touches dirty rows
- GlyphCache eliminates redundant CoreText rendering (the expensive part)
- Scroll: reposition layers (GPU, near-zero cost) + render 1-2 new rows
- Batch: accumulate grid events between flushes, render once per flush

### Window/Tab Operations (target: perceived instant)
- New window: NSDocument creates window immediately, nvim starts async in background
- Tab switch: Cmd+N sends `:tabnext N`, one RPC call, response updates grid

### Startup
- Minimal launch path: create NSDocument → start nvim process → connect channel
- Minimal startup path, no heavy initialization

## Font Handling

- Primary configuration via neovim's `guifont` option (`:set guifont=...`)
- Detected via `optionSet` event from NvimChannel
- Font change triggers: recalculate cell size → `nvim_ui_try_resize` → full grid redraw
  → GlyphCache invalidated
- Fallback font chain for missing glyphs: configured font → system fallback (via CoreText
  font cascade, which handles CJK and emoji automatically)
- Line spacing and character spacing configurable via neovim options

## Naming Conventions

| Concept | Name | Follows |
|---------|------|---------|
| App window document | `WindowDocument` | User visual intuition |
| App window controller | `WindowController` | AppKit convention |
| RPC connection | `NvimChannel` | Neovim `:h channel` |
| Process manager | `NvimProcess` | Descriptive |
| Screen buffer | `Grid`, `Cell`, `CellAttributes` | Neovim UI protocol |
| Tab bar view | `TablineView` | Neovim `tabline` |
| Tab data type | `Tabpage` | Neovim API type |
| Render view | `NvimView` | Descriptive |
| Glyph cache | `GlyphCache` | Descriptive |
| NVIM_APPNAME config | `Profile` | User intuition |

Neovim-originated concepts use neovim's own terminology. Internal concepts prioritize
programmer intuition. Neovim's `window` (split) is not exposed at GUI level.

## MVP Scope

1. Single and multi-window with independent neovim processes
2. Tab bar mapping neovim tabpages with Cmd+1/2/3
3. Neovim binary: system PATH, with user-configurable override
4. Profile (NVIM_APPNAME) selection on new window
5. Font and theme following neovim colorscheme
6. Mouse: scroll wheel, click-to-position, drag selection
7. IME / text input support (NSTextInputClient)
8. Window resize with grid recalculation
9. Responsiveness as architectural constraint throughout

## Out of MVP Scope

- Preferences UI (use nvim config and `defaults` commands for now)
- File associations / Open With
- Drag & drop files onto window
- State restoration (reopen windows after quit)
- Sparkle auto-update
- Trackpad pinch-to-zoom

## Dependencies

| Package | Purpose |
|---------|---------|
| MessagePack.swift | Msgpack serialization for RPC |

Single external dependency. CoreText, CALayer, NSDocument are all system frameworks.
