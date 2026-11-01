import Foundation

/// Column describes one column of a SQLite table.
public struct Column: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let notNull: Bool
    public let pk: Bool
    /// 1-based position within the table's PRIMARY KEY (from `PRAGMA table_info`), or 0 if not part of the PK.
    public let pkIndex: Int
    public let isNumeric: Bool

    public init(name: String, type: String, notNull: Bool = false, pk: Bool = false, pkIndex: Int? = nil) {
        self.name = name
        self.type = type
        self.notNull = notNull
        self.pk = pk
        self.pkIndex = pkIndex ?? (pk ? 1 : 0)
        
        let upper = type.uppercased()
        self.isNumeric = upper.contains("INT") ||
                         upper.contains("FLOAT") ||
                         upper.contains("DOUBLE") ||
                         upper.contains("REAL") ||
                         upper.contains("NUMERIC") ||
                         upper.contains("DECIMAL") ||
                         upper.contains("BOOLEAN")
    }
}
