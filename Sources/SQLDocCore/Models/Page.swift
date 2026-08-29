import Foundation

/// Window describes the slice of a table the viewer requests.
public struct Window: Equatable, Sendable {
    public var table: String
    public var limit: Int
    public var after: Int64
    public var useAfter: Bool
    public var offset: Int64
    public var sort: String?
    public var desc: Bool
    public var forceOffset: Bool
    /// Sort as a number rather than by SQLite's storage-class/text collation.
    public var sortNumeric: Bool
    /// Keyset anchor for sorted forward paging: the sort-column value of the last
    /// row on the current page. When present (and non-null) the sorted path seeks
    /// past `(afterSortValue, after)` instead of counting `OFFSET` rows.
    public var afterSortValue: SQLiteValue?

    public init(
        table: String,
        limit: Int = 100,
        after: Int64 = 0,
        useAfter: Bool = false,
        offset: Int64 = 0,
        sort: String? = nil,
        desc: Bool = false,
        forceOffset: Bool = false,
        sortNumeric: Bool = false,
        afterSortValue: SQLiteValue? = nil
    ) {
        self.table = table
        self.limit = limit
        self.after = after
        self.useAfter = useAfter
        self.offset = offset
        self.sort = sort
        self.desc = desc
        self.forceOffset = forceOffset
        self.sortNumeric = sortNumeric
        self.afterSortValue = afterSortValue
    }
}

/// One display-ready cell: text already clamped to a sane length off the main
/// thread, with a flag when it was clipped.
public struct CellText: Equatable, Sendable {
    public let text: String
    public let truncated: Bool
    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}

/// Page represents one rendered window of a table.
public struct Page: Equatable, Sendable {
    public let table: String
    public let columns: [Column]
    public var rows: [[SQLiteValue]]
    /// Display-ready text for every cell, built alongside `rows` off the main
    /// thread. Same shape as `rows`. The view renders these directly.
    public var text: [[CellText]]
    public var rowIDs: [Int64]
    public var start: Int64
    public var approx: Bool
    public var path: String // "keyset", "interpolated", "offset", "sorted-keyset", "sorted-offset"
    public var micros: Int64

    /// Max characters kept per cell string. Longer values are clipped here so the
    /// UI never lays out a huge string. Sourced from the config database.
    public static let cellTextMaxChars = BehaviorConfig.textCellDisplayMaxChars

    public init(
        table: String,
        columns: [Column],
        rows: [[SQLiteValue]] = [],
        text: [[CellText]]? = nil,
        rowIDs: [Int64] = [],
        start: Int64 = 0,
        approx: Bool = false,
        path: String = "offset",
        micros: Int64 = 0
    ) {
        self.table = table
        self.columns = columns
        self.rows = rows
        self.text = text ?? rows.map { row in
            row.map { v in
                let c = v.gridCell(maxChars: Page.cellTextMaxChars)
                return CellText(text: c.text, truncated: c.truncated)
            }
        }
        self.rowIDs = rowIDs
        self.start = start
        self.approx = approx
        self.path = path
        self.micros = micros
    }
}
