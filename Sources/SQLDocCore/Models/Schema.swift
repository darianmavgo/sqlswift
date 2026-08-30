import Foundation

/// A foreign-key relationship declared on a table (one row of `PRAGMA foreign_key_list`).
public struct ForeignKey: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { "\(fromColumn)->\(table).\(toColumn)" }
    public let fromColumn: String
    public let table: String
    public let toColumn: String
    public let onUpdate: String
    public let onDelete: String

    public init(fromColumn: String, table: String, toColumn: String, onUpdate: String = "", onDelete: String = "") {
        self.fromColumn = fromColumn
        self.table = table
        self.toColumn = toColumn
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

/// An index on a table (from `PRAGMA index_list` + `PRAGMA index_info`).
public struct TableIndex: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let unique: Bool
    /// "c" = created by CREATE INDEX, "u" = UNIQUE constraint, "pk" = PRIMARY KEY.
    public let origin: String
    public let partial: Bool
    public let columns: [String]

    public init(name: String, unique: Bool, origin: String, partial: Bool, columns: [String]) {
        self.name = name
        self.unique = unique
        self.origin = origin
        self.partial = partial
        self.columns = columns
    }
}

/// Everything the schema inspector shows for one table or view.
public struct TableSchema: Equatable, Sendable {
    public let name: String
    public let type: String            // "table" | "view"
    public let ddl: String             // the CREATE statement from sqlite_master
    public let columns: [Column]
    public let foreignKeys: [ForeignKey]
    public let indexes: [TableIndex]
    public let rowidAlias: String?     // the INTEGER PRIMARY KEY column, if any

    public init(name: String, type: String, ddl: String, columns: [Column],
                foreignKeys: [ForeignKey] = [], indexes: [TableIndex] = [], rowidAlias: String? = nil) {
        self.name = name
        self.type = type
        self.ddl = ddl
        self.columns = columns
        self.foreignKeys = foreignKeys
        self.indexes = indexes
        self.rowidAlias = rowidAlias
    }
}

/// The result of running an ad-hoc read-only query in the console.
public struct QueryResult: Sendable {
    public let columns: [String]
    public let rows: [[SQLiteValue]]
    public let text: [[CellText]]
    public let truncated: Bool         // more rows existed than the row cap
    public let micros: Int64
    public let sql: String

    public init(columns: [String], rows: [[SQLiteValue]], truncated: Bool, micros: Int64, sql: String) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
        self.micros = micros
        self.sql = sql
        self.text = rows.map { row in
            row.map { v in
                let c = v.gridCell(maxChars: Page.cellTextMaxChars)
                return CellText(text: c.text, truncated: c.truncated)
            }
        }
    }
}
