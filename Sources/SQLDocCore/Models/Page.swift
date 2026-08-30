import Foundation

/// One per-column filter from the filter bar.
public struct ColumnFilter: Equatable, Sendable, Hashable {
    public enum Op: String, CaseIterable, Sendable {
        case contains, equals, notEquals, startsWith, greater, less, isNull, isNotNull
        public var label: String {
            switch self {
            case .contains: return "contains"
            case .equals: return "="
            case .notEquals: return "≠"
            case .startsWith: return "starts with"
            case .greater: return ">"
            case .less: return "<"
            case .isNull: return "is null"
            case .isNotNull: return "is not null"
            }
        }
        public var needsValue: Bool { self != .isNull && self != .isNotNull }
    }

    public let column: String
    public let op: Op
    public let value: String

    public init(column: String, op: Op = .contains, value: String) {
        self.column = column
        self.op = op
        self.value = value
    }

    /// SQL fragment + bound args for this filter. Column already quoted by caller.
    func sql(quotedColumn q: String) -> (clause: String, args: [Any]) {
        switch op {
        case .contains:    return ("CAST(\(q) AS TEXT) LIKE ? ESCAPE '\\'", ["%\(escapeLike(value))%"])
        case .startsWith:  return ("CAST(\(q) AS TEXT) LIKE ? ESCAPE '\\'", ["\(escapeLike(value))%"])
        case .equals:      return ("\(q) = ?", [value])
        case .notEquals:   return ("(\(q) IS NULL OR \(q) <> ?)", [value])
        case .greater:     return ("\(q) > ?", [numericBind(value)])
        case .less:        return ("\(q) < ?", [numericBind(value)])
        case .isNull:      return ("\(q) IS NULL", [])
        case .isNotNull:   return ("\(q) IS NOT NULL", [])
        }
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
    private func numericBind(_ s: String) -> Any {
        if let i = Int64(s) { return i }
        if let d = Double(s) { return d }
        return s
    }
}

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
    /// Per-column filters, ANDed together.
    public var filters: [ColumnFilter]
    /// Show only rows at ordinals 1, 2, 4, 8, 16, … — a logarithmic spot-check.
    public var powerSample: Bool

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
        afterSortValue: SQLiteValue? = nil,
        filters: [ColumnFilter] = [],
        powerSample: Bool = false
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
        self.filters = filters
        self.powerSample = powerSample
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
