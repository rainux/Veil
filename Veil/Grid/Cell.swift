import Foundation

let _emptyCell = Cell(text: " ", hlId: 0, utf16Length: 1)

struct Cell: Equatable, Sendable {
    var text: String
    var hlId: Int
    var utf16Length: Int

    static var empty: Cell { _emptyCell }
}
