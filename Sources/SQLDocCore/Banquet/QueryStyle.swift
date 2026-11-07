import Foundation

/// Display mode for browsing a table:
/// - `raw`: literal physical column order, every column shown
/// - `trim`: Banquet Query Style column ordering (PK → label → status/date/headline → details) and noise removal
/// - `summary`: automatic `GROUP BY` rollup over low-cardinality dimensions with smart `SUM`/`AVG` aggregations
public enum DisplayKind: String, CaseIterable, Sendable, Equatable {
    case raw = "raw"
    case trim = "trim"
    case summary = "summary"

    public var label: String {
        switch self {
        case .raw: return "Raw"
        case .trim: return "Trim"
        case .summary: return "Summary"
        }
    }
}

/// Per-column statistics gathered from a fast bounded sample (`LIMIT 2000`) of a table.
public struct ColumnProbeStats: Sendable, Equatable {
    public let nonNull: Bool
    public let fill: Int
    public let distinct: Int
    public let minVal: Double?
    public let maxVal: Double?

    public init(nonNull: Bool, fill: Int, distinct: Int, minVal: Double? = nil, maxVal: Double? = nil) {
        self.nonNull = nonNull
        self.fill = fill
        self.distinct = distinct
        self.minVal = minVal
        self.maxVal = maxVal
    }
}

/// Sampled profile of a table used by `QueryStyle` to order/trim columns and build summary rollups.
public struct TableProbe: Sendable, Equatable {
    public var sampleN: Int
    public var byName: [String: ColumnProbeStats]
    public var duplicates: Set<String>

    public init(sampleN: Int = 0, byName: [String: ColumnProbeStats] = [:], duplicates: Set<String> = []) {
        self.sampleN = sampleN
        self.byName = byName
        self.duplicates = duplicates
    }
}

/// Implements Banquet Query Style ("Trim View" and "Summary View") column ordering,
/// noise hiding, and automatic rollup generation.
public struct QueryStyle {
    public static let probeSampleRows = 1000
    public static let wideTableLimit = 60
    public static let trimColumnCap = 40
    public static let lowCardinalityMax = 12

    // MARK: - Column Name Classification Rules

    private static let labelTokens: Set<String> = [
        "name", "label", "title", "desc", "description", "caption", "heading",
        "strategy_id", "strategy_name", "primary_strategy_id", "primary_strategy_name",
        "combined_id", "symbol", "what"
    ]

    private static let rowNumExact: Set<String> = [
        "row", "rownum", "row_num", "rownumber", "row_number",
        "line", "lineno", "line_no", "seq", "sequence", "serial",
        "ordinal", "idx", "index", "nr", "no", "num", "rn", "#"
    ]

    private static let systemExact: Set<String> = [
        "created_at", "updated_at", "deleted_at", "modified_at",
        "last_modified", "last_updated", "created_on", "updated_on",
        "created_by", "updated_by", "date_created", "date_modified", "date_updated",
        "version", "revision", "row_version", "lock_version", "etag", "_etag",
        "uuid", "guid", "tenant_id", "org_id", "organization_id", "workspace_id"
    ]

    private static let statusTokens: Set<String> = [
        "status", "state", "type", "kind", "category", "categ", "class",
        "stage", "phase", "priority", "severity", "level", "tier", "mode", "flag",
        "regime", "win", "direction", "role", "order_type", "exit_reason", "feature", "pred"
    ]

    private static let primaryDateExact: Set<String> = [
        "date", "datetime", "timestamp", "time", "dt",
        "entry_date", "exit_date", "window_start", "window_end",
        "start_date", "end_date", "first_date", "last_date", "regime_date"
    ]

