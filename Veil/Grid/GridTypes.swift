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
