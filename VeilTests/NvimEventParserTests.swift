import XCTest
import MessagePack
@testable import Veil

final class NvimEventParserTests: XCTestCase {

    // Helper: build a redraw args array for a single named event
    private func redrawArgs(_ name: String, _ eventArgs: [MessagePackValue]) -> [MessagePackValue] {
        var items: [MessagePackValue] = [.string(name)]
        items.append(contentsOf: eventArgs)
        return [.array(items)]
    }

    // MARK: - Parameterless events

    func testFlush() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("flush", []))
        XCTAssertEqual(events.count, 1)
        if case .flush = events[0] {} else { XCTFail("Expected flush") }
    }

    func testBell() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("bell", []))
        XCTAssertEqual(events.count, 1)
        if case .bell = events[0] {} else { XCTFail("Expected bell") }
    }

    func testVisualBell() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("visual_bell", []))
        XCTAssertEqual(events.count, 1)
        if case .visualBell = events[0] {} else { XCTFail("Expected visualBell") }
    }

    func testMouseOn() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("mouse_on", []))
        XCTAssertEqual(events.count, 1)
        if case .mouseOn = events[0] {} else { XCTFail("Expected mouseOn") }
    }

    func testMouseOff() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("mouse_off", []))
        XCTAssertEqual(events.count, 1)
        if case .mouseOff = events[0] {} else { XCTFail("Expected mouseOff") }
    }

    func testBusyStart() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("busy_start", []))
        XCTAssertEqual(events.count, 1)
        if case .busyStart = events[0] {} else { XCTFail("Expected busyStart") }
    }

    func testBusyStop() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("busy_stop", []))
        XCTAssertEqual(events.count, 1)
        if case .busyStop = events[0] {} else { XCTFail("Expected busyStop") }
    }

    // MARK: - gridResize

    func testGridResize() {
        let args: [MessagePackValue] = [.array([.int(1), .int(80), .int(24)])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("grid_resize", args))
        XCTAssertEqual(events.count, 1)
        if case .gridResize(let grid, let width, let height) = events[0] {
            XCTAssertEqual(grid, 1)
            XCTAssertEqual(width, 80)
            XCTAssertEqual(height, 24)
        } else {
            XCTFail("Expected gridResize")
        }
    }

    // MARK: - gridLine

    func testGridLine() {
        // grid_line [grid, row, col_start, [[text, hl_id], ...]]
        let cells: MessagePackValue = .array([
            .array([.string("H"), .int(5)]),
            .array([.string("i"), .int(5)]),
        ])
        let args: [MessagePackValue] = [.array([.int(1), .int(3), .int(0), cells])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("grid_line", args))
        XCTAssertEqual(events.count, 1)
        if case .gridLine(let grid, let row, let colStart, let parsedCells) = events[0] {
            XCTAssertEqual(grid, 1)
            XCTAssertEqual(row, 3)
            XCTAssertEqual(colStart, 0)
            XCTAssertEqual(parsedCells.count, 2)
            XCTAssertEqual(parsedCells[0], GridCellData(text: "H", hlId: 5, repeats: 1))
            XCTAssertEqual(parsedCells[1], GridCellData(text: "i", hlId: 5, repeats: 1))
        } else {
            XCTFail("Expected gridLine")
        }
    }

    func testGridLineWithRepeat() {
        // Third element in cell array is repeat count; hl_id is sticky when omitted
        let cells: MessagePackValue = .array([
            .array([.string("A"), .int(7), .int(3)]),
            .array([.string("B")]),  // no hlId — should inherit 7; no repeat — defaults to 1
        ])
        let args: [MessagePackValue] = [.array([.int(1), .int(0), .int(5), cells])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("grid_line", args))
        XCTAssertEqual(events.count, 1)
        if case .gridLine(_, _, _, let parsedCells) = events[0] {
            XCTAssertEqual(parsedCells.count, 2)
            XCTAssertEqual(parsedCells[0], GridCellData(text: "A", hlId: 7, repeats: 3))
            XCTAssertEqual(parsedCells[1], GridCellData(text: "B", hlId: 7, repeats: 1))
        } else {
            XCTFail("Expected gridLine")
        }
    }

    // MARK: - hlAttrDefine

    func testHlAttrDefine() {
        let rgbAttrs: MessagePackValue = .map([.string("bold"): .bool(true), .string("foreground"): .int(0xFF0000)])
        let ctermAttrs: MessagePackValue = .map([:])
        let info: MessagePackValue = .array([])
        let args: [MessagePackValue] = [.array([.int(10), rgbAttrs, ctermAttrs, info])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("hl_attr_define", args))
        XCTAssertEqual(events.count, 1)
        if case .hlAttrDefine(let id, let rgb, _, _) = events[0] {
            XCTAssertEqual(id, 10)
            XCTAssertEqual(rgb["bold"], .bool(true))
            XCTAssertEqual(rgb["foreground"], .int(0xFF0000))
        } else {
            XCTFail("Expected hlAttrDefine")
        }
    }

    // MARK: - defaultColorsSet

    func testDefaultColorsSet() {
        let args: [MessagePackValue] = [.array([.int(0xFFFFFF), .int(0x000000), .int(0xFF00FF), .int(15), .int(0)])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("default_colors_set", args))
        XCTAssertEqual(events.count, 1)
        if case .defaultColorsSet(let fg, let bg, let sp, let ctermFg, let ctermBg) = events[0] {
            XCTAssertEqual(fg, 0xFFFFFF)
            XCTAssertEqual(bg, 0x000000)
            XCTAssertEqual(sp, 0xFF00FF)
            XCTAssertEqual(ctermFg, 15)
            XCTAssertEqual(ctermBg, 0)
        } else {
            XCTFail("Expected defaultColorsSet")
        }
    }

    // MARK: - gridScroll

    func testGridScroll() {
        let args: [MessagePackValue] = [.array([.int(1), .int(0), .int(24), .int(0), .int(80), .int(3), .int(0)])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("grid_scroll", args))
        XCTAssertEqual(events.count, 1)
        if case .gridScroll(let grid, let top, let bottom, let left, let right, let rows, let cols) = events[0] {
            XCTAssertEqual(grid, 1)
            XCTAssertEqual(top, 0)
            XCTAssertEqual(bottom, 24)
            XCTAssertEqual(left, 0)
            XCTAssertEqual(right, 80)
            XCTAssertEqual(rows, 3)
            XCTAssertEqual(cols, 0)
        } else {
            XCTFail("Expected gridScroll")
        }
    }

    // MARK: - gridCursorGoto

    func testGridCursorGoto() {
        let args: [MessagePackValue] = [.array([.int(1), .int(10), .int(5)])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("grid_cursor_goto", args))
        XCTAssertEqual(events.count, 1)
        if case .gridCursorGoto(let grid, let row, let col) = events[0] {
            XCTAssertEqual(grid, 1)
            XCTAssertEqual(row, 10)
            XCTAssertEqual(col, 5)
        } else {
            XCTFail("Expected gridCursorGoto")
        }
    }

    // MARK: - modeChange

    func testModeChange() {
        let args: [MessagePackValue] = [.array([.string("insert"), .int(2)])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("mode_change", args))
        XCTAssertEqual(events.count, 1)
        if case .modeChange(let mode, let idx) = events[0] {
            XCTAssertEqual(mode, "insert")
            XCTAssertEqual(idx, 2)
        } else {
            XCTFail("Expected modeChange")
        }
    }

    // MARK: - tablineUpdate

    func testTablineUpdate() {
        let tab1: MessagePackValue = .map([.string("tab"): .int(1), .string("name"): .string("index.swift")])
        let tab2: MessagePackValue = .map([.string("tab"): .int(2), .string("name"): .string("App.swift")])
        let args: [MessagePackValue] = [.array([.int(1), .array([tab1, tab2])])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("tabline_update", args))
        XCTAssertEqual(events.count, 1)
        if case .tablineUpdate(let current, let tabs) = events[0] {
            XCTAssertEqual(current, 1)
            XCTAssertEqual(tabs.count, 2)
            XCTAssertEqual(tabs[0].name, "index.swift")
            XCTAssertEqual(tabs[1].handle, 2)
        } else {
            XCTFail("Expected tablineUpdate")
        }
    }

    // MARK: - setTitle

    func testSetTitle() {
        let args: [MessagePackValue] = [.array([.string("My Title")])]
        let events = NvimEvent.parse(redrawArgs: redrawArgs("set_title", args))
        XCTAssertEqual(events.count, 1)
        if case .setTitle(let title) = events[0] {
            XCTAssertEqual(title, "My Title")
        } else {
            XCTFail("Expected setTitle")
        }
    }

    // MARK: - Multiple events in one redraw batch

    func testMultipleEvents() {
        var redrawArgsList: [MessagePackValue] = []
        // flush
        redrawArgsList.append(.array([.string("flush")]))
        // grid_resize [1, 120, 40]
        redrawArgsList.append(.array([.string("grid_resize"), .array([.int(1), .int(120), .int(40)])]))
        let events = NvimEvent.parse(redrawArgs: redrawArgsList)
        XCTAssertEqual(events.count, 2)
        if case .flush = events[0] {} else { XCTFail("Expected flush at index 0") }
        if case .gridResize(let g, let w, let h) = events[1] {
            XCTAssertEqual(g, 1)
            XCTAssertEqual(w, 120)
            XCTAssertEqual(h, 40)
        } else {
            XCTFail("Expected gridResize at index 1")
        }
    }

    // MARK: - Unknown event

    func testUnknownEvent() {
        let events = NvimEvent.parse(redrawArgs: redrawArgs("unknown_future_event", [.array([.int(1)])]))
        XCTAssertEqual(events.count, 0)
    }
}
