import Foundation
import SQLite3

extension Doc {
    /// Largest window one request may return. A Banquet URL with no slice means "all rows"
    /// (up to `window.all_rows_cap`), so the clamp must not sit below that.
    public static let maxLimit = max(BehaviorConfig.windowMaxRows, BehaviorConfig.windowAllRowsCap)

    /// Fetches one rendered window of a table according to the window specification.
    public func rows(window: Window, control: QueryControl? = nil) throws -> Page {
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
        var reverseRows = false

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
        } else if t.hasRowID, !window.forceOffset,
                  let seek = Doc.seekQuery(
                      window: window, quotedTable: ts.quoted, colExpr: colExpr,
                      filterClause: filterClause, filterArgs: filterArgs, limit: limit) {
            // Anchored on a row we already hold: O(log n) however deep the page,
            // with or without filters and sort, forward or back.
            query = seek.sql
            args = seek.args
            path = seek.path
            withRowID = true
            reverseRows = window.backward || window.fromEnd
        } else if !filterClause.isEmpty {
            // Filtered jump to an arbitrary ordinal: no row to anchor on, so count
            // past `OFFSET` rows of the filtered set (optionally sorted).
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
                // No usable anchor (a jump, or a clipped sort value): count rows.
                query = "SELECT rowid, \(colExpr) FROM \(ts.quoted) ORDER BY \(sortExpr) \(dir), rowid ASC LIMIT ? OFFSET ?"
                args = [limit, offset]
                path = "sorted-offset"
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
        } else if t.hasRowID {
            // Scrollbar jump: interpolate ordinal onto rowid axis
            let (rid, exact) = rowidForOffset(table: window.table, offset: offset)
            query = "SELECT rowid, \(colExpr) FROM \(ts.quoted) WHERE rowid >= ? ORDER BY rowid LIMIT ?"
            args = [rid, limit]
            path = "interpolated"
            isApprox = !exact
            withRowID = true
        } else {
            // WITHOUT ROWID tables and views: use composite primary-key keyset seeking when available.
            let pkCols = cols.filter { $0.pkIndex > 0 }.sorted { $0.pkIndex < $1.pkIndex }
            if !pkCols.isEmpty {
                let orderList = pkCols.map { "\(Doc.quoteIdent($0.name)) ASC" }.joined(separator: ", ")
                if window.useAfter && window.afterPKValues.count == pkCols.count && !window.afterPKValues.contains(where: { $0.isNull }) {
                    if pkCols.count == 1 {
                        let k0 = Doc.quoteIdent(pkCols[0].name)
                        query = "SELECT \(colExpr) FROM \(ts.quoted) WHERE \(k0) > ? ORDER BY \(orderList) LIMIT ?"
                    } else {
                        let tupleCols = pkCols.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")
                        let placeholders = Array(repeating: "?", count: pkCols.count).joined(separator: ", ")
                        query = "SELECT \(colExpr) FROM \(ts.quoted) WHERE (\(tupleCols)) > (\(placeholders)) ORDER BY \(orderList) LIMIT ?"
                    }
                    args = window.afterPKValues.map { $0.bindable } + [limit]
                    path = "pk-keyset"
                } else if offset == 0 {
                    query = "SELECT \(colExpr) FROM \(ts.quoted) ORDER BY \(orderList) LIMIT ?"
                    args = [limit]
                    path = "pk-keyset"
                } else {
                    query = "SELECT \(colExpr) FROM \(ts.quoted) ORDER BY \(orderList) LIMIT ? OFFSET ?"
                    args = [limit, offset]
                    path = "offset"
                }
            } else {
                // Views without declared PKs
                query = "SELECT \(colExpr) FROM \(ts.quoted) LIMIT ? OFFSET ?"
                args = [limit, offset]
                path = "offset"
            }
        }

        var rawRows = try pages.query(query, args: args, control: (control ?? QueryControl()).forPage(rowKeyed: withRowID))
        if reverseRows {
            // A backward seek that comes up short has run into the start of the
            // set, so the page the caller wants is simply the first one.
            if window.backward && rawRows.count < limit {
                var first = window
                first.backward = false
                first.useAfter = false
                first.afterSortValue = nil
                first.offset = 0
                return try rows(window: first, control: control)
            }
            rawRows.reverse()
        }
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

        var page = Page(
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
        page.rowKeyed = withRowID
        return page
    }

    /// SQL for a rowid-anchored seek, or nil when the window names no anchor this
    /// can use (then the caller falls back to an offset path).
    ///
    /// Row order is `(sort expr, rowid ASC)`, or plain `rowid` when unsorted.
    /// Reading backward or from the end walks that order in reverse and the
    /// caller flips the rows. NULL sort values need their own arms: they sort
    /// lowest, and no comparison against a bound value ever matches them.
    static func seekQuery(
        window: Window, quotedTable: String, colExpr: String,
        filterClause: String, filterArgs: [Any], limit: Int
    ) -> (sql: String, args: [Any], path: String)? {
        guard window.useAfter || window.backward || window.fromEnd else { return nil }
        let reversed = window.backward || window.fromEnd
        let ridCmp = reversed ? "<" : ">"
        let sortCol = window.sort.flatMap { $0.isEmpty ? nil : $0 }

        var conds: [String] = []
        var args: [Any] = []
        if !filterClause.isEmpty {
            conds.append("(\(filterClause))")
            args += filterArgs
        }

        let order: String
        if let sortCol {
            let q = Doc.quoteIdent(sortCol)
            let se = window.sortNumeric ? "CAST(\(q) AS REAL)" : q
            // The direction this query walks the sort values in.
            let walkDesc = window.desc != reversed
            order = "\(se) \(walkDesc ? "DESC" : "ASC"), rowid \(reversed ? "DESC" : "ASC")"
            if !window.fromEnd {
                guard let anchor = window.afterSortValue, !anchor.isPartial else { return nil }
                if anchor.isNull {
                    // Walking up, every non-NULL row is still ahead; walking down, none is.
                    conds.append(walkDesc
                        ? "(\(se) IS NULL AND rowid \(ridCmp) ?)"
                        : "((\(se) IS NULL AND rowid \(ridCmp) ?) OR \(se) IS NOT NULL)")
                    args.append(window.after)
                } else {
                    let bind: Any = window.sortNumeric
                        ? (anchor.doubleValue ?? Double(anchor.textValue ?? "") ?? 0)
                        : anchor.bindable
                    let cmp = walkDesc ? "<" : ">"
                    // Walking down, the NULL run lies ahead of every value.
                    let nullTail = walkDesc ? " OR \(se) IS NULL" : ""
                    conds.append("(\(se) \(cmp) ? OR (\(se) = ? AND rowid \(ridCmp) ?)\(nullTail))")
                    args += [bind, bind, window.after]
                }
            }
        } else {
            order = "rowid \(reversed ? "DESC" : "ASC")"
            if !window.fromEnd {
                conds.append("rowid \(ridCmp) ?")
                args.append(window.after)
            }
        }

        let whereSQL = conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")
        args.append(limit)
        let path = !filterClause.isEmpty ? "filtered-keyset" : (sortCol != nil ? "sorted-keyset" : "keyset")
        return ("SELECT rowid, \(colExpr) FROM \(quotedTable)\(whereSQL) ORDER BY \(order) LIMIT ?", args, path)
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
