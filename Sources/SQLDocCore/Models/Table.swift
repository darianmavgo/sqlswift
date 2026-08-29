import Foundation

/// Table is the lightweight, always-available description of one table or view.
public struct Table: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public var label: String
    public let type: String // "table", "view", or "virtual"
    public var hidden: Bool
    public let hasRowID: Bool

    public var isView: Bool {
        return type.lowercased() == "view"
    }

    public var isVirtual: Bool {
        return type.lowercased() == "virtual" || type.lowercased().contains("fts")
    }

    public init(name: String, label: String? = nil, type: String = "table", hidden: Bool = false, hasRowID: Bool = true) {
        self.name = name
        self.label = label ?? Table.humanize(name)
        self.type = type
        self.hidden = hidden || name.hasPrefix("_")
        self.hasRowID = hasRowID
    }

    /// Converts raw identifier names like "sensor_readings" or "tblUsers" into clean readable labels
    public static func humanize(_ name: String) -> String {
        // Strip common prefix/suffix noise
        var s = name
        if s.hasPrefix("tbl_") || s.hasPrefix("tbl") {
            s = String(s.dropFirst(s.hasPrefix("tbl_") ? 4 : 3))
        }
        
        let words = s.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        if words.isEmpty { return name }
        
        let capitalized = words.map { word -> String in
            let str = String(word)
            return str.prefix(1).uppercased() + str.dropFirst()
        }
        return capitalized.joined(separator: " ")
    }
}
