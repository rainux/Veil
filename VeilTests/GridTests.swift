import Foundation
import Testing
import MessagePack
@testable import Veil

@MainActor
final class GridTests {

    var grid: Grid

    init() {
        grid = Grid()
        grid.resize(width: 5, height: 3)
    }

    @Test func gridResize() {
        #expect(grid.size.rows == 3)
        #expect(grid.size.cols == 5)
        #expect(grid.cells.count == 3)
        #expect(grid.cells[0].count == 5)
        #expect(grid.dirtyRows == IndexSet(0..<3))
    }

    @Test func gridLine() {
        grid.clearDirty()
        let cells = [
            GridCellData(text: "H", hlId: 1, repeats: 1),
            GridCellData(text: "i", hlId: 1, repeats: 1),
        ]
        grid.putCells(row: 1, colStart: 0, data: cells)
        #expect(grid.cells[1][0].text == "H")
        #expect(grid.cells[1][1].text == "i")
        #expect(grid.cells[1][2].text == " ")
        #expect(grid.dirtyRows.contains(1))
        #expect(!grid.dirtyRows.contains(0))
    }

    @Test func gridLineWithRepeat() {
        grid.clearDirty()
        let cells = [GridCellData(text: "-", hlId: 0, repeats: 4)]
        grid.putCells(row: 0, colStart: 1, data: cells)
        #expect(grid.cells[0][0].text == " ")
        #expect(grid.cells[0][1].text == "-")
        #expect(grid.cells[0][2].text == "-")
        #expect(grid.cells[0][3].text == "-")
        #expect(grid.cells[0][4].text == "-")
    }

    @Test func clearDirty() {
        #expect(grid.dirtyRows.count > 0)
        grid.clearDirty()
        #expect(grid.dirtyRows.count == 0)
    }

    @Test func gridClear() {
        let cells = [GridCellData(text: "X", hlId: 0, repeats: 1)]
        grid.putCells(row: 0, colStart: 0, data: cells)
        grid.clearDirty()
        grid.clear()
        #expect(grid.cells[0][0].text == " ")
        #expect(grid.dirtyRows == IndexSet(0..<3))
    }

    @Test func scrollDown() {
        // Fill rows: row0="AAAAA", row1="BBBBB", row2="CCCCC"
        grid.putCells(row: 0, colStart: 0, data: [GridCellData(text: "A", hlId: 0, repeats: 5)])
        grid.putCells(row: 1, colStart: 0, data: [GridCellData(text: "B", hlId: 0, repeats: 5)])
        grid.putCells(row: 2, colStart: 0, data: [GridCellData(text: "C", hlId: 0, repeats: 5)])
        grid.clearDirty()

        // Scroll up by 1: rows shift up, row2 becomes empty
        grid.scroll(top: 0, bottom: 3, left: 0, right: 5, rows: 1)
        #expect(grid.cells[0][0].text == "B")
        #expect(grid.cells[1][0].text == "C")
        #expect(grid.cells[2][0].text == " ")
        #expect(grid.dirtyRows == IndexSet(0..<3))
    }

    @Test func scrollUp() {
        // Fill rows
        grid.putCells(row: 0, colStart: 0, data: [GridCellData(text: "A", hlId: 0, repeats: 5)])
        grid.putCells(row: 1, colStart: 0, data: [GridCellData(text: "B", hlId: 0, repeats: 5)])
        grid.putCells(row: 2, colStart: 0, data: [GridCellData(text: "C", hlId: 0, repeats: 5)])
        grid.clearDirty()

        // Scroll down by 1 (rows = -1): content shifts down, row0 becomes empty
        grid.scroll(top: 0, bottom: 3, left: 0, right: 5, rows: -1)
        #expect(grid.cells[0][0].text == " ")
        #expect(grid.cells[1][0].text == "A")
        #expect(grid.cells[2][0].text == "B")
        #expect(grid.dirtyRows == IndexSet(0..<3))
    }

    @Test func cursorGoto() {
        grid.cursorGoto(row: 2, col: 3)
        #expect(grid.cursorPosition.row == 2)
        #expect(grid.cursorPosition.col == 3)
    }

    @Test func hlAttrDefine() {
        let event = NvimEvent.hlAttrDefine(id: 42, rgbAttrs: ["foreground": .uint(0xAABBCC), "bold": .bool(true)], ctermAttrs: [:], info: [])
        grid.apply(event)
        let attr = grid.attributes[42]
        #expect(attr != nil)
        #expect(attr?.foreground == 0xAABBCC)
        #expect(attr?.bold == true)
    }
}
