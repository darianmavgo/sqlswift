import Foundation

/// TableCount represents what is currently known about a table's row count.
/// Inexact estimates are published immediately in O(1) and refined in the background.
public struct TableCount: Equatable, Codable, Sendable {
    public var rows: Int64
    public var exact: Bool
    public var known: Bool

    public init(rows: Int64 = 0, exact: Bool = false, known: Bool = false) {
        self.rows = rows
        self.exact = exact
        self.known = known
    }

    public var displayString: String {
        if !known { return "?" }
        let formatted = SQLiteValueFormat.integerString(rows)
        return exact ? formatted : "\(formatted)~"
    }

    public static let unknown = TableCount(rows: 0, exact: false, known: false)
}