    private static let headlineMetricExact: Set<String> = [
        "cagr", "total_return_pct", "avg_return_pct", "vs_all_avg_return_pct", "return_pct",
        "net_profit", "net_pnl", "total_net_pnl", "gross_pnl",
        "final_equity", "total_equity", "max_drawdown_pct", "drawdown_pct",
        "sharpe_ratio", "calmar_ratio", "sortino_ratio", "profit_factor",
        "win_rate", "total_trades", "n", "wins", "winning_trades", "losing_trades",
        "avg_trade_return_pct", "payoff_ratio", "avg_hold_days", "avg_holding_days", "hold_days",
        "close", "adj_close", "adj close", "open", "high", "low", "volume",
        "entry_price", "exit_price", "signal", "prob_bull", "prob_bear",
        "threshold", "ratio", "up_streak", "down_streak", "streak", "entered", "entry"
    ]

    private static let longTextTokens: Set<String> = [
        "note", "notes", "comment", "comments", "body", "content", "message", "msg",
        "remark", "remarks", "summary", "detail", "details", "bio", "about",
        "abstract", "excerpt", "text", "metadata", "facts", "suspect", "reason", "class_counts"
    ]

    private static func words(of name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
            .map(String.init)
    }

    public static func isLabelColumn(_ name: String) -> Bool {
        let lower = name.lowercased()
        if labelTokens.contains(lower) { return true }
        return words(of: lower).contains(where: { labelTokens.contains($0) })
    }

    public static func isRowNumberColumn(_ col: Column, probe: TableProbe?, hasKey: Bool) -> Bool {
        if col.pk || !hasKey { return false }
        let lower = col.name.lowercased()
        if rowNumExact.contains(lower) { return true }
        guard col.isNumeric, let p = probe?.byName[col.name], let n = probe?.sampleN, n > 3 else {
            return false
        }
        if p.fill != n || p.distinct != n { return false }
        guard let lo = p.minVal, let hi = p.maxVal,
              lo.rounded() == lo, hi.rounded() == hi else { return false }
        let loInt = Int(lo), hiInt = Int(hi)
        return loInt >= 0 && loInt <= 2 && abs((hiInt - loInt + 1) - n) <= 1
    }

    public static func isSystemColumn(_ name: String) -> Bool {
        let lower = name.lowercased()
        if systemExact.contains(lower) { return true }
        if lower.hasPrefix("audit_") || lower.hasSuffix("_audit") { return true }
        return false
    }

    public static func isLongTextColumn(_ name: String) -> Bool {
        let lower = name.lowercased()
        if longTextTokens.contains(lower) { return true }
        return words(of: lower).contains(where: { longTextTokens.contains($0) })
    }

    /// Coarse tier for ordering remaining columns in `trim`:
    /// 0 = status / regime / type, 1 = primary dates, 2 = headline metrics,
    /// 3 = other numeric/dates, 4 = other text, 5 = long text / JSON
    public static func columnTier(_ col: Column) -> Int {
        let lower = col.name.lowercased()
        if isLongTextColumn(lower) { return 5 }
        let tokens = words(of: lower)
        if statusTokens.contains(lower) || tokens.contains(where: { statusTokens.contains($0) }) {
            return 0
        }
        if primaryDateExact.contains(lower) {
            return 1
        }
        if headlineMetricExact.contains(lower) {
            return 2
        }
        if col.isNumeric || lower.hasSuffix("_date") || lower.hasSuffix("_at") || lower.contains("date") {
            return 3
        }
        return 4
    }

    /// Orders `Column` models according to Banquet Query Style rules.
    public static func orderColumns(
        columns: [Column],
        probe: TableProbe? = nil,
        hints: [String]? = nil
    ) -> [Column] {
        var hintPos: [String: Int] = [:]
        if let hints {
            for (i, h) in hints.enumerated() {
                hintPos[h.lowercased()] = i
            }
        }

        let indexed = columns.enumerated().map { (ord, col) -> (col: Column, key: (Int, Int, Int, Int, Int, Int)) in
            let pkRank = col.pkIndex > 0 ? 0 : 1
            let pkOrder = col.pkIndex > 0 ? col.pkIndex : 0
            let hRank = hintPos[col.name.lowercased()] ?? Int.max
            let labelRank = isLabelColumn(col.name) ? 0 : 1
            let tier = columnTier(col)
            return (col, (pkRank, pkOrder, hRank, labelRank, tier, ord))
        }

        return indexed.sorted { a, b in
            a.key < b.key
        }.map { $0.col }
    }

