import Foundation
import MessagePack

// MARK: - Supporting types

struct GridCellData: Equatable, Sendable {
    var text: String
    var hlId: Int
    var repeats: Int
}

struct TabpageInfo: Equatable, Sendable {
    var handle: Int
    var name: String
}

struct ModeInfo: Equatable, Sendable {
    enum CursorShape: String, Equatable, Sendable {
        case block
        case horizontal
        case vertical
    }

    var name: String
    var cursorShape: CursorShape
    var cellPercentage: Int
}

// MARK: - NvimEvent

enum NvimEvent: Sendable {
    case gridResize(grid: Int, width: Int, height: Int)
    case gridLine(grid: Int, row: Int, colStart: Int, cells: [GridCellData])
    case gridClear(grid: Int)
    case gridCursorGoto(grid: Int, row: Int, col: Int)
    case gridScroll(grid: Int, top: Int, bottom: Int, left: Int, right: Int, rows: Int, cols: Int)
    case flush
    case hlAttrDefine(id: Int, rgbAttrs: [String: MessagePackValue], ctermAttrs: [String: MessagePackValue], info: [MessagePackValue])
    case defaultColorsSet(rgbFg: Int, rgbBg: Int, rgbSp: Int, ctermFg: Int, ctermBg: Int)
    case modeChange(mode: String, modeIdx: Int)
    case modeInfoSet(enabled: Bool, modeInfoList: [ModeInfo])
    case tablineUpdate(current: Int, tabs: [TabpageInfo])
    case setTitle(title: String)
    case optionSet(name: String, value: MessagePackValue)
    case bell
    case visualBell
    case mouseOn
    case mouseOff
    case busyStart
    case busyStop
    case veilBufChanged

    // MARK: - Parse

    nonisolated static func parse(redrawArgs: [MessagePackValue]) -> [NvimEvent] {
        var events: [NvimEvent] = []
        for arg in redrawArgs {
            guard let array = arg.arrayValue, let eventName = array.first?.stringValue else {
                continue
            }
            let eventArgs = Array(array.dropFirst())
            switch eventName {
            case "flush":
                events.append(.flush)
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
            case "grid_resize":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 3 else { continue }
                    let grid = a[0].intValue
                    let width = a[1].intValue
                    let height = a[2].intValue
                    events.append(.gridResize(grid: grid, width: width, height: height))
                }
            case "grid_line":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 4 else { continue }
                    let grid = a[0].intValue
                    let row = a[1].intValue
                    let colStart = a[2].intValue
                    guard let rawCells = a[3].arrayValue else { continue }
                    let cells = parseGridLineCells(rawCells)
                    events.append(.gridLine(grid: grid, row: row, colStart: colStart, cells: cells))
                }
            case "grid_clear":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 1 else { continue }
                    events.append(.gridClear(grid: a[0].intValue))
                }
            case "grid_cursor_goto":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 3 else { continue }
                    events.append(.gridCursorGoto(grid: a[0].intValue, row: a[1].intValue, col: a[2].intValue))
                }
            case "grid_scroll":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 7 else { continue }
                    events.append(.gridScroll(
                        grid: a[0].intValue,
                        top: a[1].intValue,
                        bottom: a[2].intValue,
                        left: a[3].intValue,
                        right: a[4].intValue,
                        rows: a[5].intValue,
                        cols: a[6].intValue
                    ))
                }
            case "hl_attr_define":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 4 else { continue }
                    let id = a[0].intValue
                    let rgbAttrs = a[1].dictionaryValue.flatMap { dict -> [String: MessagePackValue]? in
                        var result: [String: MessagePackValue] = [:]
                        for (k, v) in dict {
                            if let key = k.stringValue { result[key] = v }
                        }
                        return result
                    } ?? [:]
                    let ctermAttrs = a[2].dictionaryValue.flatMap { dict -> [String: MessagePackValue]? in
                        var result: [String: MessagePackValue] = [:]
                        for (k, v) in dict {
                            if let key = k.stringValue { result[key] = v }
                        }
                        return result
                    } ?? [:]
                    let info = a[3].arrayValue ?? []
                    events.append(.hlAttrDefine(id: id, rgbAttrs: rgbAttrs, ctermAttrs: ctermAttrs, info: info))
                }
            case "default_colors_set":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 5 else { continue }
                    events.append(.defaultColorsSet(
                        rgbFg: a[0].intValue,
                        rgbBg: a[1].intValue,
                        rgbSp: a[2].intValue,
                        ctermFg: a[3].intValue,
                        ctermBg: a[4].intValue
                    ))
                }
            case "mode_change":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let mode = a[0].stringValue else { continue }
                    events.append(.modeChange(mode: mode, modeIdx: a[1].intValue))
                }
            case "mode_info_set":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let enabled = a[0].boolValue,
                          let rawList = a[1].arrayValue else { continue }
                    let modeInfoList = rawList.compactMap { parseModeInfo($0) }
                    events.append(.modeInfoSet(enabled: enabled, modeInfoList: modeInfoList))
                }
            case "tabline_update":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let rawTabs = a[1].arrayValue else { continue }
                    let current = a[0].intValue
                    let tabs = rawTabs.compactMap { parseTabpageInfo($0) }
                    events.append(.tablineUpdate(current: current, tabs: tabs))
                }
            case "set_title":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 1,
                          let title = a[0].stringValue else { continue }
                    events.append(.setTitle(title: title))
                }
            case "option_set":
                for args in eventArgs {
                    guard let a = args.arrayValue, a.count >= 2,
                          let name = a[0].stringValue else { continue }
                    events.append(.optionSet(name: name, value: a[1]))
                }
            default:
                break
            }
        }
        return events
    }

    // MARK: - Private helpers

    private nonisolated static func parseGridLineCells(_ rawCells: [MessagePackValue]) -> [GridCellData] {
        var cells: [GridCellData] = []
        var lastHlId = 0
        for cell in rawCells {
            guard let a = cell.arrayValue, !a.isEmpty,
                  let text = a[0].stringValue else { continue }
            // hlId is optional — if missing, reuse lastHlId (sticky)
            if a.count >= 2 {
                lastHlId = a[1].intValue
            }
            let repeats = a.count >= 3 ? a[2].intValue : 1
            cells.append(GridCellData(text: text, hlId: lastHlId, repeats: repeats))
        }
        return cells
    }

    private nonisolated static func parseModeInfo(_ value: MessagePackValue) -> ModeInfo? {
        guard let dict = value.dictionaryValue else { return nil }
        var name = ""
        var shape = ModeInfo.CursorShape.block
        var cellPercentage = 0
        for (k, v) in dict {
            switch k.stringValue {
            case "name":
                name = v.stringValue ?? ""
            case "cursor_shape":
                shape = ModeInfo.CursorShape(rawValue: v.stringValue ?? "") ?? .block
            case "cell_percentage":
                cellPercentage = v.intValue
            default:
                break
            }
        }
        return ModeInfo(name: name, cursorShape: shape, cellPercentage: cellPercentage)
    }

    private nonisolated static func parseTabpageInfo(_ value: MessagePackValue) -> TabpageInfo? {
        guard let dict = value.dictionaryValue else { return nil }
        var handle = 0
        var tabName = ""
        for (k, v) in dict {
            switch k.stringValue {
            case "tab":
                handle = v.intValue
            case "name":
                tabName = v.stringValue ?? ""
            default:
                break
            }
        }
        return TabpageInfo(handle: handle, name: tabName)
    }
}
