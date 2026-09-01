import Foundation

/// Canonicalizer and serializer for Banquet URLs and app states.
public enum BanquetSerializer {

    /// Serializes a `Banquet` object into a canonical Banquet URL string.
    public static func canonicalString(for banquet: Banquet) -> String {
        var base = ""

        if let scheme = banquet.scheme, !scheme.isEmpty {
            base += "\(scheme)://"
            if let host = banquet.host, !host.isEmpty {
                base += host
                if let port = banquet.port, !port.isEmpty {
                    base += ":\(port)"
                }
            }
            if !banquet.dataSetPath.isEmpty {
                if !base.hasSuffix("/") && !banquet.dataSetPath.hasPrefix("/") {
                    base += "/"
                }
                base += banquet.dataSetPath
            }
        } else {
            base = banquet.dataSetPath
        }

        // Table
        if !banquet.table.isEmpty {
            if !base.isEmpty && !base.hasSuffix("/") {
                base += "/"
            }
            base += banquet.table
        }

        // Column / Sort / Slice modifiers in path
        var pathModifiers: [String] = []

        // Sort modifier (+col or -col)
        if let sortCol = banquet.sortColumn, !sortCol.isEmpty {
            let prefix = banquet.isSortDesc ? "-" : "+"
            pathModifiers.append("\(prefix)\(sortCol)")
        }

        // Select columns (if specific and not wildcard)
        if !banquet.select.isEmpty && banquet.select != ["*"] {
            pathModifiers.append(banquet.select.joined(separator: ","))
        }

        if !pathModifiers.isEmpty {
            let combined = pathModifiers.joined(separator: ",")
            if !base.isEmpty && !base.hasSuffix("/") {
                base += "/"
            }
            base += combined
        }

        // Slice notation [offset:offset+limit]
        if let offset = banquet.offset, let limit = banquet.limit {
            base += "[\(offset):\(offset + limit)]"
        } else if let offset = banquet.offset {
            base += "[\(offset):]"
        } else if let limit = banquet.limit {
            base += "[0:\(limit)]"
        }

        // Query parameters (?where=...&groupby=...)
        var queryParams: [String] = []
        if let whereClause = banquet.whereClause, !whereClause.isEmpty {
            if let encoded = whereClause.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                queryParams.append("where=\(encoded)")
            } else {
                queryParams.append("where=\(whereClause)")
            }
        }

        if let groupBy = banquet.groupBy, !groupBy.isEmpty {
            queryParams.append("groupby=\(groupBy)")
        }

        if let having = banquet.having, !having.isEmpty {
            queryParams.append("having=\(having)")
        }

        if !queryParams.isEmpty {
            base += "?" + queryParams.joined(separator: "&")
        }

        return base
    }

    /// Composes a Banquet URL directly from viewer state.
    public static func serialize(
        datasetPath: String,
        tableName: String,
        select: [String]? = nil,
        sortColumn: String? = nil,
        isSortDesc: Bool = false,
        filters: [ColumnFilter]? = nil,
        offset: Int64? = nil,
        limit: Int? = nil
    ) -> String {
        // Compile where clause from filters if present
        let whereClause: String?
        if let filters, !filters.isEmpty {
            let clauses = filters.compactMap { filter -> String? in
                let val = filter.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let col = filter.column
                switch filter.op {
                case .equals:
                    return "\(col) = '\(val.replacingOccurrences(of: "'", with: "''"))'"
                case .notEquals:
                    return "\(col) != '\(val.replacingOccurrences(of: "'", with: "''"))'"
                case .contains:
                    return "\(col) LIKE '%\(val)%'"
                case .startsWith:
                    return "\(col) LIKE '\(val)%'"
                case .greater:
                    return "\(col) > \(val)"
                case .less:
                    return "\(col) < \(val)"
                case .isNull:
                    return "\(col) IS NULL"
                case .isNotNull:
                    return "\(col) IS NOT NULL"
                }
            }
            whereClause = clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
        } else {
            whereClause = nil
        }

        let banquet = Banquet(
            dataSetPath: datasetPath,
            table: tableName,
            select: select ?? ["*"],
            sortColumn: sortColumn,
            isSortDesc: isSortDesc,
            whereClause: whereClause,
            limit: limit,
            offset: offset.map { Int($0) }
        )

        return canonicalString(for: banquet)
    }
}
