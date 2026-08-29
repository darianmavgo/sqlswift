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

    public init(
        table: String,
        limit: Int = 100,
        after: Int64 = 0,
        useAfter: Bool = false,
        offset: Int64 = 0,
        sort: String? = nil,
        desc: Bool = false,
        forceOffset: Bool = false
    ) {
        self.table = table
        self.limit = limit
        self.after = after
        self.useAfter = useAfter
        self.offset = offset
        self.sort = sort
        self.desc = desc
        self.forceOffset = forceOffset
    }
}

/// Page represents one rendered window of a table.
public struct Page: Equatable, Sendable {
    public let table: String
    public let columns: [Column]
    public var rows: [[SQLiteValue]]
    public var rowIDs: [Int64]
    public var start: Int64
    public var approx: Bool
    public var path: String // "keyset", "interpolated", "offset", "sorted-offset"
    public var micros: Int64

    public init(
        table: String,
        columns: [Column],
        rows: [[SQLiteValue]] = [],
        rowIDs: [Int64] = [],
        start: Int64 = 0,
        approx: Bool = false,
        path: String = "offset",
        micros: Int64 = 0
    ) {
        self.table = table
        self.columns = columns
        self.rows = rows
        self.rowIDs = rowIDs
        self.start = start
        self.approx = approx
        self.path = path
        self.micros = micros
    }
}
