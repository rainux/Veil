# MacNeovim MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal, responsive macOS GUI client for Neovim with multi-window and tab support.

**Architecture:** NSDocument-based multi-window app where each window owns an independent neovim process. Communication via msgpack-rpc over stdin/stdout pipes. Layer-backed rendering with glyph caching for responsiveness. No Redux, no global state — each window is fully autonomous.

**Tech Stack:** Swift 6, AppKit (pure, no SwiftUI), MessagePack.swift (msgpack serialization), CoreText (glyph rendering), CALayer (compositing)

**Spec:** `docs/superpowers/specs/2026-03-30-macneovim-design.md`

**VimR reference code:** `vimr/` directory (MIT license, for algorithmic reference only — all code is freshly written)

---

## File Structure

```
MacNeovim/
├── AppDelegate.swift              # App lifecycle, menu setup
├── Base.lproj/MainMenu.xib        # Main menu (existing, will modify)
├── Assets.xcassets/               # App icons (existing)
│
├── Nvim/
│   ├── NvimProcess.swift          # Process lifecycle: launch, pipes, shutdown
│   ├── NvimChannel.swift          # Actor: msgpack-rpc encode/decode, event stream
│   ├── NvimEvent.swift            # Enum: typed UI protocol events
│   ├── MsgpackRpc.swift           # Actor: low-level msgpack-rpc message pump
│   └── KeyUtils.swift             # macOS key events → neovim key notation
│
├── Grid/
│   ├── Grid.swift                 # @MainActor class: 2D cell array, dirty tracking
│   ├── Cell.swift                 # Cell struct: character + attrId
│   ├── CellAttributes.swift       # Colors, bold/italic/underline flags
│   └── GridTypes.swift            # Position, GridSize, Region value types
│
├── Rendering/
│   ├── NvimView.swift             # NSView: layer-backed rendering + input
│   ├── NvimView+Keyboard.swift    # keyDown, NSTextInputClient conformance
│   ├── NvimView+Mouse.swift       # Mouse clicks, drag, scroll wheel
│   ├── GlyphCache.swift           # CoreText glyph → CGImage cache
│   └── RowRenderer.swift          # Renders one grid row to CGImage using GlyphCache
│
├── Window/
│   ├── WindowDocument.swift       # NSDocument: owns nvim process + event loop
│   ├── WindowController.swift     # NSWindowController: layout + menu routing
│   ├── TablineView.swift          # Custom tab bar mapping nvim tabpages
│   └── ProfilePicker.swift        # NVIM_APPNAME selection popover
│
└── Util/
    └── Profile.swift              # NVIM_APPNAME config scanning

MacNeovimTests/
├── MsgpackRpcTests.swift          # RPC encode/decode, request correlation
├── NvimEventParserTests.swift     # Raw msgpack → NvimEvent parsing
├── GridTests.swift                # Grid apply, scroll, dirty tracking
├── CellAttributesTests.swift      # Attribute resolution, reverse, defaults
├── KeyUtilsTests.swift            # Key conversion coverage
├── GlyphCacheTests.swift          # Cache hit/miss, eviction
└── ProfileTests.swift             # Config directory scanning
```

---

### Task 1: Project Setup and Dependencies

**Files:**
- Modify: `MacNeovim.xcodeproj/project.pbxproj` (via Xcode SPM UI)
- Create: `MacNeovim/Nvim/` directory
- Create: `MacNeovim/Grid/` directory
- Create: `MacNeovim/Rendering/` directory
- Create: `MacNeovim/Window/` directory
- Create: `MacNeovim/Util/` directory
- Create: `MacNeovim/Grid/GridTypes.swift`

**Context:** The Xcode project already exists with AppDelegate.swift and MainMenu.xib. We need to add the MessagePack.swift SPM dependency and create the directory structure.

- [ ] **Step 1: Add MessagePack.swift SPM dependency**

In Xcode: File → Add Package Dependencies → URL: `https://github.com/qvacua/MessagePack.swift`, version `4.1.0` up to next major. Add product `MessagePack` to the `MacNeovim` target.

Alternatively via command line — add to the Xcode project's package references. The dependency URL is `https://github.com/qvacua/MessagePack.swift` with minimum version `4.1.0`.

- [ ] **Step 2: Create directory structure**

```bash
mkdir -p MacNeovim/Nvim MacNeovim/Grid MacNeovim/Rendering MacNeovim/Window MacNeovim/Util
```

Since this is a `PBXFileSystemSynchronizedRootGroup` Xcode project, files added to the `MacNeovim/` folder are automatically included in the build.

- [ ] **Step 3: Create GridTypes.swift with core value types**

These foundational types are used everywhere — define them first so subsequent tasks can reference them.

```swift
// MacNeovim/Grid/GridTypes.swift

import Foundation

struct Position: Equatable, Hashable, Sendable {
    var row: Int
    var col: Int

    static let zero = Position(row: 0, col: 0)
}

struct GridSize: Equatable, Hashable, Sendable {
    var rows: Int
    var cols: Int

    static let zero = GridSize(rows: 0, cols: 0)
}

struct Region: Equatable, Sendable {
    var top: Int
    var bottom: Int
    var left: Int
    var right: Int
}
```

- [ ] **Step 4: Verify build succeeds**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add MacNeovim/Nvim MacNeovim/Grid MacNeovim/Rendering MacNeovim/Window MacNeovim/Util MacNeovim/Grid/GridTypes.swift MacNeovim.xcodeproj
git commit -m "Add MessagePack dependency and project directory structure"
```

---

### Task 2: MsgpackRpc — Low-Level Message Pump

**Files:**
- Create: `MacNeovim/Nvim/MsgpackRpc.swift`
- Create: `MacNeovimTests/MsgpackRpcTests.swift`

**Context:** This is the lowest layer — raw msgpack-rpc over pipes. It handles message framing, encode/decode, and request-response correlation. The neovim msgpack-rpc protocol uses 3 message types: request `[0, msgid, method, params]`, response `[1, msgid, error, result]`, and notification `[2, method, params]`.

**Reference:** `vimr/NvimApi/Sources/NvimApi/MsgpackRpc.swift` (317 lines) for the actor pattern and buffer management.

- [ ] **Step 1: Write failing tests for message encoding**

```swift
// MacNeovimTests/MsgpackRpcTests.swift

import XCTest
import MessagePack
@testable import MacNeovim

final class MsgpackRpcTests: XCTestCase {

    func testEncodeRequest() throws {
        let data = MsgpackRpc.encodeRequest(
            msgid: 1,
            method: "nvim_ui_attach",
            params: [.int(80), .int(24), .map(["rgb": .bool(true)])]
        )
        let unpacked = try unpack(data)
        let array = unpacked.value.arrayValue!
        XCTAssertEqual(array[0], .uint(0))  // request type
        XCTAssertEqual(array[1], .uint(1))  // msgid
        XCTAssertEqual(array[2], .string("nvim_ui_attach"))
        XCTAssertEqual(array[3].arrayValue?.count, 3)
    }

    func testDecodeResponse() throws {
        // Encode a response: [1, msgid, nil, "ok"]
        let response: MessagePackValue = .array([.uint(1), .uint(1), .nil, .string("ok")])
        let data = pack(response)

        let messages = try MsgpackRpc.decode(data: data)
        XCTAssertEqual(messages.count, 1)

        if case .response(let msgid, let error, let result) = messages[0] {
            XCTAssertEqual(msgid, 1)
            XCTAssertEqual(error, .nil)
            XCTAssertEqual(result, .string("ok"))
        } else {
            XCTFail("Expected response message")
        }
    }

    func testDecodeNotification() throws {
        let notification: MessagePackValue = .array([.uint(2), .string("redraw"), .array([])])
        let data = pack(notification)

        let messages = try MsgpackRpc.decode(data: data)
        XCTAssertEqual(messages.count, 1)

        if case .notification(let method, let params) = messages[0] {
            XCTAssertEqual(method, "redraw")
            XCTAssertEqual(params, .array([]))
        } else {
            XCTFail("Expected notification message")
        }
    }

    func testDecodeMultipleMessagesInOneChunk() throws {
        let msg1: MessagePackValue = .array([.uint(1), .uint(1), .nil, .bool(true)])
        let msg2: MessagePackValue = .array([.uint(2), .string("flush"), .array([])])
        var data = pack(msg1)
        data.append(pack(msg2))

        let messages = try MsgpackRpc.decode(data: data)
        XCTAssertEqual(messages.count, 2)
    }