    /// Filters an already-ordered column list using the Banquet Query Style "don't show this" rules:
    /// drops empty columns, redundant row-number counters, system/audit columns, and near-duplicates,
    /// and caps ultra-wide tables to `maxColumns` most important columns.
    public static func visibleColumns(
        orderedColumns: [Column],
        probe: TableProbe? = nil,
        hints: [String]? = nil,
        maxColumns: Int = QueryStyle.trimColumnCap
    ) -> [Column] {
        let hintedSet = Set((hints ?? []).map { $0.lowercased() })
        let hasKey = orderedColumns.contains { $0.pk || isLabelColumn($0.name) || $0.name.lowercased().hasSuffix("_id") }
        let dups = probe?.duplicates ?? []

        func isPinned(_ c: Column) -> Bool {
            c.pk || hintedSet.contains(c.name.lowercased())
        }

        func isEmpty(_ c: Column) -> Bool {
            guard let p = probe?.byName[c.name], let n = probe?.sampleN, n > 0 else { return false }
            return !p.nonNull
        }

        var kept = orderedColumns.filter { c in
            if isPinned(c) { return true }
            if isEmpty(c) { return false }
            if isRowNumberColumn(c, probe: probe, hasKey: hasKey) { return false }
            if hasKey && isSystemColumn(c.name) { return false }
            if dups.contains(c.name.lowercased()) { return false }
            return true
        }

        if kept.isEmpty {
            kept = orderedColumns
        }

        if kept.count > maxColumns {
            var head = Array(kept.prefix(maxColumns))
            let inHead = Set(head.map { $0.name })
            for c in kept where isPinned(c) && !inHead.contains(c.name) {
                head.append(c)
            }
            kept = head
        }

        return kept
    }

    /// Backwards-compatible string-based entry point for `QueryStyle.orderColumns`.
    public static func orderColumns(
        primaryKeys: [String],
        allColumns: [String],
        sampledRows: [[String: Any]]
    ) -> [String] {
        let pkMap = Dictionary(uniqueKeysWithValues: primaryKeys.enumerated().map { ($0.element.lowercased(), $0.offset + 1) })
        let cols: [Column] = allColumns.map { name in
            let pkIdx = pkMap[name.lowercased()] ?? 0
            var isNum = false
            for row in sampledRows.prefix(20) {
                if let v = row[name] {
                    if v is Int || v is Int64 || v is Double || v is Float || v is NSNumber {
                        isNum = true
                        break
                    }
                }
            }
            return Column(name: name, type: isNum ? "REAL" : "TEXT", notNull: false, pk: pkIdx > 0, pkIndex: pkIdx)
        }

        var byName: [String: ColumnProbeStats] = [:]
        let n = sampledRows.count
        if n > 0 {
            for col in cols {
                var fill = 0
                var distinctVals = Set<String>()
                var minV: Double?
                var maxV: Double?
                for row in sampledRows {
                    guard let val = row[col.name], !(val is NSNull) else { continue }
                    fill += 1
                    distinctVals.insert(String(describing: val))
                    if let d = (val as? NSNumber)?.doubleValue ?? Double(String(describing: val)) {
                        minV = minV.map { min($0, d) } ?? d
                        maxV = maxV.map { max($0, d) } ?? d
                    }
                }
                byName[col.name] = ColumnProbeStats(
                    nonNull: fill > 0,
                    fill: fill,
                    distinct: distinctVals.count,
                    minVal: minV,
                    maxVal: maxV
                )
            }
        }
        let probe = TableProbe(sampleN: n, byName: byName)
        let ordered = orderColumns(columns: cols, probe: probe)
        let visible = visibleColumns(orderedColumns: ordered, probe: probe)
        return visible.map { $0.name }
    }

