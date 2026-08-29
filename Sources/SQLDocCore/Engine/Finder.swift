import Foundation
import SQLite3

public final class Finder: @unchecked Sendable {
    public init() {}
}

extension Doc {
    public static let findChunk: Int64 = 250_000

    /// Searches every column of a table for a substring, case-insensitively, resuming from a rowid cursor.
    public func find(table tableName: String, query q: String, from fromRowID: Int64 = 0, limit: Int = 50) throws -> FindResult {
        let startTime = DispatchTime.now()

        guard let t = table(named: tableName), !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FindResult(matches: [], next: 0, done: true, scanned: 0, progress: 1.0, micros: 0)
        }

        let ts = tableState(for: tableName)
        let (cols, colExpr) = try ts.getColumns {
            try columns(for: tableName)
        }

        let cleanLimit = min(max(1, limit), 200)

        if !t.hasRowID {
            // No rowid axis to walk; run single bounded pass
            let matches = try scanFind(
                ts: ts,
                cols: cols,
                colExpr: colExpr,
                whereClause: "",
                limit: cleanLimit,
                baseArgs: [],
                searchNeedle: q
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
            return FindResult(
                matches: matches,
                next: 0,
                done: true,
                scanned: Int64(matches.count),
                progress: 1.0,
                micros: Int64(elapsed / 1000)
            )
        }

        let (lo, hi, ok) = bounds(for: tableName)
        guard ok, hi >= lo else {
            return FindResult(matches: [], next: 0, done: true, scanned: 0, progress: 1.0, micros: 0)
        }

        var startCursor = fromRowID
        if startCursor < lo - 1 {
            startCursor = lo - 1
        }

        var upper = startCursor + Doc.findChunk
        var isDone = false
        if upper >= hi {
            upper = hi
            isDone = true
        }

        let whereClause = "rowid > ? AND rowid <= ? AND "
        let baseArgs: [Any] = [startCursor, upper]

        let matches = try scanFind(
            ts: ts,
            cols: cols,
            colExpr: colExpr,
            whereClause: whereClause,
            limit: cleanLimit,
            baseArgs: baseArgs,
            searchNeedle: q
        )

        let span = hi - lo + 1
        var progress: Double = 1.0
        if span > 0 {
            progress = min(1.0, max(0.0, Double(upper - lo + 1) / Double(span)))
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let micros = Int64(elapsed / 1000)

        return FindResult(
            matches: matches,
            next: upper,
            done: isDone,
            scanned: upper - startCursor,
            progress: progress,
            micros: micros
        )
    }

    private func scanFind(
        ts: TableState,
        cols: [Column],
        colExpr: String,
        whereClause: String,
        limit: Int,
        baseArgs: [Any],
        searchNeedle: String
    ) throws -> [FindMatch] {
        var query = "SELECT rowid, \(colExpr) FROM \(ts.quoted) WHERE \(whereClause)("
        var args = baseArgs
        let pattern = "%\(escapeLike(searchNeedle))%"

        for (i, c) in cols.enumerated() {
            if i > 0 { query += " OR " }
            query += "CAST(\(Doc.quoteIdent(c.name)) AS TEXT) LIKE ? ESCAPE '\\'"
            args.append(pattern)
        }
        query += ") ORDER BY rowid LIMIT ?"
        args.append(limit)

        let rawRows = try bg.query(query, args: args)
        var matches: [FindMatch] = []
        let lowerNeedle = searchNeedle.lowercased()

        for row in rawRows {
            guard let first = row.first, let rowID = first.intValue else { continue }
            let cells = Array(row.dropFirst())
            var matchedCol = -1

            for (colIdx, cellVal) in cells.enumerated() {
                if let text = cellVal.textValue?.lowercased(), text.contains(lowerNeedle) {
                    matchedCol = colIdx
                    break
                }
            }

            matches.append(FindMatch(rowID: rowID, column: matchedCol, row: cells))
        }

        return matches
    }

    private func escapeLike(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
    }
}