    func testDecodePartialData() throws {
        let full: MessagePackValue = .array([.uint(1), .uint(1), .nil, .string("ok")])
        let data = pack(full)
        // Take only first half
        let partial = Data(data.prefix(data.count / 2))

        // Should return empty — not enough data for a complete message
        let messages = try MsgpackRpc.decode(data: partial)
        // Partial data handling depends on implementation; at minimum, should not crash
        XCTAssertTrue(messages.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|error|BUILD'`

Expected: Compilation errors — `MsgpackRpc` not defined.

- [ ] **Step 3: Implement MsgpackRpc**

```swift
// MacNeovim/Nvim/MsgpackRpc.swift

import Foundation
import MessagePack

enum RpcMessage: Sendable {
    case response(msgid: UInt32, error: MessagePackValue, result: MessagePackValue)
    case notification(method: String, params: MessagePackValue)
    case request(msgid: UInt32, method: String, params: MessagePackValue)
}

actor MsgpackRpc {
    private var nextMsgid: UInt32 = 0
    private var pendingRequests: [UInt32: CheckedContinuation<(MessagePackValue, MessagePackValue), Never>] = [:]
    private var eventContinuation: AsyncStream<RpcMessage>.Continuation?

    private let inPipe: FileHandle   // write to nvim stdin
    private let outPipe: FileHandle  // read from nvim stdout

    lazy var notifications: AsyncStream<RpcMessage> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }()

    init(inPipe: FileHandle, outPipe: FileHandle) {
        self.inPipe = inPipe
        self.outPipe = outPipe
    }

    func start() async {
        let stream = outPipe.asyncBytes
        var accumulated = Data()
        do {
            for try await byte in stream {
                accumulated.append(byte)
                // Try to unpack complete messages from accumulated data
                do {
                    let messages = try Self.decodeAccumulated(data: &accumulated)
                    for message in messages {
                        switch message {
                        case .response(let msgid, let error, let result):
                            if let continuation = pendingRequests.removeValue(forKey: msgid) {
                                continuation.resume(returning: (error, result))
                            }
                        case .notification, .request:
                            eventContinuation?.yield(message)
                        }
                    }
                } catch {
                    // Incomplete data — continue accumulating
                }
            }
        } catch {
            // Stream ended (pipe closed)
        }
        eventContinuation?.finish()
        // Complete any pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(returning: (.string("channel closed"), .nil))
        }
        pendingRequests.removeAll()
    }

    func request(method: String, params: [MessagePackValue]) async -> (error: MessagePackValue, result: MessagePackValue) {
        let msgid = nextMsgid
        nextMsgid += 1
        let data = Self.encodeRequest(msgid: msgid, method: method, params: params)

        // Register continuation BEFORE writing to pipe — if the response
        // arrives between write and registration, we'd silently drop it.
        return await withCheckedContinuation { continuation in
            pendingRequests[msgid] = continuation
            inPipe.write(data)
        }
    }

    // MARK: - Static encode/decode (testable without actor)

    static func encodeRequest(msgid: UInt32, method: String, params: [MessagePackValue]) -> Data {
        let message: MessagePackValue = .array([
            .uint(0),
            .uint(UInt64(msgid)),
            .string(method),
            .array(params),
        ])
        return pack(message)
    }

    static func decode(data: Data) throws -> [RpcMessage] {
        var mutableData = data
        return try decodeAccumulated(data: &mutableData)
    }

    static func decodeAccumulated(data: inout Data) throws -> [RpcMessage] {
        var messages: [RpcMessage] = []
        while !data.isEmpty {
            let (value, remainder) = try unpack(data)
            data = Data(remainder)
            guard let array = value.arrayValue, array.count >= 3 else { continue }
            guard let type = array[0].unsignedIntegerValue else { continue }

            switch type {
            case 0: // request
                guard array.count >= 4,
                      let msgid = array[1].unsignedIntegerValue,
                      let method = array[2].stringValue else { continue }
                messages.append(.request(msgid: UInt32(msgid), method: method, params: array[3]))
            case 1: // response
                guard array.count >= 4,
                      let msgid = array[1].unsignedIntegerValue else { continue }
                messages.append(.response(msgid: UInt32(msgid), error: array[2], result: array[3]))
            case 2: // notification
                guard let method = array[1].stringValue else { continue }
                messages.append(.notification(method: method, params: array[2]))
            default:
                continue
            }
        }
        return messages
    }
}

extension FileHandle {
    var asyncBytes: AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                for byte in data {
                    continuation.yield(byte)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|BUILD'`

Expected: All `MsgpackRpcTests` pass.

- [ ] **Step 5: Commit**

```bash
git add MacNeovim/Nvim/MsgpackRpc.swift MacNeovimTests/MsgpackRpcTests.swift
git commit -m "Add MsgpackRpc actor for msgpack-rpc message pump"
```

---

### Task 3: NvimEvent — Typed UI Protocol Events

**Files:**
- Create: `MacNeovim/Nvim/NvimEvent.swift`
- Create: `MacNeovimTests/NvimEventParserTests.swift`

**Context:** Neovim sends `redraw` notifications containing batched UI events. Each `redraw` notification has params like `[["grid_line", ...args], ["grid_line", ...args], ["flush"]]`. This task parses raw MessagePackValues into a strongly-typed Swift enum. The event format follows neovim's `ext_linegrid` UI protocol.

**Reference:** `vimr/NvimView/Sources/NvimView/NvimView+UiBridge.swift` (694 lines) for the event type strings and their argument formats.

- [ ] **Step 1: Write failing tests for event parsing**

```swift
// MacNeovimTests/NvimEventParserTests.swift

import XCTest
import MessagePack
@testable import MacNeovim

final class NvimEventParserTests: XCTestCase {

    func testParseFlush() {
        let events = NvimEvent.parse(redrawArgs: [.array([.string("flush")])])
        XCTAssertEqual(events.count, 1)
        if case .flush = events[0] {} else { XCTFail("Expected flush") }
    }

    func testParseGridResize() {
        // grid_resize event: ["grid_resize", grid, width, height]
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("grid_resize"), .int(1), .int(80), .int(24)])
        ])
        XCTAssertEqual(events.count, 1)
        if case .gridResize(let grid, let width, let height) = events[0] {
            XCTAssertEqual(grid, 1)
            XCTAssertEqual(width, 80)
            XCTAssertEqual(height, 24)
        } else {
            XCTFail("Expected gridResize")
        }
    }

    func testParseGridLine() {
        // grid_line: ["grid_line", grid, row, col_start, [[text, hl_id, repeat]], ...]
        let cells: MessagePackValue = .array([.string("A"), .int(0), .int(1)])
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("grid_line"), .int(1), .int(0), .int(0), .array([cells])])
        ])
        XCTAssertEqual(events.count, 1)
        if case .gridLine(let grid, let row, let colStart, let cellData) = events[0] {
            XCTAssertEqual(grid, 1)
            XCTAssertEqual(row, 0)
            XCTAssertEqual(colStart, 0)
            XCTAssertEqual(cellData.count, 1)
            XCTAssertEqual(cellData[0].text, "A")
            XCTAssertEqual(cellData[0].hlId, 0)
            XCTAssertEqual(cellData[0].repeats, 1)
        } else {
            XCTFail("Expected gridLine")
        }
    }

    func testParseGridLineWithRepeat() {
        // Cell with repeat: [" ", 0, 80] means 80 spaces
        let cells: MessagePackValue = .array([.string(" "), .int(0), .int(80)])
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("grid_line"), .int(1), .int(0), .int(0), .array([cells])])
        ])
        if case .gridLine(_, _, _, let cellData) = events[0] {
            XCTAssertEqual(cellData[0].repeats, 80)
        } else {
            XCTFail("Expected gridLine")
        }
    }

    func testParseHlAttrDefine() {
        let rgb: MessagePackValue = .map([
            .string("foreground"): .int(0xFF0000),
            .string("background"): .int(0x000000),
            .string("bold"): .bool(true),
        ])
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("hl_attr_define"), .int(1), rgb, .map([:]), .array([])])
        ])
        XCTAssertEqual(events.count, 1)
        if case .hlAttrDefine(let id, let attrs) = events[0] {
            XCTAssertEqual(id, 1)
            XCTAssertEqual(attrs.foreground, 0xFF0000)
            XCTAssertEqual(attrs.background, 0x000000)
            XCTAssertTrue(attrs.bold)
        } else {
            XCTFail("Expected hlAttrDefine")
        }
    }

    func testParseDefaultColorsSet() {
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("default_colors_set"), .int(0xFFFFFF), .int(0x000000), .int(0xFF0000), .int(0), .int(0)])
        ])
        if case .defaultColorsSet(let fg, let bg, let sp) = events[0] {
            XCTAssertEqual(fg, 0xFFFFFF)
            XCTAssertEqual(bg, 0x000000)
            XCTAssertEqual(sp, 0xFF0000)
        } else {
            XCTFail("Expected defaultColorsSet")
        }
    }

    func testParseGridScroll() {
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("grid_scroll"), .int(1), .int(0), .int(24), .int(0), .int(80), .int(1), .int(0)])
        ])
        if case .gridScroll(_, let top, let bottom, let left, let right, let rows, let cols) = events[0] {
            XCTAssertEqual(top, 0)
            XCTAssertEqual(bottom, 24)
            XCTAssertEqual(left, 0)
            XCTAssertEqual(right, 80)
            XCTAssertEqual(rows, 1)
            XCTAssertEqual(cols, 0)
        } else {
            XCTFail("Expected gridScroll")
        }
    }

    func testParseGridCursorGoto() {
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("grid_cursor_goto"), .int(1), .int(5), .int(10)])
        ])
        if case .gridCursorGoto(_, let row, let col) = events[0] {
            XCTAssertEqual(row, 5)
            XCTAssertEqual(col, 10)
        } else {
            XCTFail("Expected gridCursorGoto")
        }
    }

    func testParseModeChange() {
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("mode_change"), .string("insert"), .int(1)])
        ])
        if case .modeChange(let name, let index) = events[0] {
            XCTAssertEqual(name, "insert")
            XCTAssertEqual(index, 1)
        } else {
            XCTFail("Expected modeChange")
        }
    }

    func testParseTablineUpdate() {
        let tab: MessagePackValue = .map([
            .string("tab"): .ext(1, Data([0, 0, 0, 1])),  // tabpage handle
            .string("name"): .string("[No Name]"),
        ])
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("tabline_update"), .ext(1, Data([0, 0, 0, 1])), .array([tab])])
        ])
        if case .tablineUpdate(let current, let tabs) = events[0] {
            XCTAssertEqual(tabs.count, 1)
            XCTAssertEqual(tabs[0].name, "[No Name]")
        } else {
            XCTFail("Expected tablineUpdate, got: \(events)")
        }
    }

    func testParseMultipleEventsInOneRedraw() {
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("grid_clear"), .int(1)]),
            .array([.string("grid_resize"), .int(1), .int(80), .int(24)]),
            .array([.string("flush")]),
        ])
        XCTAssertEqual(events.count, 3)
    }

    func testParseSetTitle() {
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("set_title"), .string("test.swift")])
        ])
        if case .setTitle(let title) = events[0] {
            XCTAssertEqual(title, "test.swift")
        } else {
            XCTFail("Expected setTitle")
        }
    }

    func testUnknownEventIsIgnored() {
        let events = NvimEvent.parse(redrawArgs: [
            .array([.string("some_future_event"), .int(42)])
        ])
        XCTAssertTrue(events.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|error|BUILD'`

Expected: Compilation errors — `NvimEvent` not defined.

- [ ] **Step 3: Implement NvimEvent**

```swift
// MacNeovim/Nvim/NvimEvent.swift

import Foundation
import MessagePack

/// Cell data from a grid_line event.
struct GridCellData: Equatable, Sendable {
    let text: String
    let hlId: Int
    let repeats: Int
}

/// Tab info from a tabline_update event.
struct TabpageInfo: Equatable, Sendable {
    let handle: MessagePackValue  // ext type, opaque to us
    let name: String
}

/// Mode info from mode_info_set event.
struct ModeInfo: Sendable {
    let name: String
    let cursorShape: CursorShape
    let cellPercentage: Int

    enum CursorShape: String, Sendable {
        case block
        case horizontal
        case vertical
    }
}

enum NvimEvent: Sendable {
    // Grid events
    case gridResize(grid: Int, width: Int, height: Int)
    case gridLine(grid: Int, row: Int, colStart: Int, cells: [GridCellData])
    case gridClear(grid: Int)
    case gridCursorGoto(grid: Int, row: Int, col: Int)
    case gridScroll(grid: Int, top: Int, bottom: Int, left: Int, right: Int, rows: Int, cols: Int)
    case flush

    // Appearance
    case hlAttrDefine(id: Int, attrs: CellAttributes)
    case defaultColorsSet(fg: Int, bg: Int, sp: Int)

    // Mode
    case modeChange(name: String, index: Int)
    case modeInfoSet(enabled: Bool, modes: [ModeInfo])

    // Tabline
    case tablineUpdate(current: MessagePackValue, tabs: [TabpageInfo])

    // Window
    case setTitle(String)

    // Options
    case optionSet(name: String, value: MessagePackValue)

    // Misc
    case bell
    case visualBell
    case mouseOn
    case mouseOff
    case busyStart
    case busyStop

    /// Parse a redraw notification's params into typed events.
    /// Each param is an array: [event_name, ...args] or [event_name, ...args1, ...args2]
    /// where args can repeat (multiple invocations batched).
    static func parse(redrawArgs: [MessagePackValue]) -> [NvimEvent] {
        var events: [NvimEvent] = []
        for arg in redrawArgs {
            guard let array = arg.arrayValue,
                  let name = array.first?.stringValue else { continue }

            let args = Array(array.dropFirst())

            switch name {
            case "flush":
                events.append(.flush)

            case "grid_resize":
                guard args.count >= 3 else { continue }
                events.append(.gridResize(
                    grid: args[0].intValue,
                    width: args[1].intValue,
                    height: args[2].intValue
                ))

            case "grid_line":
                guard args.count >= 4 else { continue }
                let cells = parseGridLineCells(args[3])
                events.append(.gridLine(
                    grid: args[0].intValue,
                    row: args[1].intValue,
                    colStart: args[2].intValue,
                    cells: cells
                ))

            case "grid_clear":
                events.append(.gridClear(grid: args.first?.intValue ?? 1))

            case "grid_cursor_goto":
                guard args.count >= 3 else { continue }
                events.append(.gridCursorGoto(
                    grid: args[0].intValue,
                    row: args[1].intValue,
                    col: args[2].intValue
                ))

            case "grid_scroll":
                guard args.count >= 7 else { continue }
                events.append(.gridScroll(
                    grid: args[0].intValue,
                    top: args[1].intValue,
                    bottom: args[2].intValue,
                    left: args[3].intValue,
                    right: args[4].intValue,
                    rows: args[5].intValue,
                    cols: args[6].intValue
                ))

            case "hl_attr_define":
                guard args.count >= 2 else { continue }
                let id = args[0].intValue
                let attrs = CellAttributes(from: args[1])
                events.append(.hlAttrDefine(id: id, attrs: attrs))

            case "default_colors_set":
                guard args.count >= 3 else { continue }
                events.append(.defaultColorsSet(
                    fg: args[0].intValue,
                    bg: args[1].intValue,
                    sp: args[2].intValue
                ))

            case "mode_change":
                guard args.count >= 2 else { continue }
                events.append(.modeChange(
                    name: args[0].stringValue ?? "",
                    index: args[1].intValue
                ))

            case "mode_info_set":
                guard args.count >= 2, let modesArray = args[1].arrayValue else { continue }
                let modes = modesArray.compactMap { parseModeInfo($0) }
                events.append(.modeInfoSet(
                    enabled: args[0].boolValue ?? true,
                    modes: modes
                ))

            case "tabline_update":
                guard args.count >= 2, let tabsArray = args[1].arrayValue else { continue }
                let current = args[0]
                let tabs = tabsArray.compactMap { parseTabpageInfo($0) }
                events.append(.tablineUpdate(current: current, tabs: tabs))

            case "set_title":
                guard let title = args.first?.stringValue else { continue }
                events.append(.setTitle(title))

            case "option_set":
                // option_set can batch multiple: [name, value, name, value, ...]
                // But typically each option_set call has its own array entry
                guard args.count >= 2 else { continue }
                events.append(.optionSet(name: args[0].stringValue ?? "", value: args[1]))

            case "bell":
                events.append(.bell)
            case "visual_bell":
                events.append(.visualBell)
            case "mouse_on":
                events.append(.mouseOn)
            case "mouse_off":
                events.append(.mouseOff)
            case "busy_start":
                events.append(.busyStart)
            case "busy_stop":
                events.append(.busyStop)

            default:
                break // Unknown events are silently ignored (forward compatibility)
            }
        }
        return events
    }

    // MARK: - Private parsing helpers

    private static func parseGridLineCells(_ value: MessagePackValue) -> [GridCellData] {
        guard let chunks = value.arrayValue else { return [] }
        var result: [GridCellData] = []
        var lastHlId = 0

        for chunk in chunks {
            guard let parts = chunk.arrayValue, !parts.isEmpty else { continue }
            let text = parts[0].stringValue ?? ""
            let hlId = parts.count > 1 ? parts[1].intValue : lastHlId
            let repeats = parts.count > 2 ? parts[2].intValue : 1
            lastHlId = hlId
            result.append(GridCellData(text: text, hlId: hlId, repeats: repeats))
        }
        return result
    }

    private static func parseModeInfo(_ value: MessagePackValue) -> ModeInfo? {
        guard let dict = value.dictionaryValue else { return nil }
        let name = dict[.string("name")]?.stringValue ?? ""
        let shapeStr = dict[.string("cursor_shape")]?.stringValue ?? "block"
        let shape = ModeInfo.CursorShape(rawValue: shapeStr) ?? .block
        let pct = dict[.string("cell_percentage")]?.intValue ?? 0
        return ModeInfo(name: name, cursorShape: shape, cellPercentage: pct)
    }

    private static func parseTabpageInfo(_ value: MessagePackValue) -> TabpageInfo? {
        guard let dict = value.dictionaryValue else { return nil }
        let handle = dict[.string("tab")] ?? .nil
        let name = dict[.string("name")]?.stringValue ?? ""
        return TabpageInfo(handle: handle, name: name)
    }
}

// MARK: - MessagePackValue convenience

extension MessagePackValue {
    var intValue: Int {
        switch self {
        case .int(let v): return Int(v)
        case .uint(let v): return Int(v)
        default: return 0
        }
    }
}
```

Note: `CellAttributes` is used here and will be created in Task 4. For now, add a minimal stub so this compiles:

```swift
// MacNeovim/Grid/CellAttributes.swift (stub — full implementation in Task 4)

import Foundation
import MessagePack

struct CellAttributes: Equatable, Sendable {
    var foreground: Int
    var background: Int
    var special: Int
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var undercurl: Bool
    var underdouble: Bool
    var underdotted: Bool
    var underdashed: Bool
    var strikethrough: Bool
    var reverse: Bool
    var blend: Int  // 0-100, for floating windows

    init(
        foreground: Int = -1, background: Int = -1, special: Int = -1,
        bold: Bool = false, italic: Bool = false, underline: Bool = false,
        undercurl: Bool = false, underdouble: Bool = false, underdotted: Bool = false,
        underdashed: Bool = false, strikethrough: Bool = false, reverse: Bool = false,
        blend: Int = 0
    ) {
        self.foreground = foreground
        self.background = background
        self.special = special
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.undercurl = undercurl
        self.underdouble = underdouble
        self.underdotted = underdotted
        self.underdashed = underdashed
        self.strikethrough = strikethrough
        self.reverse = reverse
        self.blend = blend
    }

    init(from value: MessagePackValue) {
        guard let dict = value.dictionaryValue else {
            self.init()
            return
        }
        self.init(
            foreground: dict[.string("foreground")]?.intValue ?? -1,
            background: dict[.string("background")]?.intValue ?? -1,
            special: dict[.string("special")]?.intValue ?? -1,
            bold: dict[.string("bold")]?.boolValue ?? false,
            italic: dict[.string("italic")]?.boolValue ?? false,
            underline: dict[.string("underline")]?.boolValue ?? false,
            undercurl: dict[.string("undercurl")]?.boolValue ?? false,
            underdouble: dict[.string("underdouble")]?.boolValue ?? false,
            underdotted: dict[.string("underdotted")]?.boolValue ?? false,
            underdashed: dict[.string("underdashed")]?.boolValue ?? false,
            strikethrough: dict[.string("strikethrough")]?.boolValue ?? false,
            reverse: dict[.string("reverse")]?.boolValue ?? false,
            blend: dict[.string("blend")]?.intValue ?? 0
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|BUILD'`

Expected: All `NvimEventParserTests` pass.

- [ ] **Step 5: Commit**

```bash
git add MacNeovim/Nvim/NvimEvent.swift MacNeovim/Grid/CellAttributes.swift MacNeovimTests/NvimEventParserTests.swift
git commit -m "Add NvimEvent parser for neovim UI protocol events"
```

---

### Task 4: Grid Model — Cell Array and Dirty Tracking

**Files:**
- Create: `MacNeovim/Grid/Grid.swift`
- Create: `MacNeovim/Grid/Cell.swift`
- Modify: `MacNeovim/Grid/CellAttributes.swift` (expand stub from Task 3)
- Create: `MacNeovimTests/GridTests.swift`
- Create: `MacNeovimTests/CellAttributesTests.swift`

**Context:** Grid is the in-memory representation of the neovim screen. It's a `@MainActor` reference type (class) because the grid can be large (10,000+ cells) and is owned exclusively by one WindowDocument. It accumulates dirty rows and exposes them for the renderer.

**Reference:** `vimr/NvimView/Sources/NvimView/UGrid.swift` (419 lines) for the scroll algorithm and cell data structure.

- [ ] **Step 1: Write failing tests for CellAttributes**

```swift
// MacNeovimTests/CellAttributesTests.swift

import XCTest
import MessagePack
@testable import MacNeovim

final class CellAttributesTests: XCTestCase {

    func testDefaultAttributes() {
        let attrs = CellAttributes()
        XCTAssertEqual(attrs.foreground, -1)
        XCTAssertEqual(attrs.background, -1)
        XCTAssertFalse(attrs.bold)
        XCTAssertFalse(attrs.reverse)
    }

    func testEffectiveColorsNormal() {
        let attrs = CellAttributes(foreground: 0xFFFFFF, background: 0x000000)
        XCTAssertEqual(attrs.effectiveForeground(defaultFg: 0xAAAAAA, defaultBg: 0x333333), 0xFFFFFF)
        XCTAssertEqual(attrs.effectiveBackground(defaultFg: 0xAAAAAA, defaultBg: 0x333333), 0x000000)
    }

    func testEffectiveColorsDefaultFallback() {
        let attrs = CellAttributes()  // foreground = -1, background = -1
        XCTAssertEqual(attrs.effectiveForeground(defaultFg: 0xAAAAAA, defaultBg: 0x333333), 0xAAAAAA)
        XCTAssertEqual(attrs.effectiveBackground(defaultFg: 0xAAAAAA, defaultBg: 0x333333), 0x333333)
    }

    func testEffectiveColorsReversed() {
        let attrs = CellAttributes(foreground: 0xFFFFFF, background: 0x000000, reverse: true)
        XCTAssertEqual(attrs.effectiveForeground(defaultFg: 0, defaultBg: 0), 0x000000)
        XCTAssertEqual(attrs.effectiveBackground(defaultFg: 0, defaultBg: 0), 0xFFFFFF)
    }

    func testEffectiveColorsReversedWithDefaults() {
        // When background is default (-1) and reverse is true, effective fg should use defaultBg
        let attrs = CellAttributes(foreground: 0xFFFFFF, reverse: true)  // background = -1
        XCTAssertEqual(attrs.effectiveForeground(defaultFg: 0xAAAAAA, defaultBg: 0x333333), 0x333333)
        XCTAssertEqual(attrs.effectiveBackground(defaultFg: 0xAAAAAA, defaultBg: 0x333333), 0xFFFFFF)
    }

    func testParseFromMessagePack() {
        let dict: MessagePackValue = .map([
            .string("foreground"): .int(0xFF0000),
            .string("bold"): .bool(true),
            .string("italic"): .bool(true),
        ])
        let attrs = CellAttributes(from: dict)
        XCTAssertEqual(attrs.foreground, 0xFF0000)
        XCTAssertTrue(attrs.bold)
        XCTAssertTrue(attrs.italic)
        XCTAssertFalse(attrs.underline)
    }
}
```

- [ ] **Step 2: Write failing tests for Grid**

```swift
// MacNeovimTests/GridTests.swift

import XCTest
@testable import MacNeovim

@MainActor
final class GridTests: XCTestCase {

    func testGridResize() {
        let grid = Grid()
        grid.resize(rows: 24, cols: 80)
        XCTAssertEqual(grid.size, GridSize(rows: 24, cols: 80))
        XCTAssertEqual(grid.cells.count, 24)
        XCTAssertEqual(grid.cells[0].count, 80)
        // All cells should be space with hlId 0
        XCTAssertEqual(grid.cells[0][0].text, " ")
        XCTAssertEqual(grid.cells[0][0].hlId, 0)
    }

    func testGridLine() {
        let grid = Grid()
        grid.resize(rows: 24, cols: 80)
        grid.putCells(row: 0, colStart: 0, cells: [
            GridCellData(text: "H", hlId: 1, repeats: 1),
            GridCellData(text: "i", hlId: 1, repeats: 1),
        ])
        XCTAssertEqual(grid.cells[0][0].text, "H")
        XCTAssertEqual(grid.cells[0][1].text, "i")
        XCTAssertEqual(grid.cells[0][0].hlId, 1)
        XCTAssertTrue(grid.dirtyRows.contains(0))
    }

    func testGridLineWithRepeat() {
        let grid = Grid()
        grid.resize(rows: 24, cols: 80)
        grid.putCells(row: 0, colStart: 0, cells: [
            GridCellData(text: " ", hlId: 0, repeats: 5),
        ])
        // 5 cells should be filled
        for col in 0..<5 {
            XCTAssertEqual(grid.cells[0][col].text, " ")
        }
    }

    func testClearDirty() {
        let grid = Grid()
        grid.resize(rows: 24, cols: 80)
        grid.putCells(row: 0, colStart: 0, cells: [GridCellData(text: "X", hlId: 0, repeats: 1)])
        XCTAssertFalse(grid.dirtyRows.isEmpty)
        grid.clearDirty()
        XCTAssertTrue(grid.dirtyRows.isEmpty)
    }

    func testGridClear() {
        let grid = Grid()
        grid.resize(rows: 24, cols: 80)
        grid.putCells(row: 0, colStart: 0, cells: [GridCellData(text: "X", hlId: 1, repeats: 1)])
        grid.clearDirty()
        grid.clear()
        XCTAssertEqual(grid.cells[0][0].text, " ")
        XCTAssertEqual(grid.cells[0][0].hlId, 0)
        // All rows should be dirty after clear
        XCTAssertEqual(grid.dirtyRows.count, 24)
    }

    func testScrollDown() {
        let grid = Grid()
        grid.resize(rows: 5, cols: 10)
        grid.putCells(row: 0, colStart: 0, cells: [GridCellData(text: "A", hlId: 0, repeats: 1)])
        grid.putCells(row: 1, colStart: 0, cells: [GridCellData(text: "B", hlId: 0, repeats: 1)])
        grid.putCells(row: 2, colStart: 0, cells: [GridCellData(text: "C", hlId: 0, repeats: 1)])
        grid.clearDirty()

        // Scroll 1 row up (content moves up, bottom row becomes empty)
        grid.scroll(region: Region(top: 0, bottom: 4, left: 0, right: 9), rows: 1, cols: 0)

        XCTAssertEqual(grid.cells[0][0].text, "B")  // row 1 moved to row 0
        XCTAssertEqual(grid.cells[1][0].text, "C")  // row 2 moved to row 1
        XCTAssertEqual(grid.cells[4][0].text, " ")  // bottom row cleared
    }

    func testScrollUp() {
        let grid = Grid()
        grid.resize(rows: 5, cols: 10)
        grid.putCells(row: 2, colStart: 0, cells: [GridCellData(text: "X", hlId: 0, repeats: 1)])
        grid.putCells(row: 3, colStart: 0, cells: [GridCellData(text: "Y", hlId: 0, repeats: 1)])
        grid.clearDirty()

        // Scroll 1 row down (content moves down, top row becomes empty)
        grid.scroll(region: Region(top: 0, bottom: 4, left: 0, right: 9), rows: -1, cols: 0)

        XCTAssertEqual(grid.cells[3][0].text, "X")  // row 2 moved to row 3
        XCTAssertEqual(grid.cells[4][0].text, "Y")  // row 3 moved to row 4
        XCTAssertEqual(grid.cells[0][0].text, " ")  // top row cleared
    }

    func testCursorGoto() {
        let grid = Grid()
        grid.resize(rows: 24, cols: 80)
        grid.cursorGoto(row: 5, col: 10)
        XCTAssertEqual(grid.cursorPosition, Position(row: 5, col: 10))
    }

    func testHlAttrDefine() {
        let grid = Grid()
        let attrs = CellAttributes(foreground: 0xFF0000, bold: true)
        grid.defineHighlight(id: 1, attrs: attrs)
        XCTAssertEqual(grid.attributes[1]?.foreground, 0xFF0000)
        XCTAssertTrue(grid.attributes[1]?.bold ?? false)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|error|BUILD'`

Expected: Compilation errors — `Grid`, `Cell` not defined.

- [ ] **Step 4: Expand CellAttributes with effective color methods**

Update `MacNeovim/Grid/CellAttributes.swift` — add `effectiveForeground(default:)` and `effectiveBackground(default:)`:

```swift
// Add to CellAttributes struct:

func effectiveForeground(default defaultFg: Int) -> Int {
    let fg = foreground == -1 ? defaultFg : foreground
    let bg = background == -1 ? defaultFg : background  // intentional: default for bg uses defaultFg in reverse
    return reverse ? (background == -1 ? defaultFg : background) : fg
}

func effectiveBackground(default defaultBg: Int) -> Int {
    let fg = foreground == -1 ? defaultBg : foreground
    let bg = background == -1 ? defaultBg : background
    return reverse ? (foreground == -1 ? defaultBg : foreground) : bg
}
```

The logic: resolve both colors using their respective defaults, then swap if reversed.

Add to `CellAttributes`:
```swift
func effectiveForeground(defaultFg: Int, defaultBg: Int) -> Int {
    let fg = foreground >= 0 ? foreground : defaultFg
    let bg = background >= 0 ? background : defaultBg
    return reverse ? bg : fg
}

func effectiveBackground(defaultFg: Int, defaultBg: Int) -> Int {
    let fg = foreground >= 0 ? foreground : defaultFg
    let bg = background >= 0 ? background : defaultBg
    return reverse ? fg : bg
}
```

- [ ] **Step 5: Implement Cell**

```swift
// MacNeovim/Grid/Cell.swift

import Foundation

struct Cell: Equatable, Sendable {
    var text: String
    var hlId: Int
    var utf16Length: Int  // cached for IME character index mapping

    static let empty = Cell(text: " ", hlId: 0, utf16Length: 1)
}
```

- [ ] **Step 6: Implement Grid**

```swift
// MacNeovim/Grid/Grid.swift

import Foundation

@MainActor
final class Grid {
    private(set) var cells: [[Cell]] = []
    private(set) var size: GridSize = .zero
    private(set) var cursorPosition: Position = .zero
    private(set) var dirtyRows = IndexSet()
    private(set) var attributes: [Int: CellAttributes] = [:]
    private(set) var defaultForeground: Int = 0xFFFFFF
    private(set) var defaultBackground: Int = 0x000000
    private(set) var defaultSpecial: Int = 0xFF0000
    private(set) var flatCharIndices: [[Int]] = []  // per-cell character index for IME

    func resize(rows: Int, cols: Int) {
        size = GridSize(rows: rows, cols: cols)
        cells = Array(repeating: Array(repeating: Cell.empty, count: cols), count: rows)
        dirtyRows = IndexSet(integersIn: 0..<rows)
        recomputeFlatCharIndices()
    }

    func putCells(row: Int, colStart: Int, cells cellData: [GridCellData]) {
        guard row >= 0, row < size.rows else { return }
        var col = colStart
        for data in cellData {
            let utf16Len = data.text.utf16.count
            for _ in 0..<data.repeats {
                guard col < size.cols else { break }
                cells[row][col] = Cell(text: data.text, hlId: data.hlId, utf16Length: utf16Len)
                col += 1
            }
        }
        dirtyRows.insert(row)
        recomputeFlatCharIndices(row: row)
    }

    func clear() {
        for row in 0..<size.rows {
            for col in 0..<size.cols {
                cells[row][col] = .empty
            }
        }
        dirtyRows = IndexSet(integersIn: 0..<size.rows)
    }

    func cursorGoto(row: Int, col: Int) {
        cursorPosition = Position(row: row, col: col)
    }

    func scroll(region: Region, rows: Int, cols: Int) {
        guard rows != 0 else { return }

        let rangeWithinRow = region.left...region.right

        if rows > 0 {
            // Scroll up: shift rows upward
            for i in region.top..<(region.bottom - rows + 1) {
                cells[i].replaceSubrange(rangeWithinRow, with: cells[i + rows][rangeWithinRow])
            }
            // Clear bottom rows
            for i in (region.bottom - rows + 1)...region.bottom {
                for col in rangeWithinRow {
                    cells[i][col] = .empty
                }
                dirtyRows.insert(i)
            }
        } else {
            // Scroll down: shift rows downward
            let absRows = abs(rows)
            for i in stride(from: region.bottom, through: region.top + absRows, by: -1) {
                cells[i].replaceSubrange(rangeWithinRow, with: cells[i + rows][rangeWithinRow])
            }
            // Clear top rows
            for i in region.top..<(region.top + absRows) {
                for col in rangeWithinRow {
                    cells[i][col] = .empty
                }
                dirtyRows.insert(i)
            }
        }

        // Mark all affected rows as dirty
        for i in region.top...region.bottom {
            dirtyRows.insert(i)
        }
    }

    func defineHighlight(id: Int, attrs: CellAttributes) {
        attributes[id] = attrs
    }

    func setDefaultColors(fg: Int, bg: Int, sp: Int) {
        defaultForeground = fg
        defaultBackground = bg
        defaultSpecial = sp
    }

    func clearDirty() {
        dirtyRows = IndexSet()
    }

    // MARK: - Flat character indices for IME

    private func recomputeFlatCharIndices() {
        flatCharIndices = cells.map { row in
            var index = 0
            return row.map { cell in
                let current = index
                index += cell.utf16Length
                return current
            }
        }
    }

    private func recomputeFlatCharIndices(row: Int) {
        guard row < flatCharIndices.count else {
            recomputeFlatCharIndices()
            return
        }
        var index = 0
        flatCharIndices[row] = cells[row].map { cell in
            let current = index
            index += cell.utf16Length
            return current
        }
    }

    /// Apply a single NvimEvent to the grid.
    func apply(_ event: NvimEvent) {
        switch event {
        case .gridResize(_, let width, let height):
            resize(rows: height, cols: width)
        case .gridLine(_, let row, let colStart, let cellData):
            putCells(row: row, colStart: colStart, cells: cellData)
        case .gridClear:
            clear()
        case .gridCursorGoto(_, let row, let col):
            cursorGoto(row: row, col: col)
        case .gridScroll(_, let top, let bottom, let left, let right, let rows, let cols):
            scroll(region: Region(top: top, bottom: bottom, left: left, right: right), rows: rows, cols: cols)
        case .hlAttrDefine(let id, let attrs):
            defineHighlight(id: id, attrs: attrs)
        case .defaultColorsSet(let fg, let bg, let sp):
            setDefaultColors(fg: fg, bg: bg, sp: sp)
        default:
            break
        }
    }
}
```

- [ ] **Step 7: Run all tests**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|BUILD'`

Expected: All `GridTests` and `CellAttributesTests` pass.

- [ ] **Step 8: Commit**

```bash
git add MacNeovim/Grid/ MacNeovimTests/GridTests.swift MacNeovimTests/CellAttributesTests.swift
git commit -m "Add Grid model with cell array, scroll, and dirty tracking"
```

---

### Task 5: KeyUtils — macOS Key Events to Neovim Notation

**Files:**
- Create: `MacNeovim/Nvim/KeyUtils.swift`
- Create: `MacNeovimTests/KeyUtilsTests.swift`

**Context:** Neovim expects keys in a specific notation: `<C-a>` for Ctrl+A, `<M-x>` for Alt+X, `<D-s>` for Cmd+S, `<CR>` for Enter, `<BS>` for Backspace, etc. This module converts NSEvent key data to that format.

**Reference:** `vimr/NvimView/Sources/NvimView/KeyUtils.swift` for the special key map and `NvimView+Key.swift` for modifier handling.

- [ ] **Step 1: Write failing tests**

```swift
// MacNeovimTests/KeyUtilsTests.swift

import XCTest
import Carbon.HIToolbox
@testable import MacNeovim

final class KeyUtilsTests: XCTestCase {

    func testPlainCharacter() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "a", modifiers: []), "a")
        XCTAssertEqual(KeyUtils.nvimKey(characters: "Z", modifiers: []), "Z")
    }

    func testSpecialCharactersEscaped() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "<", modifiers: []), "<lt>")
        XCTAssertEqual(KeyUtils.nvimKey(characters: "\\", modifiers: []), "<Bslash>")
    }

    func testEnterKey() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "\r", modifiers: []), "<CR>")
    }

    func testEscapeKey() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "\u{1B}", modifiers: []), "<Esc>")
    }

    func testBackspace() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "\u{7F}", modifiers: []), "<BS>")
    }

    func testTab() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "\t", modifiers: []), "<Tab>")
    }

    func testSpace() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: " ", modifiers: []), "<Space>")
    }

    func testArrowKeys() {
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: up, modifiers: []), "<Up>")

        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: down, modifiers: []), "<Down>")
    }

    func testFunctionKeys() {
        let f1 = String(Character(UnicodeScalar(NSF1FunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: f1, modifiers: []), "<F1>")
    }

    func testControlModifier() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "a", modifiers: .control), "<C-a>")
    }

    func testAltModifier() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "x", modifiers: .option), "<M-x>")
    }

    func testCmdModifier() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "s", modifiers: .command), "<D-s>")
    }

    func testMultipleModifiers() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "a", modifiers: [.control, .shift]), "<C-S-a>")
    }

    func testControlWithSpecialKey() {
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: up, modifiers: .control), "<C-Up>")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|error|BUILD'`

Expected: Compilation error — `KeyUtils` not defined.

- [ ] **Step 3: Implement KeyUtils**

```swift
// MacNeovim/Nvim/KeyUtils.swift

import AppKit

enum KeyUtils {
    /// Convert macOS key event data to neovim key notation.
    static func nvimKey(characters: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard let scalar = characters.unicodeScalars.first else { return "" }
        let code = Int(scalar.value)

        // Check for named special key
        if let name = specialKeyName(code) {
            return wrapWithModifiers(name, modifiers: modifiers)
        }

        // Escape key
        if code == 0x1B {
            return wrapWithModifiers("Esc", modifiers: modifiers)
        }

        // Backspace (delete key on Mac)
        if code == 0x7F {
            return wrapWithModifiers("BS", modifiers: modifiers)
        }

        // Tab
        if code == 0x09 {
            return wrapWithModifiers("Tab", modifiers: modifiers)
        }

        // Enter / carriage return
        if code == 0x0D {
            return wrapWithModifiers("CR", modifiers: modifiers)
        }

        // Space
        if code == 0x20 {
            return wrapWithModifiers("Space", modifiers: modifiers)
        }

        // Special characters that need escaping
        if characters == "<" {
            return wrapWithModifiers("lt", modifiers: modifiers)
        }
        if characters == "\\" {
            return wrapWithModifiers("Bslash", modifiers: modifiers)
        }

        // Control codes (Ctrl+letter generates 0x01-0x1A)
        let relevantModifiers = modifiers.intersection([.control, .option, .command, .shift])
        if relevantModifiers.isEmpty {
            return characters
        }

        return wrapWithModifiers(characters, modifiers: modifiers)
    }

    // MARK: - Private

    private static func wrapWithModifiers(_ key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "C-" }
        if modifiers.contains(.shift) { prefix += "S-" }
        if modifiers.contains(.option) { prefix += "M-" }
        if modifiers.contains(.command) { prefix += "D-" }

        if prefix.isEmpty && key.count == 1 && !isNamedKey(key) {
            return key
        }

        return "<\(prefix)\(key)>"
    }

    private static func isNamedKey(_ key: String) -> Bool {
        // Single chars that must be wrapped: lt, Bslash, Space, etc.
        ["lt", "Bslash", "Space", "CR", "Tab", "Esc", "BS"].contains(key)
    }

    private static func specialKeyName(_ code: Int) -> String? {
        specialKeys[code]
    }

    private static let specialKeys: [Int: String] = {
        var map: [Int: String] = [
            NSUpArrowFunctionKey: "Up",
            NSDownArrowFunctionKey: "Down",
            NSLeftArrowFunctionKey: "Left",
            NSRightArrowFunctionKey: "Right",
            NSInsertFunctionKey: "Insert",
            NSDeleteFunctionKey: "Del",
            NSHomeFunctionKey: "Home",
            NSEndFunctionKey: "End",
            NSPageUpFunctionKey: "PageUp",
            NSPageDownFunctionKey: "PageDown",
        ]
        // F1-F35
        for i in 0..<35 {
            map[NSF1FunctionKey + i] = "F\(i + 1)"
        }
        return map
    }()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|BUILD'`

Expected: All `KeyUtilsTests` pass.

- [ ] **Step 5: Commit**

```bash
git add MacNeovim/Nvim/KeyUtils.swift MacNeovimTests/KeyUtilsTests.swift
git commit -m "Add KeyUtils for macOS key event to neovim notation conversion"
```

---

### Task 6: NvimProcess — Neovim Process Lifecycle

**Files:**
- Create: `MacNeovim/Nvim/NvimProcess.swift`

**Context:** Manages launching and stopping a neovim process with `--embed` for pipe-based RPC. Must capture login shell environment for correct PATH resolution. The process uses stdin/stdout as the msgpack-rpc channel.

**Reference:** `vimr/NvimView/Sources/NvimView/NvimProcess.swift` for process launch and `vimr/Commons/Sources/Commons/ProcessUtils.swift` for login shell env capture.

- [ ] **Step 1: Implement NvimProcess**

```swift
// MacNeovim/Nvim/NvimProcess.swift

import Foundation

final class NvimProcess {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    private var process: Process?
    private let nvimPath: String
    private let cwd: String
    private let appName: String
    private let additionalEnv: [String: String]

    var isRunning: Bool { process?.isRunning ?? false }

    init(nvimPath: String = "",
         cwd: String = NSHomeDirectory(),
         appName: String = "nvim",
         additionalEnv: [String: String] = [:]) {
        self.nvimPath = nvimPath
        self.cwd = cwd
        self.appName = appName
        self.additionalEnv = additionalEnv
    }

    /// Launch the nvim process with --embed.
    func start() throws {
        let process = Process()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.qualityOfService = .userInteractive

        // Resolve nvim binary
        let binary = resolveNvimBinary()
        process.executableURL = URL(fileURLWithPath: binary)

        // Build environment from login shell
        var env = Self.loginShellEnvironment()
        env["NVIM_APPNAME"] = appName
        env.merge(additionalEnv) { _, new in new }
        process.environment = env

        process.arguments = ["--embed"]

        try process.run()
        self.process = process
    }

    /// Send quit command and wait for exit, kill if timeout.
    func stop() {
        guard let process, process.isRunning else { return }
        // Close stdin to signal EOF
        stdinPipe.fileHandleForWriting.closeFile()
        // Wait briefly for graceful exit
        let deadline = DispatchTime.now() + .seconds(2)
        DispatchQueue.global().async {
            process.waitUntilExit()
        }
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    var onTermination: ((Int32) -> Void)? {
        didSet {
            process?.terminationHandler = { [weak self] proc in
                self?.onTermination?(proc.terminationStatus)
            }
        }
    }

    // MARK: - Private

    private func resolveNvimBinary() -> String {
        // User-configured path
        if !nvimPath.isEmpty, FileManager.default.isExecutableFile(atPath: nvimPath) {
            return nvimPath
        }
        // Search PATH
        if let path = Self.findInPath("nvim") {
            return path
        }
        // Common Homebrew locations
        for candidate in ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/local/bin/nvim"  // fallback
    }

    private static func findInPath(_ binary: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let pathString = env["PATH"] else { return nil }
        for dir in pathString.split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Capture environment variables from the user's login shell.
    static func loginShellEnvironment() -> [String: String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)

        var args = ["-l"]  // login shell
        if shellName != "tcsh" {
            args.append("-i")  // interactive (for .zshrc)
        }

        let marker = UUID().uuidString
        args.append(contentsOf: ["-c", "echo \(marker) && env"])
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessInfo.processInfo.environment
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return ProcessInfo.processInfo.environment
        }

        // Find marker and parse env after it
        guard let markerRange = output.range(of: marker) else {
            return ProcessInfo.processInfo.environment
        }

        let envString = output[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var env: [String: String] = [:]
        for line in envString.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }

        return env.isEmpty ? ProcessInfo.processInfo.environment : env
    }
}
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add MacNeovim/Nvim/NvimProcess.swift
git commit -m "Add NvimProcess for neovim process lifecycle management"
```

---

### Task 7: NvimChannel — High-Level Neovim Communication

**Files:**
- Create: `MacNeovim/Nvim/NvimChannel.swift`

**Context:** NvimChannel is the public-facing actor that combines NvimProcess + MsgpackRpc. It provides typed API methods (`send(key:)`, `command()`, `request()`) and an `AsyncStream<NvimEvent>` for UI events. This is the single point of contact between WindowDocument and the neovim process.

- [ ] **Step 1: Implement NvimChannel**

```swift
// MacNeovim/Nvim/NvimChannel.swift

import Foundation
import MessagePack

actor NvimChannel {
    private var process: NvimProcess?
    private var rpc: MsgpackRpc?
    private var eventContinuation: AsyncStream<NvimEvent>.Continuation?
    private var rpcTask: Task<Void, Never>?

    let events: AsyncStream<NvimEvent>

    init() {
        // Use makeStream to avoid capturing self during init
        let (stream, continuation) = AsyncStream<NvimEvent>.makeStream()
        self.events = stream
        self.eventContinuation = continuation
    }

    /// Start neovim process and connect RPC.
    func start(nvimPath: String = "", cwd: String = NSHomeDirectory(), appName: String = "nvim") async throws {
        let proc = NvimProcess(nvimPath: nvimPath, cwd: cwd, appName: appName)
        try proc.start()
        self.process = proc

        let rpc = MsgpackRpc(
            inPipe: proc.stdinPipe.fileHandleForWriting,
            outPipe: proc.stdoutPipe.fileHandleForReading
        )
        self.rpc = rpc

        // Start RPC read loop and forward parsed events
        rpcTask = Task {
            // Start the notification listener in parallel with the read loop
            async let readLoop: Void = rpc.start()

            for await message in await rpc.notifications {
                if case .notification(let method, let params) = message, method == "redraw" {
                    guard let args = params.arrayValue else { continue }
                    let events = NvimEvent.parse(redrawArgs: args)
                    for event in events {
                        eventContinuation?.yield(event)
                    }
                }
            }

            await readLoop
            eventContinuation?.finish()
        }
    }

    /// Attach UI with given grid dimensions.
    func uiAttach(width: Int, height: Int) async throws {
        let (error, _) = await request("nvim_ui_attach", params: [
            .int(Int64(width)),
            .int(Int64(height)),
            .map([
                .string("rgb"): .bool(true),
                .string("ext_linegrid"): .bool(true),
                .string("ext_tabline"): .bool(true),
                .string("ext_multigrid"): .bool(false),
            ]),
        ])
        if case .string(let msg) = error { throw NvimChannelError.rpcError(msg) }
        if error != .nil { throw NvimChannelError.rpcError("ui_attach failed: \(error)") }
    }

    /// Send key input to neovim.
    func send(key: String) async {
        _ = await request("nvim_input", params: [.string(key)])
    }

    /// Execute an ex command.
    func command(_ cmd: String) async throws {
        let (error, _) = await request("nvim_command", params: [.string(cmd)])
        if case .string(let msg) = error { throw NvimChannelError.rpcError(msg) }
        if error != .nil { throw NvimChannelError.rpcError("command failed: \(error)") }
    }

    /// Generic RPC request.
    func request(_ method: String, params: [MessagePackValue]) async -> (error: MessagePackValue, result: MessagePackValue) {
        guard let rpc else { return (.string("not connected"), .nil) }
        return await rpc.request(method: method, params: params)
    }

    /// Resize the UI grid.
    func uiTryResize(width: Int, height: Int) async {
        _ = await request("nvim_ui_try_resize", params: [.int(Int64(width)), .int(Int64(height))])
    }

    /// Send mouse input.
    func inputMouse(button: String, action: String, modifier: String, grid: Int, row: Int, col: Int) async {
        _ = await request("nvim_input_mouse", params: [
            .string(button), .string(action), .string(modifier),
            .int(Int64(grid)), .int(Int64(row)), .int(Int64(col)),
        ])
    }

    /// Stop the neovim process.
    func stop() {
        rpcTask?.cancel()
        process?.stop()
        eventContinuation?.finish()
    }
}

enum NvimChannelError: Error, LocalizedError {
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .rpcError(let msg): return "Neovim RPC error: \(msg)"
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add MacNeovim/Nvim/NvimChannel.swift
git commit -m "Add NvimChannel actor for high-level neovim communication"
```

---

### Task 8: NvimView — First Visual Milestone

**Files:**
- Create: `MacNeovim/Rendering/NvimView.swift`
- Create: `MacNeovim/Rendering/NvimView+Keyboard.swift`
- Create: `MacNeovim/Rendering/GlyphCache.swift`
**Context:** This is the first visual milestone — neovim renders in a window. NvimView is a layer-backed NSView that renders grid content using CoreText + CALayer. Each row is a CALayer with its content rendered as a CGImage from the glyph cache. Initial keyboard input (without IME) is also wired up here.

**Reference:**
- `vimr/NvimView/Sources/NvimView/NvimView+Draw.swift` for the rendering pipeline
- `vimr/NvimView/Sources/NvimView/AttributesRunDrawer.swift` for CoreText usage
- `vimr/NvimView/Sources/NvimView/NvimView+Key.swift` for keyboard handling

- [ ] **Step 1: Implement GlyphCache**

```swift
// MacNeovim/Rendering/GlyphCache.swift

import AppKit

final class GlyphCache {
    struct Key: Hashable {
        let text: String
        let fontName: String
        let fontSize: CGFloat
        let bold: Bool
        let italic: Bool
        let foreground: Int
        let background: Int
    }

    private var cache: [Key: CGImage] = [:]

    func image(for text: String, cellSize: CGSize, font: NSFont, bold: Bool, italic: Bool,
               foreground: NSColor, background: NSColor) -> CGImage? {
        let key = Key(
            text: text,
            fontName: font.fontName,
            fontSize: font.pointSize,
            bold: bold,
            italic: italic,
            foreground: foreground.intValue,
            background: background.intValue
        )

        if let cached = cache[key] {
            return cached
        }

        let image = renderGlyph(text: text, cellSize: cellSize, font: font,
                                bold: bold, italic: italic,
                                foreground: foreground, background: background)
        if let image {
            cache[key] = image
        }
        return image
    }

    func invalidate() {
        cache.removeAll()
    }

    // MARK: - Private

    private func renderGlyph(text: String, cellSize: CGSize, font: NSFont,
                             bold: Bool, italic: Bool,
                             foreground: NSColor, background: NSColor) -> CGImage? {
        let width = Int(cellSize.width)
        let height = Int(cellSize.height)
        guard width > 0, height > 0 else { return nil }

        let resolvedFont = resolveFont(font, bold: bold, italic: italic)

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Fill background
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw text
        let attrString = NSAttributedString(string: text, attributes: [
            .font: resolvedFont,
            .foregroundColor: foreground,
        ])
        let line = CTLineCreateWithAttributedString(attrString)
        let descent = CTFontGetDescent(resolvedFont)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)

        return context.makeImage()
    }

    private func resolveFont(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }

        if traits.isEmpty { return font }

        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

}

extension NSColor {
    var intValue: Int {
        guard let rgb = usingColorSpace(.deviceRGB) else { return 0 }
        return (Int(rgb.redComponent * 255) << 16) |
               (Int(rgb.greenComponent * 255) << 8) |
               Int(rgb.blueComponent * 255)
    }

    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
```

- [ ] **Step 2: Implement RowRenderer**

```swift
// MacNeovim/Rendering/RowRenderer.swift

import AppKit

final class RowRenderer {
    let glyphCache: GlyphCache
    var font: NSFont
    var cellSize: CGSize

    init(glyphCache: GlyphCache, font: NSFont, cellSize: CGSize) {
        self.glyphCache = glyphCache
        self.font = font
        self.cellSize = cellSize
    }

    /// Render one grid row into a CGImage.
    func renderRow(_ cells: [Cell], attributes: [Int: CellAttributes],
                   defaultFg: Int, defaultBg: Int, cols: Int, scale: CGFloat) -> CGImage? {
        let width = cellSize.width * CGFloat(cols)
        let height = cellSize.height
        let pixelWidth = Int(width * scale)
        let pixelHeight = Int(height * scale)

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)

        for col in 0..<min(cells.count, cols) {
            let cell = cells[col]
            let attrs = attributes[cell.hlId] ?? CellAttributes()

            let fg = attrs.effectiveForeground(defaultFg: defaultFg, defaultBg: defaultBg)
            let bg = attrs.effectiveBackground(defaultFg: defaultFg, defaultBg: defaultBg)

            let x = CGFloat(col) * cellSize.width
            let cellRect = CGRect(x: x, y: 0, width: cellSize.width, height: cellSize.height)

            let fgColor = NSColor(rgb: fg)
            let bgColor = NSColor(rgb: bg)

            if cell.text == " " || cell.text.isEmpty {
                context.setFillColor(bgColor.cgColor)
                context.fill(cellRect)
            } else if let image = glyphCache.image(
                for: cell.text, cellSize: cellSize, font: font,
                bold: attrs.bold, italic: attrs.italic,
                foreground: fgColor, background: bgColor
            ) {
                context.draw(image, in: cellRect)
            }
        }

        return context.makeImage()
    }
}
```

- [ ] **Step 3: Write GlyphCache tests**

```swift
// MacNeovimTests/GlyphCacheTests.swift

import XCTest
@testable import MacNeovim

final class GlyphCacheTests: XCTestCase {

    func testCacheMissRendersImage() {
        let cache = GlyphCache()
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let cellSize = CGSize(width: 8, height: 16)
        let img = cache.image(for: "A", cellSize: cellSize, font: font,
                              bold: false, italic: false,
                              foreground: .white, background: .black)
        XCTAssertNotNil(img)
    }

    func testCacheHitReturnsSameImage() {
        let cache = GlyphCache()
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let cellSize = CGSize(width: 8, height: 16)
        let img1 = cache.image(for: "A", cellSize: cellSize, font: font,
                               bold: false, italic: false,
                               foreground: .white, background: .black)
        let img2 = cache.image(for: "A", cellSize: cellSize, font: font,
                               bold: false, italic: false,
                               foreground: .white, background: .black)
        // Same object from cache
        XCTAssertTrue(img1 === img2)
    }

    func testDifferentAttributesProduceDifferentImages() {
        let cache = GlyphCache()
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let cellSize = CGSize(width: 8, height: 16)
        let img1 = cache.image(for: "A", cellSize: cellSize, font: font,
                               bold: false, italic: false,
                               foreground: .white, background: .black)
        let img2 = cache.image(for: "A", cellSize: cellSize, font: font,
                               bold: true, italic: false,
                               foreground: .white, background: .black)
        XCTAssertFalse(img1 === img2)
    }

    func testInvalidateClearsCache() {
        let cache = GlyphCache()
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let cellSize = CGSize(width: 8, height: 16)
        let img1 = cache.image(for: "A", cellSize: cellSize, font: font,
                               bold: false, italic: false,
                               foreground: .white, background: .black)
        cache.invalidate()
        let img2 = cache.image(for: "A", cellSize: cellSize, font: font,
                               bold: false, italic: false,
                               foreground: .white, background: .black)
        // After invalidation, should be a new image
        XCTAssertFalse(img1 === img2)
    }
}
```

- [ ] **Step 4: Implement NvimView**

```swift
// MacNeovim/Rendering/NvimView.swift

import AppKit

@MainActor
final class NvimView: NSView {
    var channel: NvimChannel?

    private(set) var cellSize: CGSize = .zero
    private(set) var gridFont: NSFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private var rowLayers: [CALayer] = []
    private let glyphCache = GlyphCache()
    private lazy var rowRenderer = RowRenderer(glyphCache: glyphCache, font: gridFont, cellSize: cellSize)
    private let cursorLayer = CALayer()

    private var defaultFg: Int = 0xFFFFFF
    private var defaultBg: Int = 0x000000

    private var flatCharIndices: [[Int]] = []  // from Grid, for IME characterIndex
    private var modeInfoList: [ModeInfo] = []
    private var currentCursorShape: ModeInfo.CursorShape = .block
    private var currentCellPercentage: Int = 100

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        updateCellSize()

        cursorLayer.backgroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        cursorLayer.zPosition = 100
        layer?.addSublayer(cursorLayer)
    }

    // MARK: - Public API

    func updateFont(_ font: NSFont) {
        gridFont = font
        updateCellSize()
        glyphCache.invalidate()
        rowRenderer.font = font
        rowRenderer.cellSize = cellSize
        rebuildAllRows()
    }

    func render(grid: Grid) {
        defaultFg = grid.defaultForeground
        defaultBg = grid.defaultBackground
        layer?.backgroundColor = NSColor(rgb: defaultBg).cgColor
        flatCharIndices = grid.flatCharIndices

        ensureRowLayers(count: grid.size.rows)

        for row in grid.dirtyRows {
            guard row < grid.size.rows, row < rowLayers.count else { continue }
            renderRow(row, cells: grid.cells[row], attributes: grid.attributes, gridCols: grid.size.cols)
        }

        updateCursor(position: grid.cursorPosition)
    }

    func gridSizeForViewSize(_ size: NSSize) -> GridSize {
        guard cellSize.width > 0, cellSize.height > 0 else { return .zero }
        return GridSize(
            rows: max(1, Int(size.height / cellSize.height)),
            cols: max(1, Int(size.width / cellSize.width))
        )
    }

    func setDefaultColors(fg: Int, bg: Int) {
        defaultFg = fg
        defaultBg = bg
        layer?.backgroundColor = NSColor(rgb: bg).cgColor
    }

    func updateModeInfo(_ modes: [ModeInfo]) {
        modeInfoList = modes
    }

    func updateCursorMode(_ index: Int) {
        guard index < modeInfoList.count else { return }
        let mode = modeInfoList[index]
        currentCursorShape = mode.cursorShape
        currentCellPercentage = mode.cellPercentage
        updateCursorAppearance()
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }

    // MARK: - Private rendering

    private func updateCellSize() {
        let attrs: [NSAttributedString.Key: Any] = [.font: gridFont]
        let size = ("M" as NSString).size(withAttributes: attrs)
        let ascent = CTFontGetAscent(gridFont)
        let descent = CTFontGetDescent(gridFont)
        let leading = CTFontGetLeading(gridFont)
        cellSize = CGSize(width: ceil(size.width), height: ceil(ascent + descent + leading))
    }

    private func ensureRowLayers(count: Int) {
        while rowLayers.count < count {
            let layer = CALayer()
            layer.contentsGravity = .bottomLeft
            layer.contentsScale = window?.backingScaleFactor ?? 2.0
            self.layer?.addSublayer(layer)
            rowLayers.append(layer)
        }
        while rowLayers.count > count {
            rowLayers.removeLast().removeFromSuperlayer()
        }
        // Position layers
        for (i, layer) in rowLayers.enumerated() {
            let y = bounds.height - CGFloat(i + 1) * cellSize.height
            layer.frame = CGRect(x: 0, y: y, width: bounds.width, height: cellSize.height)
        }
    }

    private func renderRow(_ row: Int, cells: [Cell], attributes: [Int: CellAttributes], gridCols: Int) {
        let scale = window?.backingScaleFactor ?? 2.0
        if let image = rowRenderer.renderRow(
            cells, attributes: attributes,
            defaultFg: defaultFg, defaultBg: defaultBg,
            cols: gridCols, scale: scale
        ) {
            rowLayers[row].contents = image
        }
    }

    private func updateCursor(position: Position) {
        let x = CGFloat(position.col) * cellSize.width
        let y = bounds.height - CGFloat(position.row + 1) * cellSize.height
        let pct = CGFloat(max(10, currentCellPercentage)) / 100.0

        switch currentCursorShape {
        case .block:
            cursorLayer.frame = CGRect(x: x, y: y, width: cellSize.width, height: cellSize.height)
        case .vertical:
            cursorLayer.frame = CGRect(x: x, y: y, width: max(2, cellSize.width * pct), height: cellSize.height)
        case .horizontal:
            cursorLayer.frame = CGRect(x: x, y: y, width: cellSize.width, height: max(2, cellSize.height * pct))
        }
    }

    private func updateCursorAppearance() {
        // Re-render cursor at current position with new shape
        // The cursorLayer frame will be updated on next render()
        let pct = CGFloat(max(10, currentCellPercentage)) / 100.0
        let frame = cursorLayer.frame

        switch currentCursorShape {
        case .block:
            cursorLayer.frame = CGRect(x: frame.origin.x, y: frame.origin.y,
                                       width: cellSize.width, height: cellSize.height)
        case .vertical:
            cursorLayer.frame = CGRect(x: frame.origin.x, y: frame.origin.y,
                                       width: max(2, cellSize.width * pct), height: cellSize.height)
        case .horizontal:
            cursorLayer.frame = CGRect(x: frame.origin.x, y: frame.origin.y,
                                       width: cellSize.width, height: max(2, cellSize.height * pct))
        }
    }

    private func rebuildAllRows() {
        // Will be re-rendered on next grid render
        for layer in rowLayers {
            layer.contents = nil
        }
    }

    // MARK: - Coordinate conversion

    func gridPosition(for point: NSPoint) -> Position {
        let col = Int(point.x / cellSize.width)
        let row = Int((bounds.height - point.y) / cellSize.height)
        return Position(row: max(0, row), col: max(0, col))
    }
}
```

- [ ] **Step 5: Implement NvimView+Keyboard (basic, no IME yet)**

```swift
// MacNeovim/Rendering/NvimView+Keyboard.swift

import AppKit

extension NvimView {

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let hasMetaModifier = !modifiers.intersection([.control, .option, .command]).isEmpty

        if hasMetaModifier {
            // Meta-modified keys bypass input method and go directly to nvim
            sendKeyToNvim(event)
            return
        }

        // For non-meta keys, let the input method system handle it
        // This will call insertText() or doCommand(by:) via NSTextInputClient
        inputContext?.handleEvent(event)
    }

    private func sendKeyToNvim(_ event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty else { return }
        let modifiers = event.modifierFlags
        let nvimKey = KeyUtils.nvimKey(characters: characters, modifiers: modifiers)
        guard !nvimKey.isEmpty else { return }

        Task {
            await channel?.send(key: nvimKey)
        }
    }

    // insertText and doCommand are NSTextInputClient protocol methods
    // (see NSTextInputClient extension below). They are called by
    // inputContext?.handleEvent() during keyDown processing.
}

// MARK: - NSTextInputClient (stub — will be fully replaced in Task 11)
// All methods are in the main NvimView+Keyboard extension above.
// The protocol conformance is declared here as a stub.
// Task 11 will DELETE this entire file and rewrite it with full IME support.

extension NvimView: NSTextInputClient {
    func hasMarkedText() -> Bool { false }

    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String, !text.isEmpty else { return }
        Task {
            await channel?.send(key: text)
        }
    }

    func doCommand(by selector: Selector) {
        // No-op for now — standard commands handled by responder chain
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}

    func unmarkText() {}

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let cursorRect = cursorLayer.frame
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    func attributedString() -> NSAttributedString { NSAttributedString() }
}
```

- [ ] **Step 6: Verify build**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Run GlyphCache tests**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'GlyphCache|BUILD'`

Expected: All `GlyphCacheTests` pass.

- [ ] **Step 8: Commit**

```bash
git add MacNeovim/Rendering/ MacNeovimTests/GlyphCacheTests.swift
git commit -m "Add NvimView with layer-backed rendering and basic keyboard input"
```

---

### Task 9: WindowDocument + WindowController — App Shell

**Files:**
- Create: `MacNeovim/Window/WindowDocument.swift`
- Create: `MacNeovim/Window/WindowController.swift`
- Modify: `MacNeovim/AppDelegate.swift`
- Modify: `MacNeovim/Base.lproj/MainMenu.xib` (remove default window)

**Context:** This wires everything together. WindowDocument owns the nvim process, channel, grid, and event loop. WindowController creates and lays out the NvimView. After this task, you should be able to launch the app and see neovim rendering.

**Important:** The existing `MainMenu.xib` has a default NSWindow outlet connected to AppDelegate. We need to remove that window — NSDocument will create its own windows. Also need to register the document type in Info.plist.

- [ ] **Step 1: Implement WindowDocument**

```swift
// MacNeovim/Window/WindowDocument.swift

import AppKit
import MessagePack

@MainActor
class WindowDocument: NSDocument {
    var profile: Profile = .default

    private var channel: NvimChannel!
    private let grid = Grid()
    private var eventLoopTask: Task<Void, Never>?
    private var windowTitle: String = "MacNeovim"

    private var nvimView: NvimView? {
        (windowControllers.first as? WindowController)?.nvimView
    }

    override init() {
        super.init()
        self.channel = NvimChannel()
    }

    override func makeWindowControllers() {
        let controller = WindowController()
        controller.nvimView.channel = channel
        addWindowController(controller)

        // Start nvim after window is visible
        Task {
            await startNvim()
        }
    }

    override class var autosavesInPlace: Bool { false }
    override func data(ofType typeName: String) throws -> Data { Data() }
    override func read(from data: Data, ofType typeName: String) throws {}

    // MARK: - Nvim lifecycle

    private func startNvim() async {
        do {
            try await channel.start(
                nvimPath: "",
                cwd: NSHomeDirectory(),
                appName: profile.name
            )

            guard let nvimView else { return }
            let gridSize = nvimView.gridSizeForViewSize(nvimView.bounds.size)
            try await channel.uiAttach(width: gridSize.cols, height: gridSize.rows)

            startEventLoop()
        } catch {
            NSAlert(error: error).runModal()
            close()
        }
    }

    private func startEventLoop() {
        eventLoopTask = Task { @MainActor in
            let events = await channel.events
            for await event in events {
                grid.apply(event)

                switch event {
                case .flush:
                    nvimView?.render(grid: grid)
                    grid.clearDirty()
                case .setTitle(let title):
                    windowTitle = title
                    windowControllers.first?.window?.title = title
                case .defaultColorsSet(let fg, let bg, _):
                    nvimView?.setDefaultColors(fg: fg, bg: bg)
                case .modeInfoSet(_, let modes):
                    nvimView?.updateModeInfo(modes)
                case .modeChange(_, let index):
                    nvimView?.updateCursorMode(index)
                case .bell:
                    NSSound.beep()
                default:
                    break
                }
            }
            // Event stream ended — nvim process exited
            close()
        }
    }

    // MARK: - Window close

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        // For now, allow immediate close. Task 14 will add dirty buffer checking.
        Task {
            try? await channel.command("qa!")
        }
        // Allow close after a brief delay for nvim to exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    override func close() {
        eventLoopTask?.cancel()
        Task {
            await channel.stop()
        }
        super.close()
    }

    // MARK: - Resize

    func windowDidResize(to size: NSSize) {
        guard let nvimView else { return }
        let gridSize = nvimView.gridSizeForViewSize(size)
        guard gridSize.rows > 0, gridSize.cols > 0 else { return }
        Task {
            await channel.uiTryResize(width: gridSize.cols, height: gridSize.rows)
        }
    }
}
```

- [ ] **Step 2: Implement WindowController**

```swift
// MacNeovim/Window/WindowController.swift

import AppKit

@MainActor
class WindowController: NSWindowController, NSWindowDelegate {
    let nvimView = NvimView(frame: .zero)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacNeovim"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
        window.contentView = nvimView
        window.makeFirstResponder(nvimView)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard let contentSize = window?.contentView?.bounds.size else { return }
        (document as? WindowDocument)?.windowDidResize(to: contentSize)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(nvimView)
    }
}
```

- [ ] **Step 3: Update AppDelegate**

```swift
// MacNeovim/AppDelegate.swift

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create initial document/window
        NSDocumentController.shared.newDocument(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }
}
```

Remove the `@IBOutlet var window: NSWindow!` property — NSDocument manages windows now.

- [ ] **Step 4: Remove default window from MainMenu.xib**

The XIB has a default NSWindow connected to AppDelegate's `window` outlet. Since we removed that outlet, we need to disconnect it. The simplest approach: open MainMenu.xib in Xcode, delete the Window object (QvC-M9-y7g), and remove the outlet connection from AppDelegate.

Alternatively, you can edit the XIB XML to remove the window object and its connection. The key changes:
1. Remove the `<window>` element with id `QvC-M9-y7g`
2. Remove the outlet connection `gIp-Ho-8D9` from the AppDelegate custom object

- [ ] **Step 5: Register document type in Info.plist**

The Xcode project needs a document type registered so NSDocumentController works. Add to Info.plist (via Xcode target settings → Info → Document Types):

- Name: `MacNeovim Document`
- Class: `$(PRODUCT_MODULE_NAME).WindowDocument`
- Role: `Editor`
- Identifier: any (e.g., `com.rainux.macneovim.document`)
- No file extensions needed (we don't open files via Finder)

Also ensure `NSDocument` subclass is exposed: in `WindowDocument.swift`, the class must be `@objc(WindowDocument)` or properly referenced.

- [ ] **Step 6: Build and run — first visual milestone**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

Then run the app. You should see a window with neovim rendered inside it. You can type and see the output.

- [ ] **Step 7: Commit**

```bash
git add MacNeovim/Window/ MacNeovim/AppDelegate.swift MacNeovim/Base.lproj/MainMenu.xib MacNeovim.xcodeproj
git commit -m "Wire up NSDocument architecture — first visual milestone with neovim rendering"
```

---

### Task 10: Mouse Support

**Files:**
- Create: `MacNeovim/Rendering/NvimView+Mouse.swift`

**Context:** Mouse events: scroll wheel for scrolling, click to position cursor, drag for visual selection. Mouse events are sent to neovim via `nvim_input_mouse` API.

**Reference:** `vimr/NvimView/Sources/NvimView/NvimView+Mouse.swift` (239 lines) for event handling and trackpad smoothing.

- [ ] **Step 1: Implement NvimView+Mouse**

```swift
// MacNeovim/Rendering/NvimView+Mouse.swift