    // MARK: - Duplicate Detection Helpers

    private static let keyTokens: Set<String> = [
        "id", "code", "key", "slug", "ref", "uuid", "guid",
        "name", "label", "title", "desc", "description", "number", "no"
    ]

    static func relatedNames(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased(), nb = b.lowercased()
        let x = na.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        let y = nb.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        if x == y || x.contains(y) || y.contains(x) { return true }
        if keyTokens.contains(x) && keyTokens.contains(y) { return true }
        let ta = Set(words(of: na))
        return words(of: nb).contains { keyTokens.contains($0) && ta.contains($0) }
    }

    static func duplicateLoser(_ a: Column, ordA: Int, _ b: Column, ordB: Int) -> Column {
        if (a.pkIndex > 0) != (b.pkIndex > 0) {
            return a.pkIndex > 0 ? b : a
        }
        if a.name.count != b.name.count {
            return a.name.count < b.name.count ? b : a
        }
        return ordA <= ordB ? b : a
    }

    /// Determines whether a numeric measure should be aggregated with `AVG` (rates, percentages,
    /// ratios, prices, hold days) rather than `SUM` (PnL, trade counts, volume) in Summary mode.
    public static func prefersAverageAggregation(_ colName: String) -> Bool {
        let n = colName.lowercased()
        if n == "n" || n == "wins" || n == "total_trades" || n == "winning_trades" || n == "losing_trades"
            || n == "volume" || n == "shares" || n == "bars" || n == "samples" || n == "grown_cases"
            || n == "net_pnl" || n == "gross_pnl" || n == "total_net_pnl" || n == "net_profit"
            || n.hasSuffix("_commission_paid") || n == "commission_paid" {
            return false
        }
        return true
    }
}

// MARK: - Doc Integration for Trim & Summary Views

extension Doc {
    /// Probes up to `QueryStyle.probeSampleRows` rows of `tableName` to compute column fill,
    /// cardinality, bounds, and near-duplicates. Cached per table on `TableState`.
    public func probeTable(for tableName: String) -> TableProbe {
        let ts = tableState(for: tableName)
        if let cached = ts.cachedProbe {
            return cached
        }

        guard let cols = try? columns(for: tableName),
              !cols.isEmpty,
              cols.count <= QueryStyle.wideTableLimit else {
            let empty = TableProbe()
            ts.cachedProbe = empty
            return empty
        }

        // For views (which can be expensive multi-stage window functions), use a smaller sample
        // so probing never stalls first paint.
        let isView = table(named: tableName)?.isView ?? false
        let sampleLimit = isView ? 250 : QueryStyle.probeSampleRows

        var selectParts: [String] = ["COUNT(*) AS n"]
        for (i, c) in cols.enumerated() {
            let q = Doc.quoteIdent(c.name)
            selectParts.append("COUNT(\(q)) AS c\(i)")
            selectParts.append("COUNT(DISTINCT \(q)) AS k\(i)")
            selectParts.append((c.isNumeric ? "MIN(\(q))" : "NULL") + " AS lo\(i)")
            selectParts.append((c.isNumeric ? "MAX(\(q))" : "NULL") + " AS hi\(i)")
        }

        var probe = TableProbe()
        let sql = "SELECT \(selectParts.joined(separator: ", ")) FROM (SELECT * FROM \(ts.quoted) LIMIT \(sampleLimit))"
        if let row = try? fg.queryRow(sql), !row.isEmpty {
            let sampleN = Int(row[0].intValue ?? 0)
            probe.sampleN = sampleN
            for (i, c) in cols.enumerated() {
                let base = 1 + i * 4
                guard base + 3 < row.count else { continue }
                let fill = Int(row[base].intValue ?? 0)
                let distinct = Int(row[base + 1].intValue ?? 0)
                let lo = row[base + 2].doubleValue
                let hi = row[base + 3].doubleValue
                probe.byName[c.name] = ColumnProbeStats(
                    nonNull: fill > 0,
                    fill: fill,
                    distinct: distinct,
                    minVal: lo,
                    maxVal: hi
                )
            }
        }

        // Near-duplicate check (Rule 7)
        if probe.sampleN > 0 && cols.count >= 2 && !isView {
            var candidates: [(col: Column, ord: Int)] = []
            for (i, c) in cols.enumerated() {
                if let p = probe.byName[c.name], p.nonNull {
                    candidates.append((c, i))
                }
            }
            var pairs: [((Column, Int), (Column, Int))] = []
            for a in 0..<candidates.count {
                for b in (a + 1)..<candidates.count {
                    let ca = candidates[a], cb = candidates[b]
                    guard let pa = probe.byName[ca.col.name],
                          let pb = probe.byName[cb.col.name] else { continue }
                    if pa.fill == pb.fill && pa.distinct == pb.distinct &&
                        QueryStyle.relatedNames(ca.col.name, cb.col.name) {
                        pairs.append((ca, cb))
                    }
                }
            }
            let checks = Array(pairs.prefix(16))
            if !checks.isEmpty {
                let checkExprs = checks.enumerated().map { idx, pair in
                    "SUM(\(Doc.quoteIdent(pair.0.0.name)) IS NOT \(Doc.quoteIdent(pair.1.0.name))) AS p\(idx)"
                }
                let dupSQL = "SELECT \(checkExprs.joined(separator: ", ")) FROM (SELECT * FROM \(ts.quoted) LIMIT \(sampleLimit))"
                if let dupRow = try? fg.queryRow(dupSQL) {
                    for (idx, pair) in checks.enumerated() where idx < dupRow.count {
                        if (dupRow[idx].intValue ?? 1) == 0 {
                            let loser = QueryStyle.duplicateLoser(pair.0.0, ordA: pair.0.1, pair.1.0, ordB: pair.1.1)
                            probe.duplicates.insert(loser.name.lowercased())
                        }
                    }
                }
            }
        }

        ts.cachedProbe = probe
        return probe
    }

