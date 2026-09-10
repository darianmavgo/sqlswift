import Foundation

/// BanquetComposer builds a SQL query string from a Banquet struct.
/// This implementation uses double-quoting for identifiers to prevent basic SQL injection
/// and handle reserved words/spaces in names.
public enum BanquetComposer {
    
    /// Builds a SQL query string from a Banquet struct.
    public static func compose(_ bq: Banquet) -> String {
        var parts: [String] = []
        
        // SELECT
        var selectClause = "*"
        if !bq.select.isEmpty && bq.select[0] != "*" {
            let quotedCols = bq.select.map { quoteIdentifier($0) }
            selectClause = quotedCols.joined(separator: ", ")
        }
        parts.append("SELECT " + selectClause)
        
        // FROM
        var table = bq.table
        if table.isEmpty {
            table = inferTable(bq)
        }
        parts.append("FROM " + quoteIdentifier(table))
        
        // WHERE
        if let w = bq.whereClause, !w.isEmpty {
            parts.append("WHERE " + w)
        }
        
        // GROUP BY
        if let g = bq.groupBy, !g.isEmpty {
            parts.append("GROUP BY " + quoteIdentifier(g))
        }
        
        // HAVING
        if let h = bq.having, !h.isEmpty {
            parts.append("HAVING " + h)
        }
        
        // ORDER BY
        if let ob = bq.sortColumn, !ob.isEmpty {
            var orderBy = quoteIdentifier(ob)
            if let dir = bq.sortDirection {
                orderBy += " " + dir
            }
            parts.append("ORDER BY " + orderBy)
        }
        
        // LIMIT
        if let limit = bq.limit {
            parts.append("LIMIT \(limit)")
        }
        
        // OFFSET
        if let offset = bq.offset {
            parts.append("OFFSET \(offset)")
        }
        
        return parts.joined(separator: " ")
    }
    
    /// QuoteIdentifier wraps a string in double quotes and escapes existing double quotes.
    public static func quoteIdentifier(_ s: String) -> String {
        if s.isEmpty || s == "*" {
            return s
        }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
    
    /// InferTable attempts to deduce the table name when one is not explicitly provided.
    /// It checks the DataSetPath extension and whether columns were requested.
    public static func inferTable(_ bq: Banquet) -> String {
        if !bq.table.isEmpty {
            return bq.table
        }
        
        let lower = bq.dataSetPath.lowercased()
        if lower.hasSuffix(".sqlite") || lower.hasSuffix(".db") {
            return "sqlite_master"
        }
        
        // Default fallback for flat files or if columns are specified but table is implicit
        return "tb0"
    }
}
