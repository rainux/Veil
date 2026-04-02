import Foundation
import MessagePack

@MainActor
final class Grid {
    // MARK: - State

    var cells: [[Cell]]
    var size: GridSize
    var cursorPosition: Position
    var dirtyRows: IndexSet

    var attributes: [Int: CellAttributes]
    var defaultForeground: Int
    var defaultBackground: Int
    var defaultSpecial: Int

    /// Per-row array mapping column index to UTF-16 flat char index, for IME support.
    var flatCharIndices: [[Int]]

    // MARK: - Init

    init() {
        cells = []
        size = .zero
        cursorPosition = .zero
        dirtyRows = IndexSet()
        attributes = [:]
        defaultForeground = 0x000000
        defaultBackground = 0xFFFFFF
        defaultSpecial = 0xFF0000
        flatCharIndices = []
    }

    // MARK: - Public methods

    func resize(width: Int, height: Int) {
        let newSize = GridSize(rows: height, cols: width)
        guard newSize != size else { return }

        var newCells = Array(
            repeating: Array(repeating: Cell.empty, count: width),
            count: height
        )
        // Preserve existing cells within bounds
        let minRows = min(size.rows, height)
        let minCols = min(size.cols, width)
        for r in 0..<minRows {
            for c in 0..<minCols {
                newCells[r][c] = cells[r][c]
            }
        }
        cells = newCells
        size = newSize
        recomputeFlatCharIndices()
        dirtyRows = IndexSet(0..<height)
    }

    func putCells(row: Int, colStart: Int, data: [GridCellData]) {
        guard row >= 0 && row < size.rows else { return }
        var col = colStart
        for cellData in data {
            let count = cellData.repeats
            guard count > 0 else { continue }
            let utf16Len = cellData.text.utf16.count
            let cell = Cell(text: cellData.text, hlId: cellData.hlId, utf16Length: max(utf16Len, 1))
            for _ in 0..<count {
                guard col < size.cols else { break }
                cells[row][col] = cell
                col += 1
            }
        }
        dirtyRows.insert(row)
        recomputeFlatCharIndices(row: row)
    }

    func clear() {
        let emptyRow = Array(repeating: Cell.empty, count: size.cols)
        for r in 0..<size.rows {
            cells[r] = emptyRow
        }
        dirtyRows = IndexSet(0..<size.rows)
        recomputeFlatCharIndices()
    }

    func cursorGoto(row: Int, col: Int) {
        cursorPosition = Position(row: row, col: col)
    }

    /// Scroll within a region.
    /// Positive rows = shift content up (rows scroll up, new blank rows appear at bottom).
    /// Negative rows = shift content down (rows scroll down, new blank rows appear at top).
    /// Scroll within a region. Neovim sends exclusive bounds (bottom, right),
    /// so we convert to inclusive internally: bot = bottom - 1, rt = right - 1.
    func scroll(top: Int, bottom: Int, left: Int, right: Int, rows: Int) {
        guard rows != 0 else { return }
        // Neovim grid_scroll uses exclusive bottom/right
        let bot = bottom - 1
        let rt = right - 1
        guard top >= 0, bot < size.rows, left >= 0, rt < size.cols else { return }

        let colRange = left...rt

        if rows > 0 {
            for destRow in top...(bot - rows) {
                let srcRow = destRow + rows
                guard srcRow <= bot else { continue }
                cells[destRow].replaceSubrange(colRange, with: cells[srcRow][colRange])
                dirtyRows.insert(destRow)
                recomputeFlatCharIndices(row: destRow)
            }
            for r in (bot - rows + 1)...bot {
                for col in colRange { cells[r][col] = .empty }
                dirtyRows.insert(r)
                recomputeFlatCharIndices(row: r)
            }
        } else {
            let absRows = -rows
            for destRow in stride(from: bot, through: top + absRows, by: -1) {
                let srcRow = destRow - absRows
                guard srcRow >= top else { continue }
                cells[destRow].replaceSubrange(colRange, with: cells[srcRow][colRange])
                dirtyRows.insert(destRow)
                recomputeFlatCharIndices(row: destRow)
            }
            for r in top..<(top + absRows) {
                for col in colRange { cells[r][col] = .empty }
                dirtyRows.insert(r)
                recomputeFlatCharIndices(row: r)
            }
        }
    }

