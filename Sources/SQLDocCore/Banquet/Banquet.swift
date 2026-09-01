import Foundation

/// Represents a parsed Banquet URL for tabular dataset navigation and querying.
/// Conforms to the Banquet URL Standard (https://github.com/darianmavgo/banquet).
public struct Banquet: Sendable, Equatable {
    /// Scheme if present (e.g. "file", "http", "https", "gs", "banquet").
    public var scheme: String?
    /// Host if present (e.g. "localhost", "bucket.appspot.com:8080").
    public var host: String?
    /// Port if present.
    public var port: String?
    /// Path to the source dataset (e.g. "data/sales.sqlite", "users.csv", "sample.db").
    public var dataSetPath: String
    /// Table name derived from path or explicit segment.
    public var table: String
    /// Selected columns. Defaults to ["*"].
    public var select: [String]
    /// Primary column to sort by.
    public var sortColumn: String?
    /// Sort direction: true for DESC, false for ASC.
    public var isSortDesc: Bool
    /// Combined SQL WHERE condition.
    public var whereClause: String?
    /// Maximum rows to return (from `limit` param or `[start:end]` slice).
    public var limit: Int?
    /// Row offset (from `offset` param or `[start:end]` slice).
    public var offset: Int?
    /// GROUP BY clause.
    public var groupBy: String?
    /// HAVING clause.
    public var having: String?
    /// Remaining query string if any.
    public var rawQuery: String
    /// The original raw URL string.
    public var rawURL: String

    public init(
        scheme: String? = nil,
        host: String? = nil,
        port: String? = nil,
        dataSetPath: String = "",
        table: String = "",
        select: [String] = ["*"],
        sortColumn: String? = nil,
        isSortDesc: Bool = false,
        whereClause: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        groupBy: String? = nil,
        having: String? = nil,
        rawQuery: String = "",
        rawURL: String = ""
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.dataSetPath = dataSetPath
        self.table = table
        self.select = select
        self.sortColumn = sortColumn
        self.isSortDesc = isSortDesc
        self.whereClause = whereClause
        self.limit = limit
        self.offset = offset
        self.groupBy = groupBy
        self.having = having
        self.rawQuery = rawQuery
        self.rawURL = rawURL
    }

    /// Sort direction string ("ASC" or "DESC") if sort is configured.
    public var sortDirection: String? {
        guard sortColumn != nil else { return nil }
        return isSortDesc ? "DESC" : "ASC"
    }

    /// Dataset file name (last component of dataSetPath).
    public var datasetName: String {
        guard !dataSetPath.isEmpty else { return "" }
        return (dataSetPath as NSString).lastPathComponent
    }

    /// Returns canonical breadcrumb segments for UI rendering and navigation.
    public func segments() -> [BanquetSegment] {
        var items: [BanquetSegment] = []

        // 1. Dataset Segment
        if !dataSetPath.isEmpty {
            let name = datasetName.isEmpty ? dataSetPath : datasetName
            items.append(BanquetSegment(
                kind: .dataset,
                text: name,
                tooltip: dataSetPath,
                iconName: "externaldrive.fill",
                targetBanquet: truncatedTo(segment: .dataset)
            ))
        }

        // 2. Table Segment
        if !table.isEmpty {
            items.append(BanquetSegment(
                kind: .table,
                text: table,
                tooltip: "Table: \(table)",
                iconName: "tablecells",
                targetBanquet: truncatedTo(segment: .table)
            ))
        }

        // 3. Selected Columns Segment (if not wildcard "*")
        if !select.isEmpty && select != ["*"] {
            let cols = select.joined(separator: ", ")
            items.append(BanquetSegment(
                kind: .columns,
                text: cols,
                tooltip: "Columns: \(cols)",
                iconName: "checklist",
                targetBanquet: truncatedTo(segment: .columns)
            ))
        }

        // 4. Filter / Where Segment
        if let whereClause, !whereClause.isEmpty {
            items.append(BanquetSegment(
                kind: .filter,
                text: whereClause,
                tooltip: "Filter: \(whereClause)",
                iconName: "line.3.horizontal.decrease.circle.fill",
                targetBanquet: truncatedTo(segment: .filter)
            ))
        }

        // 5. Sort Segment
        if let sortColumn, !sortColumn.isEmpty {
            let prefix = isSortDesc ? "▼ " : "▲ "
            items.append(BanquetSegment(
                kind: .sort,
                text: "\(prefix)\(sortColumn)",
                tooltip: "Sorted by \(sortColumn) \(isSortDesc ? "DESC" : "ASC")",
                iconName: "arrow.up.arrow.down",
                targetBanquet: truncatedTo(segment: .sort)
            ))
        }

        // 6. Slice / Window Segment
        if offset != nil || limit != nil {
            let start = offset ?? 0
            let sliceText: String
            if let limit {
                sliceText = "[\(start):\(start + limit)]"
            } else {
                sliceText = "[\(start):]"
            }
            items.append(BanquetSegment(
                kind: .slice,
                text: sliceText,
                tooltip: "Rows range \(sliceText)",
                iconName: "square.split.1x2",
                targetBanquet: self
            ))
        }

        return items
    }

    /// Truncates the query to a given segment level.
    public func truncatedTo(segment: BanquetSegmentKind) -> Banquet {
        var b = self
        switch segment {
        case .dataset:
            b.table = ""
            b.select = ["*"]
            b.sortColumn = nil
            b.whereClause = nil
            b.limit = nil
            b.offset = nil
            b.groupBy = nil
            b.having = nil
            b.rawQuery = ""
        case .table:
            b.select = ["*"]
            b.sortColumn = nil
            b.whereClause = nil
            b.limit = nil
            b.offset = nil
            b.groupBy = nil
            b.having = nil
            b.rawQuery = ""
        case .columns:
            b.sortColumn = nil
            b.whereClause = nil
            b.limit = nil
            b.offset = nil
            b.groupBy = nil
            b.having = nil
            b.rawQuery = ""
        case .filter:
            b.sortColumn = nil
            b.limit = nil
            b.offset = nil
        case .sort:
            b.limit = nil
            b.offset = nil
        case .slice:
            break
        }
        return b
    }
}

/// The kind of breadcrumb segment in a Banquet address bar.
public enum BanquetSegmentKind: String, Sendable, CaseIterable {
    case dataset
    case table
    case columns
    case filter
    case sort
    case slice
}

/// Represents an individual clickable segment in the Banquet Bar breadcrumb trail.
public struct BanquetSegment: Identifiable, Sendable, Equatable {
    public var id: String { "\(kind.rawValue):\(text)" }
    public let kind: BanquetSegmentKind
    public let text: String
    public let tooltip: String
    public let iconName: String
    public let targetBanquet: Banquet

    public init(kind: BanquetSegmentKind, text: String, tooltip: String, iconName: String, targetBanquet: Banquet) {
        self.kind = kind
        self.text = text
        self.tooltip = tooltip
        self.iconName = iconName
        self.targetBanquet = targetBanquet
    }
}