import AppKit

extension NvimView {

    override func mouseDown(with event: NSEvent) {
        sendMouseEvent(event, button: "left", action: "press")
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseEvent(event, button: "left", action: "release")
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouseEvent(event, button: "left", action: "drag")
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseEvent(event, button: "right", action: "press")
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseEvent(event, button: "right", action: "release")
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouseEvent(event, button: "right", action: "drag")
    }

    override func scrollWheel(with event: NSEvent) {
        let position = gridPosition(for: convert(event.locationInWindow, from: nil))

        // Determine scroll direction
        // Positive deltaY = scroll up (show earlier content)
        // Negative deltaY = scroll down (show later content)
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX

        if abs(deltaY) > abs(deltaX) {
            let button = deltaY > 0 ? "wheel_up" : "wheel_down"
            let count = max(1, Int(abs(deltaY) / cellSize.height))
            let modifier = modifierString(event.modifierFlags)
            for _ in 0..<count {
                Task {
                    await channel?.inputMouse(
                        button: button, action: "press", modifier: modifier,
                        grid: 0, row: position.row, col: position.col
                    )
                }
            }
        } else if abs(deltaX) > 0 {
            let button = deltaX > 0 ? "wheel_left" : "wheel_right"
            let modifier = modifierString(event.modifierFlags)
            Task {
                await channel?.inputMouse(
                    button: button, action: "press", modifier: modifier,
                    grid: 0, row: position.row, col: position.col
                )
            }
        }
    }