    func defineHighlight(id: Int, rgbAttrs: [String: any Any]) {
        // Build a CellAttributes from a plain [String: Any] dict for testing convenience
        var fg = -1, bg = -1, sp = -1
        var bold = false, italic = false
        var underline = false, undercurl = false
        var underdouble = false, underdotted = false, underdashed = false
        var strikethrough = false, reverse = false
        var blend = 0
        for (k, v) in rgbAttrs {
            switch k {
            case "foreground": fg = v as? Int ?? -1
            case "background": bg = v as? Int ?? -1
            case "special": sp = v as? Int ?? -1
            case "bold": bold = v as? Bool ?? false
            case "italic": italic = v as? Bool ?? false
            case "underline": underline = v as? Bool ?? false
            case "undercurl": undercurl = v as? Bool ?? false
            case "underdouble": underdouble = v as? Bool ?? false
            case "underdotted": underdotted = v as? Bool ?? false
            case "underdashed": underdashed = v as? Bool ?? false
            case "strikethrough": strikethrough = v as? Bool ?? false
            case "reverse": reverse = v as? Bool ?? false
            case "blend": blend = v as? Int ?? 0
            default: break
            }
        }
        attributes[id] = CellAttributes(
            foreground: fg, background: bg, special: sp,
            bold: bold, italic: italic,
            underline: underline, undercurl: undercurl,
            underdouble: underdouble, underdotted: underdotted, underdashed: underdashed,
            strikethrough: strikethrough, reverse: reverse, blend: blend
        )
    }

    func setDefaultColors(fg: Int, bg: Int, sp: Int) {
        defaultForeground = fg
        defaultBackground = bg
        defaultSpecial = sp
        dirtyRows = IndexSet(0..<size.rows)
    }

    func clearDirty() {
        dirtyRows.removeAll()
    }

    // MARK: - Event dispatch

    func apply(_ event: NvimEvent) {
        switch event {
        case let .gridResize(_, width, height):
            resize(width: width, height: height)

        case let .gridLine(_, row, colStart, cellsData):
            putCells(row: row, colStart: colStart, data: cellsData)

        case .gridClear:
            clear()

        case let .gridCursorGoto(_, row, col):
            cursorGoto(row: row, col: col)

        case let .gridScroll(_, top, bottom, left, right, rows, _):
            scroll(top: top, bottom: bottom, left: left, right: right, rows: rows)

        case let .hlAttrDefine(id, rgbAttrs, _, _):
            var mpDict: [MessagePackValue: MessagePackValue] = [:]
            for (k, v) in rgbAttrs {
                mpDict[.string(k)] = v
            }
            attributes[id] = CellAttributes(from: .map(mpDict))

        case let .defaultColorsSet(rgbFg, rgbBg, rgbSp, _, _):
            setDefaultColors(fg: rgbFg, bg: rgbBg, sp: rgbSp)

        default:
            break
        }
    }

    // MARK: - Private helpers

    private func recomputeFlatCharIndices() {
        flatCharIndices = cells.enumerated().map { _, row in
            computeIndicesForRow(row)
        }
    }

    private func recomputeFlatCharIndices(row: Int) {
        guard row >= 0 && row < size.rows else { return }
        while flatCharIndices.count <= row {
            flatCharIndices.append([])
        }
        flatCharIndices[row] = computeIndicesForRow(cells[row])
    }

    private func computeIndicesForRow(_ row: [Cell]) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(row.count)
        var flatIdx = 0
        for cell in row {
            indices.append(flatIdx)
            flatIdx += cell.utf16Length
        }
        return indices
    }
}
