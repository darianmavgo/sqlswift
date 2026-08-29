import Foundation

/// Column describes one column of a SQLite table.
public struct Column: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let notNull: Bool
    public let pk: Bool
    public let isNumeric: Bool

    public init(name: String, type: String, notNull: Bool = false, pk: Bool = false) {
        self.name = name
        self.type = type
        self.notNull = notNull
        self.pk = pk
        
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
