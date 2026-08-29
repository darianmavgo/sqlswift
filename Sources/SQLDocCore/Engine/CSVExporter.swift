import Foundation
import SQLite3

extension Doc {
    /// Streams a table out to CSV format.
    public func exportCSV(for tableName: String) throws -> String {
        guard let _ = table(named: tableName) else {
            throw SQLiteError.tableNotFound(tableName)
        }
        let cols = try columns(for: tableName)
        let colExpr = cols.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")

        var csv = ""
        // Header
        let header = cols.map { col -> String in
            let name = col.name
            if name.contains(",") || name.contains("\"") || name.contains("\n") {
                return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return name
        }.joined(separator: ",")
        csv.append(header)
        csv.append("\n")

        // Rows
        let query = "SELECT \(colExpr) FROM \(Doc.quoteIdent(tableName))"
        try fg.queryStreaming(query) { _, row in
            let line = row.map { $0.csvText }.joined(separator: ",")
            csv.append(line)
            csv.append("\n")
            return true
        }

        return csv
    }
}