    /// Returns the ordered column list and the set of hidden column names for `trim` mode.
    public func trimPlan(for tableName: String) -> (ordered: [Column], hidden: Set<String>) {
        guard let allCols = try? columns(for: tableName), !allCols.isEmpty else {
            return ([], [])
        }
        let probe = probeTable(for: tableName)
        let lowerTable = tableName.lowercased()
        let hints = style.tableColumns[lowerTable] ?? style.tableColumns["*"]
        let ordered = QueryStyle.orderColumns(columns: allCols, probe: probe, hints: hints)
        let visible = QueryStyle.visibleColumns(orderedColumns: ordered, probe: probe, hints: hints)
        let visibleNames = Set(visible.map { $0.name })
        let hidden = Set(allCols.map { $0.name }).subtracting(visibleNames)
        return (ordered, hidden)
    }

    /// Builds and executes an automatic `GROUP BY` summary page for `tableName`.
    public func summaryPage(
        for tableName: String,
        filters: [ColumnFilter] = [],
        sort: String? = nil,
        desc: Bool = false,
        sortNumeric: Bool = false,
        limit: Int = 200
    ) throws -> Page {
        let startTime = DispatchTime.now()
        touch()
        defer { touch() }

        let allCols = try columns(for: tableName)
        let probe = probeTable(for: tableName)
        let lowerTable = tableName.lowercased()
        let hints = style.tableColumns[lowerTable] ?? style.tableColumns["*"]
        let ordered = QueryStyle.orderColumns(columns: allCols, probe: probe, hints: hints)
        let visible = QueryStyle.visibleColumns(orderedColumns: ordered, probe: probe, hints: hints, maxColumns: 28)

        let n = probe.sampleN
        let bodyCols = visible.filter { !$0.pk || visible.count <= 4 }

        // Identify low-cardinality grouping dimensions (e.g. regime, win, symbol, strategy_id, exit_reason)
        var dims: [Column] = bodyCols.filter { c in
            guard let p = probe.byName[c.name] else { return false }
            if QueryStyle.isLongTextColumn(c.name) { return false }
            let isCatName = !c.isNumeric || c.name.lowercased() == "state" || c.name.lowercased() == "report"
            let maxCard = isCatName ? 25 : QueryStyle.lowCardinalityMax
            return p.distinct >= 2 && p.distinct <= maxCard && (n == 0 || p.distinct < n) && p.fill > 0
        }
        if dims.count > 3 {
            dims = Array(dims.prefix(3))
        }

        let dimNames = Set(dims.map { $0.name })
        let measures = visible.filter { $0.isNumeric && !dimNames.contains($0.name) && !$0.pk }

        var selectExprs: [String] = []
        var summaryCols: [Column] = []

        for d in dims {
            selectExprs.append(Doc.quoteIdent(d.name))
            summaryCols.append(Column(name: d.name, type: d.type, notNull: d.notNull, pk: true, pkIndex: summaryCols.count + 1))
        }

        selectExprs.append("COUNT(*) AS \"rows\"")
        summaryCols.append(Column(name: "rows", type: "INTEGER", notNull: true, pk: false))

        for m in measures.prefix(16) {
            let q = Doc.quoteIdent(m.name)
            if QueryStyle.prefersAverageAggregation(m.name) {
                selectExprs.append("AVG(\(q)) AS \(q)")
            } else {
                selectExprs.append("SUM(\(q)) AS \(q)")
            }
            summaryCols.append(Column(name: m.name, type: "REAL", notNull: false, pk: false))
        }

        // Build optional WHERE clause from active filters
        var filterClause = ""
        var filterArgs: [Any] = []
        if !filters.isEmpty {
            let parts = filters.compactMap { f -> String? in
                guard allCols.contains(where: { $0.name == f.column }) else { return nil }
                let (clause, a) = f.sql(quotedColumn: Doc.quoteIdent(f.column))
                filterArgs.append(contentsOf: a)
                return "(\(clause))"
            }
            if !parts.isEmpty { filterClause = " WHERE " + parts.joined(separator: " AND ") }
        }

        let quotedTable = Doc.quoteIdent(tableName)
        // For huge tables (> 100k estimated rows) or views without selective filters, bound the rollup scan
        // so Summary mode stays snappy even on multi-gigabyte databases.
        let est = estimateRows(for: tableName)
        let isView = table(named: tableName)?.isView ?? false
        let sourceExpr: String
        if (est.known && est.rows > 250_000 && filterClause.isEmpty) || isView {
            sourceExpr = "(SELECT * FROM \(quotedTable)\(filterClause) LIMIT 50000)"
        } else {
            sourceExpr = "\(quotedTable)\(filterClause)"
        }

        let groupClause = dims.isEmpty ? "" : " GROUP BY " + dims.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")

        let orderClause: String
        if let sortCol = sort, summaryCols.contains(where: { $0.name == sortCol }) {
            let q = Doc.quoteIdent(sortCol)
            let se = sortNumeric ? "CAST(\(q) AS REAL)" : q
            orderClause = " ORDER BY \(se) \(desc ? "DESC" : "ASC")"
        } else if !dims.isEmpty {
            orderClause = " ORDER BY " + dims.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")
        } else {
            orderClause = ""
        }

        let sql = "SELECT \(selectExprs.joined(separator: ", ")) FROM \(sourceExpr)\(groupClause)\(orderClause) LIMIT \(max(1, min(limit, 500)))"
        let rawRows = try fg.query(sql, args: filterArgs)

        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let micros = Int64(elapsedNanos / 1000)

        return Page(
            table: tableName,
            columns: summaryCols,
            rows: rawRows,
            rowIDs: [],
            start: 0,
            approx: false,
            path: dims.isEmpty ? "summary-totals" : "summary-group",
            micros: micros
        )
    }
}