    // MARK: - Private

    private func sendMouseEvent(_ event: NSEvent, button: String, action: String) {
        let point = convert(event.locationInWindow, from: nil)
        let position = gridPosition(for: point)
        let modifier = modifierString(event.modifierFlags)

        Task {
            await channel?.inputMouse(
                button: button, action: action, modifier: modifier,
                grid: 0, row: position.row, col: position.col
            )
        }
    }

    private func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.shift) { parts.append("S") }
        if flags.contains(.control) { parts.append("C") }
        if flags.contains(.option) { parts.append("A") }
        if flags.contains(.command) { parts.append("D") }
        return parts.joined(separator: "-")
    }
}
```

- [ ] **Step 2: Verify build and test mouse**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

Manual test: Run the app, click in the neovim window — cursor should move. Scroll wheel should scroll.

- [ ] **Step 3: Commit**

```bash
git add MacNeovim/Rendering/NvimView+Mouse.swift
git commit -m "Add mouse support: click, drag, and scroll wheel"
```

---

### Task 11: IME / NSTextInputClient — Full Implementation

**Files:**
- **Replace entirely:** `MacNeovim/Rendering/NvimView+Keyboard.swift` (delete and rewrite — replaces the stub NSTextInputClient from Task 8)
- Modify: `MacNeovim/Rendering/NvimView.swift` (add marked text state)

**Context:** Full IME support for CJK input methods. When composing (marked text), the composing text is rendered as an overlay at the cursor position. When the user confirms input, the final text is sent to neovim. The tricky part is detecting whether keyDown was consumed by the input method or should be sent directly to neovim.

**Reference:** `vimr/NvimView/Sources/NvimView/NvimView+Key.swift` lines 30-100 for the `keyDownDone` flag pattern and IME lifecycle.

- [ ] **Step 1: Add marked text state to NvimView**

Add these properties to `NvimView`:

```swift
// Add to NvimView class:

