import Foundation

/// A column of the folder catalog that can be sorted (banquet-db-list-style: the `databases`
/// catalog's `name`, `location`, `table_count`, `size_bytes`, `modified`). `.scan` is the
/// scanner's own order, which has no clause in the URL.
public enum FolderSortKey: String, CaseIterable, Sendable {
    case scan, name, location, tableCount = "table_count", size = "size_bytes", modified

    public var label: String {
        switch self {
        case .scan: return "Scan order"
        case .name: return "Name"
        case .location: return "Folder"
        case .tableCount: return "Tables"
        case .size: return "Size"
        case .modified: return "Modified"
        }
    }

    /// Numbers and dates read best biggest/newest first; text reads A to Z.
    public var defaultDescending: Bool {
        switch self {
        case .tableCount, .size, .modified: return true
        case .scan, .name, .location: return false
        }
    }

    /// Reads the column name of a Banquet sort clause. Loose on purpose: the same
    /// aliases the bar has always accepted (`size`, `mod…`, `date`, `time`, `name`).
    public init?(column: String) {
        let c = column.lowercased()
        if c.contains("table") { self = .tableCount }
        else if c.contains("size") { self = .size }
        else if c.contains("mod") || c.contains("date") || c.contains("time") { self = .modified }
        else if c.contains("name") { self = .name }
        else if c.contains("loc") || c.contains("folder") || c == "key" { self = .location }
        else { return nil }
    }
}

/// How the folder catalog is ordered: one column and a direction. This is the whole sort
/// state; the Banquet URL clause and the list's header arrows are both derived from it.
public struct FolderSort: Equatable, Sendable {
    public var key: FolderSortKey
    public var descending: Bool

    public static let scanOrder = FolderSort(key: .scan, descending: false)

    public init(key: FolderSortKey, descending: Bool? = nil) {
        self.key = key
        self.descending = descending ?? key.defaultDescending
    }

    /// The clause appended to the container URL (`-size_bytes`), or "" for scan order.
    public var urlClause: String {
        key == .scan ? "" : (descending ? "-" : "+") + key.rawValue
    }

    /// Click on a column header: the same column flips direction, another starts at its default.
    public func toggled(to newKey: FolderSortKey) -> FolderSort {
        key == newKey ? FolderSort(key: key, descending: !descending) : FolderSort(key: newKey)
    }

    public func sorted(_ files: [SQLiteFileEntry]) -> [SQLiteFileEntry] {
        guard key != .scan else { return files }
        func cmp(_ a: SQLiteFileEntry, _ b: SQLiteFileEntry) -> ComparisonResult {
            switch key {
            case .scan: return .orderedSame
            case .name: return a.name.localizedStandardCompare(b.name)
            case .location: return a.relativeFolder.localizedStandardCompare(b.relativeFolder)
            case .tableCount: return a.tables.count < b.tables.count ? .orderedAscending : (a.tables.count > b.tables.count ? .orderedDescending : .orderedSame)
            case .size: return a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
            case .modified: return a.modified < b.modified ? .orderedAscending : (a.modified > b.modified ? .orderedDescending : .orderedSame)
            }
        }
        // Ties fall back to name then path, A to Z whichever way the column runs, so equal rows
        // never shuffle between redraws and a "largest first" list still reads alphabetically within a size.
        return files.sorted { a, b in
            let r = cmp(a, b)
            if r != .orderedSame { return descending ? r == .orderedDescending : r == .orderedAscending }
            let n = a.name.localizedStandardCompare(b.name)
            if n != .orderedSame { return n == .orderedAscending }
            return a.path < b.path
        }
    }
}
