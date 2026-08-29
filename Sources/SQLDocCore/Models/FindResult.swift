import Foundation

/// Match is one search hit inside a table.
public struct FindMatch: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(rowID):\(column)" }
    public let rowID: Int64
    public let column: Int
    public let row: [SQLiteValue]

    public init(rowID: Int64, column: Int, row: [SQLiteValue]) {
        self.rowID = rowID
        self.column = column
        self.row = row
    }
}

/// FindResult represents one bounded increment of a table search.
public struct FindResult: Equatable, Sendable {
    public var matches: [FindMatch]
    public var next: Int64
    public var done: Bool
    public var scanned: Int64
    public var progress: Double // 0.0 ... 1.0
    public var micros: Int64

    public init(
        matches: [FindMatch] = [],
        next: Int64 = 0,
        done: Bool = false,
        scanned: Int64 = 0,
        progress: Double = 0.0,
        micros: Int64 = 0
    ) {
        self.matches = matches
        self.next = next
        self.done = done
        self.scanned = scanned
        self.progress = progress
        self.micros = micros
    }
}