private var markedText: String?
private var markedPosition: Position = .zero
private let markedTextLayer = CATextLayer()
private var keyDownDone = true  // flag to detect if IME consumed the key
```

Initialize `markedTextLayer` in `commonInit()`:

```swift
markedTextLayer.contentsScale = 2.0
markedTextLayer.fontSize = 14
markedTextLayer.foregroundColor = NSColor.white.cgColor
markedTextLayer.backgroundColor = NSColor.darkGray.cgColor
markedTextLayer.isHidden = true
markedTextLayer.zPosition = 200
layer?.addSublayer(markedTextLayer)
```

- [ ] **Step 2: Rewrite NvimView+Keyboard with full IME support**

Replace the keyboard extension:

```swift
// MacNeovim/Rendering/NvimView+Keyboard.swift

import AppKit

extension NvimView {

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])

        if !modifiers.isEmpty {
            // Meta-modified keys bypass IME
            sendKeyDirectly(event)
            return
        }

        // Use keyDownDone flag to detect if input method consumed the event
        keyDownDone = false
        inputContext?.handleEvent(event)

        if !keyDownDone && markedText == nil {
            // Input method didn't consume it and there's no composition — send directly
            sendKeyDirectly(event)
        }
    }

    private func sendKeyDirectly(_ event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty else { return }
        let nvimKey = KeyUtils.nvimKey(characters: characters, modifiers: event.modifierFlags)
        guard !nvimKey.isEmpty else { return }
        Task {
            await channel?.send(key: nvimKey)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        keyDownDone = true

        // If we had marked text, clear it
        if markedText != nil {
            clearMarkedText()
        }

        guard let text = string as? String, !text.isEmpty else { return }
        Task {
            await channel?.send(key: text)
        }
    }

    override func doCommand(by selector: Selector) {
        keyDownDone = true
        // Standard commands — handled by the responder chain
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let menu items handle their key equivalents
        false
    }

    // MARK: - Marked text rendering

    internal func updateMarkedTextDisplay() {
        guard let text = markedText, !text.isEmpty else {
            markedTextLayer.isHidden = true
            return
        }

        markedTextLayer.string = text
        markedTextLayer.font = gridFont
        markedTextLayer.fontSize = gridFont.pointSize
        markedTextLayer.contentsScale = window?.backingScaleFactor ?? 2.0

        // Position at cursor
        let x = CGFloat(markedPosition.col) * cellSize.width
        let y = bounds.height - CGFloat(markedPosition.row + 1) * cellSize.height
        let width = cellSize.width * CGFloat(text.count)
        markedTextLayer.frame = CGRect(x: x, y: y, width: max(width, cellSize.width), height: cellSize.height)
        markedTextLayer.isHidden = false
    }

    internal func clearMarkedText() {
        markedText = nil
        markedTextLayer.isHidden = true
    }
}

