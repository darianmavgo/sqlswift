import Foundation
import SQLite3

extension Doc {
    public static let maxLimit = 1000

    /// Fetches one rendered window of a table according to the window specification.
    public func rows(window: Window) throws -> Page {
        let startTime = DispatchTime.now()
        touch()
        defer { touch() }

        guard let t = table(named: window.table) else {
            throw SQLiteError.tableNotFound(window.table)
        }
        let ts = tableState(for: window.table)
        let (cols, colExpr) = try ts.getColumns {
            try columns(for: window.table)
        }

        let limit = min(max(1, window.limit), Doc.maxLimit)
        let offset = max(0, window.offset)

        var query = ""
        var args: [Any] = []
        var path = "offset"
        let startOffset = offset
        var isApprox = false
        var withRowID = false

        // Build the filter WHERE fragment once; several paths splice it in.
        var filterClause = ""
        var filterArgs: [Any] = []
        if !window.filters.isEmpty {
            let parts = window.filters.compactMap { f -> String? in
                guard cols.contains(where: { $0.name == f.column }) else { return nil }
                let (clause, a) = f.sql(quotedColumn: Doc.quoteIdent(f.column))
                filterArgs.append(contentsOf: a)
                return "(\(clause))"
            }
            if !parts.isEmpty { filterClause = parts.joined(separator: " AND ") }
        }

        if window.powerSample {
            // Rows at ordinals 1, 2, 4, 8, 16, … — one pass, any table shape.
            var ordinals: [Int64] = []
            var k: Int64 = 1
            while ordinals.count < limit && k <= 1 << 40 { ordinals.append(k); k <<= 1 }
            let inList = ordinals.map(String.init).joined(separator: ",")
            let sel = t.hasRowID ? "rowid, \(colExpr)" : colExpr
            let whereFilter = filterClause.isEmpty ? "" : "WHERE \(filterClause) "
            query = """
                SELECT \(sel) FROM (
                  SELECT \(sel), ROW_NUMBER() OVER (ORDER BY \(t.hasRowID ? "rowid" : "1")) AS __rn
                  FROM \(ts.quoted) \(whereFilter)
                ) WHERE __rn IN (\(inList)) ORDER BY __rn
                """
            args = filterArgs
            path = "power2"
            withRowID = t.hasRowID
        } else if !filterClause.isEmpty {
            // Filtered browsing: offset paging over the filtered set (optionally sorted).
            let sel = t.hasRowID ? "rowid, \(colExpr)" : colExpr
            var order = "ORDER BY \(t.hasRowID ? "rowid" : "1")"
            if let sc = window.sort, !sc.isEmpty {
                let se = window.sortNumeric ? "CAST(\(Doc.quoteIdent(sc)) AS REAL)" : Doc.quoteIdent(sc)
                order = "ORDER BY \(se) \(window.desc ? "DESC" : "ASC")\(t.hasRowID ? ", rowid ASC" : "")"
            }
            query = "SELECT \(sel) FROM \(ts.quoted) WHERE \(filterClause) \(order) LIMIT ? OFFSET ?"
            args = filterArgs + [limit, offset]
            path = "filtered"
            withRowID = t.hasRowID
        } else if let sortCol = window.sort, !sortCol.isEmpty {
            let q = Doc.quoteIdent(sortCol)
            // Sort as a number when the caller asked and the storage class allows it.
            let sortExpr = window.sortNumeric ? "CAST(\(q) AS REAL)" : q
            let dir = window.desc ? "DESC" : "ASC"
            // rowid always ascending: a deterministic total order so equal keys
            // never reshuffle between pages.
            if t.hasRowID {
                let keysetAnchor = window.afterSortValue.flatMap { $0.isNull ? nil : $0 }
                if window.useAfter, let anchor = keysetAnchor {
                    let cmp = window.desc ? "<" : ">"
                    let anchorBind: Any = window.sortNumeric
                        ? (anchor.doubleValue ?? Double(anchor.textValue ?? "") ?? 0)
                        : anchor.bindable
                    query = """
                        SELECT rowid, \(colExpr) FROM \(ts.quoted) \
                        WHERE \(sortExpr) \(cmp) ? OR (\(sortExpr) = ? AND rowid > ?) \
                        ORDER BY \(sortExpr) \(dir), rowid ASC LIMIT ?
                        """
                    args = [anchorBind, anchorBind, window.after, limit]
                    path = "sorted-keyset"
                } else {
                    query = "SELECT rowid, \(colExpr) FROM \(ts.quoted) ORDER BY \(sortExpr) \(dir), rowid ASC LIMIT ? OFFSET ?"
                    args = [limit, offset]
                    path = "sorted-offset"
                }
                withRowID = true
            } else {
                query = "SELECT \(colExpr) FROM \(ts.quoted) ORDER BY \(sortExpr) \(dir) LIMIT ? OFFSET ?"
                args = [limit, offset]
                path = "sorted-offset"
            }
        } else if window.forceOffset {
            query = "SELECT \(colExpr) FROM \(ts.quoted) LIMIT ? OFFSET ?"
            args = [limit, offset]
            path = "offset"
        } else if t.hasRowID && window.useAfter {
            // Sequential scrolling: exact and O(log n) index seek
            query = "SELECT rowid, \(colExpr) FROM \(ts.quoted) WHERE rowid > ? ORDER BY rowid LIMIT ?"
            args = [window.after, limit]
            path = "keyset"
            withRowID = true
        } else if t.hasRowID {
            // Scrollbar jump: interpolate ordinal onto rowid axis
            let (rid, exact) = rowidForOffset(table: window.table, offset: offset)
            query = "SELECT rowid, \(colExpr) FROM \(ts.quoted) WHERE rowid >= ? ORDER BY rowid LIMIT ?"
            args = [rid, limit]
            path = "interpolated"
            isApprox = !exact
            withRowID = true
        } else {
            // Views and WITHOUT ROWID tables
            query = "SELECT \(colExpr) FROM \(ts.quoted) LIMIT ? OFFSET ?"
            args = [limit, offset]
            path = "offset"
        }

        let rawRows = try fg.query(query, args: args)
        var rowValues: [[SQLiteValue]] = []
        var rowIDs: [Int64] = []
        rowValues.reserveCapacity(rawRows.count)

        if withRowID {
            rowIDs.reserveCapacity(rawRows.count)
            for r in rawRows {
                if let first = r.first, let rid = first.intValue {
                    rowIDs.append(rid)
                } else {
                    rowIDs.append(0)
                }
                rowValues.append(Array(r.dropFirst()))
            }
        } else {
            rowValues = rawRows
        }

        // Build display-ready, length-clamped strings here (off the main thread),
        // so the grid never lays out a huge value or reruns a NumberFormatter.
        let cellText: [[CellText]] = rowValues.map { row in
            row.map { v in
                let c = v.gridCell(maxChars: Page.cellTextMaxChars)
                return CellText(text: c.text, truncated: c.truncated)
            }
        }

        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let micros = Int64(elapsedNanos / 1000)

        return Page(
            table: window.table,
            columns: cols,
            rows: rowValues,
            text: cellText,
            rowIDs: rowIDs,
            start: startOffset,
            approx: isApprox,
            path: path,
            micros: micros
        )
    }

    /// Translates an ordinal offset into an approximate or exact rowid.
    public func rowidForOffset(table: String, offset: Int64) -> (rowID: Int64, exact: Bool) {
        let (lo, hi, ok) = bounds(for: table)
        guard ok, hi >= lo else { return (0, true) }
        if offset <= 0 { return (lo, true) }

        let tableCount = count(for: table)
        let total = tableCount.known ? tableCount.rows : (hi - lo + 1)
        if total <= 1 { return (lo, true) }

        let span = hi - lo
        let rowID = lo + Int64(Double(offset) * Double(span) / Double(total - 1))
        let clamped = max(lo, min(hi, rowID))
        let exact = tableCount.known && tableCount.exact && (span + 1 == total)
        return (clamped, exact)
    }
}
