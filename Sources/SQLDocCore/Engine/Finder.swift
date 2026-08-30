import Foundation
import SQLite3

public final class Finder: @unchecked Sendable {
    public init() {}
}

extension Doc {
    public static let findChunk: Int64 = 250_000

    /// Searches a table for a substring, case-insensitively, resuming from a rowid
    /// cursor. Pass `column` to restrict the scan (and the highlight) to one column.
    public func find(table tableName: String, query q: String, from fromRowID: Int64 = 0, limit: Int = 50, column: String? = nil, caseSensitive: Bool = false) throws -> FindResult {
        let startTime = DispatchTime.now()

        guard let t = table(named: tableName), !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FindResult(matches: [], next: 0, done: true, scanned: 0, progress: 1.0, micros: 0)
        }

        let ts = tableState(for: tableName)
        let (allCols, _) = try ts.getColumns {
            try columns(for: tableName)
        }
        // Column-scoped search narrows both the SQL and the reported match column.
        let cols: [Column]
        if let column, let idx = allCols.firstIndex(where: { $0.name == column }) {
            cols = [allCols[idx]]
        } else {
            cols = allCols
        }
        let colExpr = cols.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")
        let columnOffset = (column != nil) ? (allCols.firstIndex(where: { $0.name == column }) ?? 0) : 0

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
                searchNeedle: q,
                columnOffset: columnOffset,
                caseSensitive: caseSensitive
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

        let (lo, hi, ok) = bounds(for: tableName, using: bg)
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
            searchNeedle: q,
            columnOffset: columnOffset,
            caseSensitive: caseSensitive
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
        searchNeedle: String,
        columnOffset: Int,
        caseSensitive: Bool
    ) throws -> [FindMatch] {
        var query = "SELECT rowid, \(colExpr) FROM \(ts.quoted) WHERE \(whereClause)("
        var args = baseArgs
        let pattern = "%\(escapeLike(searchNeedle))%"

        for (i, c) in cols.enumerated() {
            if i > 0 { query += " OR " }
            if caseSensitive {
                // instr() is a binary, case-sensitive substring test.
                query += "instr(CAST(\(Doc.quoteIdent(c.name)) AS TEXT), ?) > 0"
                args.append(searchNeedle)
            } else {
                query += "CAST(\(Doc.quoteIdent(c.name)) AS TEXT) LIKE ? ESCAPE '\\'"
                args.append(pattern)
            }
        }
        query += ") ORDER BY rowid LIMIT ?"
        args.append(limit)

        let rawRows = try bg.query(query, args: args)
        var matches: [FindMatch] = []
        let needleCmp = caseSensitive ? searchNeedle : searchNeedle.lowercased()

        for row in rawRows {
            guard let first = row.first, let rowID = first.intValue else { continue }
            var matchedCol = -1

            for (colIdx, cellVal) in row.dropFirst().enumerated() {
                let text = caseSensitive ? cellVal.textValue : cellVal.textValue?.lowercased()
                if let text, text.contains(needleCmp) {
                    matchedCol = columnOffset + colIdx
                    break
                }
            }

            matches.append(FindMatch(rowID: rowID, column: matchedCol))
        }

        return matches
    }

    private func escapeLike(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
    }
}