// MARK: - NSTextInputClient

extension NvimView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText != nil
    }

    func markedRange() -> NSRange {
        guard let text = markedText else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: text.utf16.count)
    }

    func selectedRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        keyDownDone = true
        let text: String
        if let attrString = string as? NSAttributedString {
            text = attrString.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        if text.isEmpty {
            clearMarkedText()
        } else {
            markedText = text
            // Capture current cursor position for marked text display
            // (cursorLayer position is already set from grid updates)
            let col = Int(cursorLayer.frame.origin.x / cellSize.width)
            let row = Int((bounds.height - cursorLayer.frame.maxY) / cellSize.height)
            markedPosition = Position(row: row, col: col)
            updateMarkedTextDisplay()
        }
    }

    func unmarkText() {
        clearMarkedText()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .underlineStyle]
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        let pos = gridPosition(for: convert(point, from: nil))
        guard pos.row < flatCharIndices.count,
              pos.col < flatCharIndices[pos.row].count else { return 0 }
        return flatCharIndices[pos.row][pos.col]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let cursorRect = cursorLayer.frame
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    func attributedString() -> NSAttributedString {
        NSAttributedString()
    }
}
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

Manual test: Switch to a Chinese input method, type pinyin — you should see the composition candidates appear.

- [ ] **Step 4: Commit**

