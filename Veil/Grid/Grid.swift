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
    /// Rows are lazily recomputed on access; see ensureFlatCharIndices(row:).
    var flatCharIndices: [[Int]]

    /// Tracks which rows need flatCharIndices recomputation.
    /// Indices are lazily recomputed only when accessed (for IME cursor positioning),
    /// avoiding redundant work during bulk cell updates and scrolling.
    private var flatCharDirtyRows = IndexSet()

    // MARK: - Init

    init() {
        cells = []
        size = .zero
        cursorPosition = .zero
        dirtyRows = IndexSet()
        attributes = [:]
        defaultForeground =
            UserDefaults.standard.object(forKey: "VeilDefaultFg") as? Int ?? 0xCCCCCC
        defaultBackground =
            UserDefaults.standard.object(forKey: "VeilDefaultBg") as? Int ?? 0x1E1E2E
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
        // Allocate flatCharIndices to correct size but defer computation
        flatCharIndices = Array(repeating: [], count: height)
        flatCharDirtyRows = IndexSet(0..<height)
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
        flatCharDirtyRows.insert(row)
    }

    func clear() {
        let emptyRow = Array(repeating: Cell.empty, count: size.cols)
        for r in 0..<size.rows {
            cells[r] = emptyRow
        }
        dirtyRows = IndexSet(0..<size.rows)
        flatCharDirtyRows = IndexSet(0..<size.rows)
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
                flatCharDirtyRows.insert(destRow)
            }
            for r in (bot - rows + 1)...bot {
                for col in colRange { cells[r][col] = .empty }
                dirtyRows.insert(r)
                flatCharDirtyRows.insert(r)
            }
        } else {
            let absRows = -rows
            for destRow in stride(from: bot, through: top + absRows, by: -1) {
                let srcRow = destRow - absRows
                guard srcRow >= top else { continue }
                cells[destRow].replaceSubrange(colRange, with: cells[srcRow][colRange])
                dirtyRows.insert(destRow)
                flatCharDirtyRows.insert(destRow)
            }
            for r in top..<(top + absRows) {
                for col in colRange { cells[r][col] = .empty }
                dirtyRows.insert(r)
                flatCharDirtyRows.insert(r)
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

    // MARK: - Lazy flatCharIndices

    /// Recompute all stale flatCharIndices rows at once.
    /// Called before copying to NvimView for IME support.
    func ensureAllFlatCharIndices() {
        guard !flatCharDirtyRows.isEmpty else { return }
        for row in flatCharDirtyRows {
            guard row < size.rows else { continue }
            while flatCharIndices.count <= row {
                flatCharIndices.append([])
            }
            flatCharIndices[row] = computeIndicesForRow(cells[row])
        }
        flatCharDirtyRows.removeAll()
    }

    /// Recompute flatCharIndices for a single row if it was marked stale.
    func ensureFlatCharIndices(row: Int) {
        guard flatCharDirtyRows.contains(row) else { return }
        guard row >= 0 && row < size.rows else { return }
        while flatCharIndices.count <= row {
            flatCharIndices.append([])
        }
        flatCharIndices[row] = computeIndicesForRow(cells[row])
        flatCharDirtyRows.remove(row)
    }

    // MARK: - Private helpers

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
