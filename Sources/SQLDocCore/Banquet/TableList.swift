import Foundation

/// banquet-table-list-style.md: the sections shown when listing a database's tables.
/// One independent grid per table (never a single meta-grid), each showing the first
/// `rowsPerTable` rows, ordered Tiny (1–19 rows) → Large (20+) → Empty (0), each
/// category by row count descending.
public enum TableListCategory: Int, Sendable, Comparable {
    case tiny = 0, large = 1, empty = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// A table is tiny when it has under `tinyRowLimit` rows.
    public static func classify(rowCount: Int64) -> TableListCategory {
        if rowCount <= 0 { return .empty }
        return rowCount < Int64(TableListBuilder.tinyRowLimit) ? .tiny : .large
    }
}

public struct TableListSection: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let rowCount: Int64
    /// Row count as shown ("3,152", or "3,152~" while only an estimate is known).
    public let rowCountText: String
    public let category: TableListCategory
    public let columns: [String]
    /// Display-ready cells, at most `rowsPerTable` rows. An empty table has one `(Empty)` row.
    public let cells: [[String]]

    public init(name: String, rowCount: Int64, rowCountText: String, category: TableListCategory,
                columns: [String], cells: [[String]]) {
        self.name = name
        self.rowCount = rowCount
        self.rowCountText = rowCountText
        self.category = category
        self.columns = columns
        self.cells = cells
    }

    /// `=== Table: steps (3152 rows, 11 columns) ===`
    public var header: String {
        let rows = rowCountText + (rowCount == 1 && !rowCountText.hasSuffix("~") ? " row" : " rows")
        let cols = "\(columns.count) " + (columns.count == 1 ? "column" : "columns")
        return "=== Table: \(name) (\(rows), \(cols)) ==="
    }
}

public enum TableListBuilder {
    public static let tinyRowLimit = 20
    public static let rowsPerTable = 20
    public static let emptyPlaceholder = "(Empty)"

    /// Standard ordering: category, then row count descending (name breaks ties so the order is stable).
    public static func ordered(_ sections: [TableListSection]) -> [TableListSection] {
        sections.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            if $0.rowCount != $1.rowCount { return $0.rowCount > $1.rowCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The single placeholder row an empty table shows.
    public static func emptyRows(columnCount: Int) -> [[String]] {
        [[emptyPlaceholder] + Array(repeating: "", count: max(0, columnCount - 1))]
    }

    /// Builds every section for `doc`. Reads at most `rowsPerTable` rows per table, so cost
    /// does not grow with table size: a full first page means "large", and the count then
    /// comes from the O(1) estimate (`Doc.count`).
    public static func sections(for doc: Doc) -> [TableListSection] {
        var out: [TableListSection] = []
        for table in doc.tables where !table.hidden {
            guard let page = try? doc.rows(window: Window(table: table.name, limit: rowsPerTable)) else { continue }
            let columns = page.columns.map(\.name)
            var cells = page.text.map { $0.map(\.text) }
            let rowCount: Int64
            let countText: String
            if page.rows.count < rowsPerTable {
                rowCount = Int64(page.rows.count)       // the whole table fit: exact
                countText = SQLiteValueFormat.integerString(rowCount)
            } else {
                let c = doc.count(for: table.name)
                rowCount = c.known ? max(c.rows, Int64(rowsPerTable)) : Int64(rowsPerTable)
                countText = c.known ? c.displayString : "\(rowsPerTable)+"
            }
            let category = TableListCategory.classify(rowCount: rowCount)
            if category == .empty { cells = emptyRows(columnCount: columns.count) }
            out.append(TableListSection(name: table.name, rowCount: rowCount, rowCountText: countText,
                                        category: category, columns: columns, cells: cells))
        }
        return ordered(out)
    }
}