```bash
git add MacNeovim/Rendering/NvimView+Keyboard.swift MacNeovim/Rendering/NvimView.swift
git commit -m "Add full IME support with marked text composition"
```

---

### Task 12: TablineView + Cmd+1/2/3

**Files:**
- Create: `MacNeovim/Window/TablineView.swift`
- Modify: `MacNeovim/Window/WindowController.swift` (add tab bar layout)
- Modify: `MacNeovim/Window/WindowDocument.swift` (forward tablineUpdate events)

**Context:** Custom tab bar that maps 1:1 to neovim tabpages. Cmd+1/2/3 switch tabs via `:tabnext N` commands. Tab bar is driven by `tablineUpdate` events from the channel.

- [ ] **Step 1: Implement TablineView**

```swift
// MacNeovim/Window/TablineView.swift

import AppKit

@MainActor
final class TablineView: NSView {
    struct Tab {
        let handle: Any  // opaque nvim tabpage handle
        let name: String
        let isSelected: Bool
    }

    var tabs: [Tab] = [] {
        didSet { needsDisplay = true }
    }

    var onSelectTab: ((Int) -> Void)?

    private let tabHeight: CGFloat = 28

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: tabs.isEmpty ? 0 : tabHeight)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !tabs.isEmpty, tabs.count > 1 else {
            // Hide tab bar when only 1 tab
            return
        }

        let bg = NSColor(rgb: 0x1e1e1e)
        bg.setFill()
        bounds.fill()

        let tabWidth = min(200, bounds.width / CGFloat(tabs.count))
        for (i, tab) in tabs.enumerated() {
            let rect = NSRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: tabHeight)

            if tab.isSelected {
                NSColor(rgb: 0x2d2d2d).setFill()
                rect.fill()

                // Bottom accent line
                let accent = NSRect(x: rect.origin.x, y: tabHeight - 2, width: tabWidth, height: 2)
                NSColor(rgb: 0x007ACC).setFill()
                accent.fill()
            }

            // Tab title
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: tab.isSelected ? NSColor.white : NSColor.gray,
            ]
            let title = NSAttributedString(string: tab.name, attributes: attrs)
            let titleSize = title.size()
            let titleOrigin = NSPoint(
                x: rect.origin.x + (tabWidth - titleSize.width) / 2,
                y: (tabHeight - titleSize.height) / 2
            )
            title.draw(at: titleOrigin)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard tabs.count > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let tabWidth = min(200, bounds.width / CGFloat(tabs.count))
        let index = Int(point.x / tabWidth)
        if index >= 0, index < tabs.count {
            onSelectTab?(index)
        }
    }

    // MARK: - Update from nvim events

    func update(current: Any, tabInfos: [TabpageInfo]) {
        tabs = tabInfos.enumerated().map { i, info in
            // Determine which tab is selected by comparing handles
            // For now, use index-based comparison (first tab after current)
            Tab(handle: info.handle,
                name: info.name.isEmpty ? "[\(i + 1)]" : info.name,
                isSelected: false)
        }
        // Mark the current tab as selected
        // The `current` value is the tabpage handle of the active tab
        if let currentPack = current as? MessagePackValue {
            for (i, info) in tabInfos.enumerated() {
                if info.handle == currentPack {
                    tabs[i] = Tab(handle: info.handle, name: tabs[i].name, isSelected: true)
                }
            }
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

import MessagePack
```

- [ ] **Step 2: Update WindowController to include TablineView**

Modify `WindowController` to lay out TablineView above NvimView:

```swift
// In WindowController.init(), replace window.contentView = nvimView with:

let tablineView = TablineView(frame: .zero)
tablineView.translatesAutoresizingMaskIntoConstraints = false
nvimView.translatesAutoresizingMaskIntoConstraints = false

let contentView = NSView(frame: window.contentView!.bounds)
contentView.addSubview(tablineView)
contentView.addSubview(nvimView)

NSLayoutConstraint.activate([
    tablineView.topAnchor.constraint(equalTo: contentView.topAnchor),
    tablineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
    tablineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    tablineView.heightAnchor.constraint(equalToConstant: 28),

    nvimView.topAnchor.constraint(equalTo: tablineView.bottomAnchor),
    nvimView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
    nvimView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    nvimView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
])

window.contentView = contentView
```

Add a `tablineView` property:

```swift
let tablineView = TablineView(frame: .zero)
```

Store it and expose it so WindowDocument can update it.

- [ ] **Step 3: Add Cmd+1/2/3 menu items**

Add to `WindowController` or `AppDelegate` — create menu items with Cmd+1 through Cmd+9 key equivalents that send `:tabnext N` via the channel:

```swift
// In WindowController, add method:
func setupTabKeyEquivalents() {
    for i in 1...9 {
        let item = NSMenuItem(title: "Tab \(i)", action: #selector(switchToTab(_:)), keyEquivalent: "\(i)")
        item.keyEquivalentModifierMask = .command
        item.tag = i
        // Add to Window menu or a new Tab menu
    }
}

@objc func switchToTab(_ sender: NSMenuItem) {
    let tabNumber = sender.tag
    guard let doc = document as? WindowDocument else { return }
    Task {
        try? await doc.channel.command("tabnext \(tabNumber)")
    }
}
```

Note: The channel property on WindowDocument needs to be accessible. Make it `internal` or add a method on WindowDocument.

- [ ] **Step 4: Forward tablineUpdate events in WindowDocument**

In `WindowDocument.startEventLoop()`, add handling for `.tablineUpdate`:

```swift
case .tablineUpdate(let current, let tabs):
    if let controller = windowControllers.first as? WindowController {
        controller.tablineView.update(current: current, tabInfos: tabs)
    }
```

Also wire up `tablineView.onSelectTab`:

```swift
// In WindowDocument.makeWindowControllers(), after creating controller:
controller.tablineView.onSelectTab = { [weak self] index in
    Task {
        try? await self?.channel.command("tabnext \(index + 1)")
    }
}
```

- [ ] **Step 5: Verify build and test tabs**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Manual test: Launch app, run `:tabnew` in neovim. Tab bar should appear with 2 tabs. Click to switch. Cmd+1/Cmd+2 should switch.

- [ ] **Step 6: Commit**

```bash
git add MacNeovim/Window/TablineView.swift MacNeovim/Window/WindowController.swift MacNeovim/Window/WindowDocument.swift
git commit -m "Add tab bar mapping neovim tabpages with Cmd+1-9 switching"
```

---

### Task 13: Multi-Window + Profile

**Files:**
- Create: `MacNeovim/Util/Profile.swift`
- Create: `MacNeovim/Window/ProfilePicker.swift`
- Modify: `MacNeovim/Window/WindowDocument.swift` (profile support)
- Modify: `MacNeovim/AppDelegate.swift` (Cmd+N handling)
- Create: `MacNeovimTests/ProfileTests.swift`

**Context:** Each new window can use a different NVIM_APPNAME. Profile scans `~/.config/` for directories containing nvim configs. Cmd+N shows a popover to pick profile; Cmd+Shift+N creates with last-used profile.

- [ ] **Step 1: Write failing tests for Profile**

```swift
// MacNeovimTests/ProfileTests.swift

import XCTest
@testable import MacNeovim

final class ProfileTests: XCTestCase {

    func testDefaultProfile() {
        let p = Profile.default
        XCTAssertEqual(p.name, "nvim")
        XCTAssertEqual(p.displayName, "Default")
    }

    func testProfileEquality() {
        let a = Profile(name: "nvim", displayName: "Default")
        let b = Profile(name: "nvim", displayName: "Something Else")
        XCTAssertEqual(a, b)  // equality based on name, not displayName
    }

    func testProfileFromDirectoryName() {
        let p = Profile(name: "lazyvim", displayName: "lazyvim")
        XCTAssertEqual(p.name, "lazyvim")
    }
}
```

- [ ] **Step 2: Implement Profile**

```swift
// MacNeovim/Util/Profile.swift

import Foundation

struct Profile: Codable, Hashable, Sendable {
    let name: String
    var displayName: String

    static let `default` = Profile(name: "nvim", displayName: "Default")

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    static func == (lhs: Profile, rhs: Profile) -> Bool {
        lhs.name == rhs.name
    }

    /// Scan ~/.config/ for directories containing nvim configuration.
    static func availableProfiles() -> [Profile] {
        let configDir: URL
        if let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            configDir = URL(fileURLWithPath: xdgConfig)
        } else {
            configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
        }

        var profiles: [Profile] = [.default]
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: configDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return profiles
        }

        for url in contents {
            guard let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir else { continue }

            let name = url.lastPathComponent
            if name == "nvim" { continue }  // already in list as default

            // Check if it looks like a neovim config
            let hasInitLua = fm.fileExists(atPath: url.appendingPathComponent("init.lua").path)
            let hasInitVim = fm.fileExists(atPath: url.appendingPathComponent("init.vim").path)
            let hasLuaDir = fm.fileExists(atPath: url.appendingPathComponent("lua").path)

            if hasInitLua || hasInitVim || hasLuaDir {
                profiles.append(Profile(name: name, displayName: name))
            }
        }

        return profiles.sorted { $0.name < $1.name }
    }

    /// Last used profile, stored in UserDefaults.
    static var lastUsed: Profile {
        get {
            guard let data = UserDefaults.standard.data(forKey: "lastUsedProfile"),
                  let profile = try? JSONDecoder().decode(Profile.self, from: data) else {
                return .default
            }
            return profile
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "lastUsedProfile")
            }
        }
    }
}
```

- [ ] **Step 3: Implement ProfilePicker — simple NSMenu popup**

```swift
// MacNeovim/Window/ProfilePicker.swift

import AppKit

@MainActor
final class ProfilePicker {
    /// Show a menu of available profiles. Calls completion with the selected profile.
    /// If only one profile exists, calls completion immediately without showing UI.
    static func pick(relativeTo view: NSView, completion: @escaping (Profile) -> Void) {
        let profiles = Profile.availableProfiles()

        if profiles.count <= 1 {
            completion(.default)
            return
        }

        let menu = NSMenu(title: "Select Profile")
        for profile in profiles {
            let item = NSMenuItem(title: profile.displayName, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.representedObject = profile
            item.target = ProfilePickerTarget.shared
            menu.addItem(item)
        }

        ProfilePickerTarget.shared.completion = { profile in
            Profile.lastUsed = profile
            completion(profile)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }
}

private class ProfilePickerTarget: NSObject {
    static let shared = ProfilePickerTarget()
    var completion: ((Profile) -> Void)?

    @objc func menuItemSelected(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else { return }
        completion?(profile)
    }
}
```

- [ ] **Step 4: Wire up Cmd+N and Cmd+Shift+N in AppDelegate**

Update `AppDelegate`. **Cmd+N creates window directly** with last-used profile (no picker). **Cmd+Shift+N shows profile picker** for choosing a different config.

```swift
// Add to AppDelegate:

@IBAction func newDocument(_ sender: Any?) {
    // Cmd+N — create window immediately with last-used profile
    createWindow(profile: Profile.lastUsed)
}

@IBAction func newDocumentWithProfilePicker(_ sender: Any?) {
    // Cmd+Shift+N — show profile picker
    guard let window = NSApp.mainWindow ?? NSApp.windows.first,
          let contentView = window.contentView else {
        createWindow(profile: Profile.lastUsed)
        return
    }
    ProfilePicker.pick(relativeTo: contentView) { [self] profile in
        createWindow(profile: profile)
    }
}

private func createWindow(profile: Profile) {
    let doc = WindowDocument()
    doc.profile = profile
    Profile.lastUsed = profile
    NSDocumentController.shared.addDocument(doc)
    doc.makeWindowControllers()
    doc.showWindows()
}
```

In MainMenu.xib, connect:
- Cmd+N → `newDocument:`
- Cmd+Shift+N → `newDocumentWithProfilePicker:`

- [ ] **Step 5: Update WindowDocument to pass profile to NvimProcess**

In `WindowDocument.startNvim()`, the `appName` parameter should use `profile.name`:

```swift
try await channel.start(
    nvimPath: "",
    cwd: NSHomeDirectory(),
    appName: profile.name  // Already done in Task 9, verify it's there
)
```

- [ ] **Step 6: Run tests and verify build**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|BUILD'`

Manual test: Cmd+N should show profile picker (if multiple profiles exist). Cmd+Shift+N should create window immediately.

- [ ] **Step 7: Commit**

```bash
git add MacNeovim/Util/Profile.swift MacNeovim/Window/ProfilePicker.swift MacNeovim/AppDelegate.swift MacNeovimTests/ProfileTests.swift
git commit -m "Add multi-window support with NVIM_APPNAME profile selection"
```

---

### Task 14: Window Close Lifecycle

**Files:**
- Modify: `MacNeovim/Window/WindowDocument.swift`
- Modify: `MacNeovim/Nvim/NvimChannel.swift` (add API for checking modified buffers)

**Context:** Four close paths must converge to clean shutdown: (1) nvim exits on its own (`:qa!`), (2) user clicks close button — check for dirty buffers, (3) nvim crashes, (4) Cmd+Q app quit. Need to handle dirty buffer warnings properly.

**Reference:** Spec section "Window close lifecycle" for the four paths.

- [ ] **Step 1: Implement canClose — no GUI dialogs, let neovim handle confirmations**

Replace the placeholder `canClose` in WindowDocument. The GUI never shows save/discard alerts — instead, send `:confirm qa` to nvim, which will show its own "save changes?" prompt inside the terminal if there are unsaved buffers.

```swift
override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
    Task { @MainActor in
        // Send :confirm qa — nvim will prompt inside the terminal if there are unsaved buffers.
        // If user confirms in nvim, the process exits and our event loop ends → close().
        // If user cancels in nvim, nothing happens — window stays open.
        try? await channel.command("confirm qa")

        // Don't allow NSDocument to close the window here.
        // The window will close when nvim actually exits (event stream ends → close()).
        if let selector = shouldCloseSelector {
            let obj = delegate as AnyObject
            _ = obj.perform(selector, with: self, with: NSNumber(value: false), with: contextInfo)
        }
    }
}
```

- [ ] **Step 3: Handle applicationShouldTerminate for Cmd+Q**

Add to AppDelegate:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let documents = NSDocumentController.shared.documents
    if documents.isEmpty { return .terminateNow }

    // Check if any document has unsaved changes
    // NSDocument's built-in handling will ask each document via canClose
    return .terminateNow  // NSDocumentController handles the rest
}
```

- [ ] **Step 4: Verify build**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Expected: `BUILD SUCCEEDED`

Manual test: Open a file, make changes without saving, try to close — should get save/discard alert.

- [ ] **Step 5: Commit**

```bash
git add MacNeovim/Window/WindowDocument.swift MacNeovim/Nvim/NvimChannel.swift MacNeovim/AppDelegate.swift
git commit -m "Add proper window close lifecycle with dirty buffer checking"
```

---

### Task 15: Font and Theme Colors

**Files:**
- Modify: `MacNeovim/Window/WindowDocument.swift` (handle optionSet for guifont)
- Modify: `MacNeovim/Rendering/NvimView.swift` (font parsing + resize)

**Context:** Font is configured via neovim's `guifont` option (`:set guifont=JetBrains\ Mono:h14`). Detected via `optionSet` event. Font change triggers: recalculate cell size → `nvim_ui_try_resize` → full grid redraw → glyph cache invalidated. Theme colors come from `default_colors_set` and `hl_attr_define` events (already handled in Grid).

- [ ] **Step 1: Add guifont parsing to NvimView**

```swift
// Add to NvimView:

/// Parse neovim guifont string format: "Font Name:h14:b"
func parseAndSetGuifont(_ guifont: String) {
    let parts = guifont.split(separator: ":")
    guard let fontName = parts.first.map(String.init) else { return }

    var size: CGFloat = 14
    for part in parts.dropFirst() {
        if part.hasPrefix("h"), let s = Double(part.dropFirst()) {
            size = CGFloat(s)
        }
    }

    // Try to find the font
    let cleanName = fontName.replacingOccurrences(of: "\\ ", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    if let font = NSFont(name: cleanName, size: size) {
        updateFont(font)
    } else {
        // Fallback: use monospaced system font at requested size
        updateFont(NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
    }
}
```

- [ ] **Step 2: Handle optionSet in WindowDocument event loop**

Add to the event loop switch in `WindowDocument.startEventLoop()`:

```swift
case .optionSet(let name, let value):
    if name == "guifont", let fontStr = value.stringValue, !fontStr.isEmpty {
        nvimView?.parseAndSetGuifont(fontStr)
        // Resize grid after font change
        if let contentSize = windowControllers.first?.window?.contentView?.bounds.size,
           let nvimView {
            let newGridSize = nvimView.gridSizeForViewSize(contentSize)
            Task {
                await channel.uiTryResize(width: newGridSize.cols, height: newGridSize.rows)
            }
        }
    }
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -5`

Manual test: Launch app, run `:set guifont=Menlo:h18` — font should change and grid should resize.

- [ ] **Step 4: Commit**

```bash
git add MacNeovim/Rendering/NvimView.swift MacNeovim/Window/WindowDocument.swift
git commit -m "Add guifont parsing and theme color support"
```

---

### Task 16: Polish and Verification

**Files:**
- Various minor fixes across all files

**Context:** Final pass to ensure everything works together. Fix any compilation issues, test all features, verify responsiveness targets.

- [ ] **Step 1: Full build verification**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -10`

Fix any compilation errors.

- [ ] **Step 2: Run all tests**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | grep -E 'Test|BUILD'`

All tests should pass.

- [ ] **Step 3: Manual verification checklist**

Test each feature:
- [ ] App launches and shows neovim in a window
- [ ] Can type and edit text
- [ ] Arrow keys and function keys work
- [ ] Ctrl/Alt/Cmd modifier keys work
- [ ] Mouse click positions cursor
- [ ] Scroll wheel scrolls
- [ ] `:tabnew` shows tab bar, Cmd+1/2 switches tabs
- [ ] Cmd+N opens new window (with profile picker if multiple profiles)
- [ ] Close window with unsaved changes shows save dialog
- [ ] `:qa!` closes the window
- [ ] IME composition works (switch to Chinese input, type pinyin)
- [ ] `:set guifont=Menlo:h18` changes font
- [ ] Window resize adjusts grid dimensions
- [ ] Multiple windows operate independently

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "Polish and fix issues found during verification"
```

---

## Dependency Graph

```
Task 1 (Setup)
  ├── Task 2 (MsgpackRpc)
  │     └── Task 3 (NvimEvent)
  │           ├── Task 4 (Grid) ──────────────────┐
  │           └── Task 5 (KeyUtils)                │
  │                                                │
  ├── Task 6 (NvimProcess)                         │
  │     └── Task 7 (NvimChannel) ─── uses 2,3 ────┤
  │                                                │
  └── Task 8 (NvimView) ──── uses 4,5,7 ──────────┘
        ├── Task 9 (WindowDocument+Controller) ── uses all above
        │     ├── Task 10 (Mouse)
        │     ├── Task 11 (IME)
        │     ├── Task 12 (TablineView)
        │     ├── Task 13 (Multi-window + Profile)
        │     ├── Task 14 (Window close lifecycle)
        │     └── Task 15 (Font + theme)
        └── Task 16 (Polish)
```

Tasks 10-15 are independent of each other and can be worked on in parallel after Task 9.

---

### Task 17: Fix Slow Startup

**Files:**
- Modify: `MacNeovim/Nvim/NvimProcess.swift`

**Problem:** `start()` calls `loginShellEnvironment()` which synchronously launches a login shell with `-l -i`, loads `.zshrc` with all plugins, and calls `waitUntilExit()`. This blocks for seconds on every window creation.

**Fix:** Remove `loginShellEnvironment()` entirely. Use `ProcessInfo.processInfo.environment` directly. The `resolveNvimBinary()` method already has Homebrew fallback paths (`/opt/homebrew/bin/nvim`, `/usr/local/bin/nvim`), so we don't need the login shell's PATH.

- [ ] **Step 1: Read NvimProcess.swift**

- [ ] **Step 2: In `start()`, replace `Self.loginShellEnvironment()` with `ProcessInfo.processInfo.environment`**

- [ ] **Step 3: Delete the entire `loginShellEnvironment()` static method**

Keep `findInPath()` — it's used by `resolveNvimBinary()`.

- [ ] **Step 4: Build and verify**

Run: `xcodebuild build -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add MacNeovim/Nvim/NvimProcess.swift
git commit -m "Remove login shell env capture — use ProcessInfo.environment directly"
```

---

### Task 18: Fix Enter/Esc Keys Not Working

**Files:**
- Modify: `MacNeovim/Rendering/NvimView+Keyboard.swift`

**Problem:** Keys without meta modifiers go through `inputContext?.handleEvent(event)`. For Enter, macOS calls `doCommand(by: insertNewline:)`. For Esc, macOS calls `doCommand(by: cancelOperation:)`. But `doCommand(by:)` only sets `keyDownDone = true` and never sends the key to neovim.

**Fix:** In `keyDown`, before going through the IME path, check if the key is a special key (Esc `0x1B`, Enter `0x0D`, Tab `0x09`, Backspace `0x7F`, Backtab `0x19`, arrow/function keys `0xF700-0xF8FF`) and send it directly to nvim, bypassing IME.

- [ ] **Step 1: Read NvimView+Keyboard.swift**

- [ ] **Step 2: Replace the `keyDown` method**

```swift
override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.control, .option, .command])
    if !modifiers.isEmpty {
        sendKeyDirectly(event)
        return
    }

    // Special keys bypass IME — they would otherwise be consumed by doCommand(by:)
    if let chars = event.characters, let scalar = chars.unicodeScalars.first {
        let code = Int(scalar.value)
        if code == 0x1B || code == 0x0D || code == 0x09 || code == 0x7F
            || code == 0x19 || (code >= 0xF700 && code <= 0xF8FF) {
            sendKeyDirectly(event)
            return
        }
    }

    // Normal text goes through IME
    keyDownDone = false
    inputContext?.handleEvent(event)
    if !keyDownDone && markedText == nil {
        sendKeyDirectly(event)
        keyDownDone = true
    }
}
```

- [ ] **Step 3: Build and verify**

- [ ] **Step 4: Run unit tests (MacNeovimTests only)**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' -only-testing:MacNeovimTests 2>&1 | grep -E 'passed|failed|Executed'`

- [ ] **Step 5: Commit**

```bash
git add MacNeovim/Rendering/NvimView+Keyboard.swift
git commit -m "Route special keys (Esc, Enter, Tab, etc.) directly to nvim bypassing IME"
```

---

### Task 19: Fix Blurry Text and CJK Double-Width Rendering

**Files:**
- Modify: `MacNeovim/Rendering/GlyphCache.swift`
- Modify: `MacNeovim/Rendering/RowRenderer.swift`
- Modify: `MacNeovim/Rendering/NvimView.swift`

**Problem 1 — Blurry text:** GlyphCache creates a CGContext at 1x point size (e.g., 8×16 pixels for an 8×16pt cell). On Retina (2x), this image gets stretched to 16×32 display pixels, causing blur.

**Problem 2 — CJK half-rendered:** CJK characters are double-width (occupy 2 grid cells). Neovim sends the character in the first cell and an empty string `""` in the second. But GlyphCache renders into a single cell width, clipping the right half of the character.

**Fix for GlyphCache:**
1. Add `var scale: CGFloat = 2.0` public property
2. Add `cellCount: Int` parameter to `get()` and to the `Key` struct
3. In `render()`, create context at pixel dimensions: `width * cellCount * scale`, `height * scale`
4. Call `ctx.scaleBy(x: scale, y: scale)` so CoreText renders at full Retina resolution
5. Draw into a rect of `cellSize.width * cellCount` points wide

**Fix for RowRenderer:**
1. Add `scale: CGFloat = 2.0` parameter to `render()`
2. Create context at pixel dimensions, call `ctx.scaleBy(x: scale, y: scale)`
3. Detect double-width chars: current cell has text AND next cell text is `""` (empty)
4. For double-width chars, call `glyphCache.get(..., cellCount: 2)` and draw into 2 cells width
5. Use `while` loop instead of `for` to skip the placeholder cell after a double-width char

**Fix for NvimView:**
1. In `render(grid:)`, get `window?.backingScaleFactor ?? 2.0`
2. Set `glyphCache.scale = screenScale`
3. Pass `scale: screenScale` to `rowRenderer.render()`

- [ ] **Step 1: Read GlyphCache.swift, RowRenderer.swift, NvimView.swift**

- [ ] **Step 2: Update GlyphCache — add scale, cellCount, render at pixel resolution**

- [ ] **Step 3: Update RowRenderer — scale parameter, double-width detection, while loop**

- [ ] **Step 4: Update NvimView — pass scale to renderer and cache**

- [ ] **Step 5: Build and verify**

- [ ] **Step 6: Run GlyphCache tests**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' -only-testing:MacNeovimTests 2>&1 | grep -E 'GlyphCache|passed|failed'`

- [ ] **Step 7: Commit**

```bash
git add MacNeovim/Rendering/GlyphCache.swift MacNeovim/Rendering/RowRenderer.swift MacNeovim/Rendering/NvimView.swift
git commit -m "Fix Retina rendering at 2x scale and handle double-width CJK characters"
```

---

### Task 20: Fix Extremely Slow I/O — Byte-by-Byte Pipe Reading

**Files:**
- Modify: `MacNeovim/Nvim/MsgpackRpc.swift`

**Problem:** `MsgpackRpc.start()` reads from the nvim stdout pipe one byte at a time via `for try await byte in stream`. The `asyncBytes` extension yields each byte individually through an `AsyncThrowingStream`, causing one async/await context switch per byte. A single nvim redraw response can be tens of KB, meaning tens of thousands of context switches. This causes both slow startup and sluggish input response.

**Fix:** Replace the byte-by-byte `AsyncThrowingStream<UInt8>` with a chunk-based `AsyncStream<Data>`. The `readabilityHandler` already receives all available data at once — yield the entire `Data` chunk instead of iterating its bytes.

- [ ] **Step 1: Read MsgpackRpc.swift**

- [ ] **Step 2: Replace the `FileHandle.asyncBytes` extension with a chunk-based `asyncDataChunks`**

```swift
extension FileHandle {
    nonisolated var asyncDataChunks: AsyncStream<Data> {
        AsyncStream { continuation in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
    }
}
```

- [ ] **Step 3: Rewrite `start()` to consume data chunks**

```swift
func start() async {
    var accumulated = Data()
    for await chunk in outPipe.asyncDataChunks {
        accumulated.append(chunk)
        // Try to decode complete messages from accumulated data
        let messages: [RpcMessage]
        do {
            messages = try Self.decodeAccumulated(data: &accumulated)
        } catch {
            continue
        }
        for message in messages {
            switch message {
            case .response(let msgid, let error, let result):
                if let continuation = pendingRequests.removeValue(forKey: msgid) {
                    continuation.resume(returning: (error, result))
                }
            case .notification, .request:
                eventContinuation?.yield(message)
            }
        }
    }
    eventContinuation?.finish()
    for (_, continuation) in pendingRequests {
        continuation.resume(returning: (error: .string("channel closed"), result: .nil))
    }
    pendingRequests.removeAll()
}
```

- [ ] **Step 4: Remove the old `asyncBytes` extension** (the `AsyncThrowingStream<UInt8>` one)

- [ ] **Step 5: Build and run tests**

Run: `xcodebuild test -project MacNeovim.xcodeproj -scheme MacNeovim -destination 'platform=macOS' -only-testing:MacNeovimTests 2>&1 | grep -E 'passed|failed|Executed'`

- [ ] **Step 6: Commit**

```bash
git add MacNeovim/Nvim/MsgpackRpc.swift
git commit -m "Replace byte-by-byte pipe reading with chunk-based data streaming"
```
