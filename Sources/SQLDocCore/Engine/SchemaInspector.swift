import Foundation
import SQLite3

extension Doc {
    /// Full schema detail for one table or view: DDL, columns, foreign keys, indexes.
    /// Everything here is a `PRAGMA` or a `sqlite_master` lookup — cheap, but not
    /// on the first-paint path, so callers should run it off the main thread.
    public func tableSchema(for tableName: String) throws -> TableSchema {
        let ts = tableState(for: tableName)
        let cols = try columns(for: tableName)

        var type = "table"
        var ddl = ""
        if let row = try? fg.queryRow(
            "SELECT type, COALESCE(sql, '') FROM sqlite_master WHERE name = ? LIMIT 1", args: [tableName]),
           row.count >= 2 {
            type = row[0].textValue ?? "table"
            ddl = row[1].textValue ?? ""
        }

        var fks: [ForeignKey] = []
        if let rows = try? fg.query("PRAGMA foreign_key_list(\(ts.quoted))") {
            // cols: id, seq, table, from, to, on_update, on_delete, match
            for r in rows where r.count >= 7 {
                fks.append(ForeignKey(
                    fromColumn: r[3].textValue ?? "",
                    table: r[2].textValue ?? "",
                    toColumn: r[4].textValue ?? "",
                    onUpdate: r[5].textValue ?? "",
                    onDelete: r[6].textValue ?? ""
                ))
            }
        }

        var indexes: [TableIndex] = []
        if let rows = try? fg.query("PRAGMA index_list(\(ts.quoted))") {
            // cols: seq, name, unique, origin, partial
            for r in rows where r.count >= 5 {
                let name = r[1].textValue ?? ""
                var idxCols: [String] = []
                if let infoRows = try? fg.query("PRAGMA index_info(\(Doc.quoteIdent(name)))") {
                    // cols: seqno, cid, name
                    for ir in infoRows where ir.count >= 3 {
                        if let c = ir[2].textValue { idxCols.append(c) }
                    }
                }
                indexes.append(TableIndex(
                    name: name,
                    unique: (r[2].intValue ?? 0) != 0,
                    origin: r[3].textValue ?? "c",
                    partial: (r[4].intValue ?? 0) != 0,
                    columns: idxCols
                ))
            }
        }

        // The INTEGER PRIMARY KEY column is the rowid alias.
        let rowidAlias = cols.first(where: {
            $0.pk && $0.type.uppercased().contains("INT")
        })?.name

        return TableSchema(
            name: tableName, type: type, ddl: ddl, columns: cols,
            foreignKeys: fks, indexes: indexes, rowidAlias: rowidAlias
        )
    }

    /// The stored values of some cells of one row, whole, fetched by rowid. For
    /// cells a grid page carries only as `.textPrefix`. Returns nil for
    /// non-rowid tables, a missing row, or when `control` stops it.
    public func cellValues(
        table tableName: String, columns: [String], rowID: Int64, control: QueryControl? = nil
    ) -> [SQLiteValue]? {
        guard !columns.isEmpty, let t = table(named: tableName), t.hasRowID else { return nil }
        let list = columns.map { Doc.quoteIdent($0) }.joined(separator: ", ")
        let sql = "SELECT \(list) FROM \(Doc.quoteIdent(tableName)) WHERE rowid = ? LIMIT 1"
        return (try? bg.queryRow(sql, args: [rowID], control: control)) ?? nil
    }

    /// Raw bytes of a BLOB cell, fetched by rowid. Returns nil for non-rowid tables.
    public func blobData(table tableName: String, column: String, rowID: Int64) -> Data? {
        guard let t = table(named: tableName), t.hasRowID else { return nil }
        let sql = "SELECT \(Doc.quoteIdent(column)) FROM \(Doc.quoteIdent(tableName)) WHERE rowid = ? LIMIT 1"
        return try? bg.queryBlob(sql, args: [rowID])
    }

    // MARK: - Ad-hoc read-only query (the console)

    public static let queryRowCap = BehaviorConfig.queryRowCap

    /// Runs a single read-only statement and returns up to `queryRowCap` rows.
    /// The connection is already `query_only=1`, so writes fail at the engine;
    /// this additionally rejects multi-statement input and obvious DDL/DML up
    /// front for a clearer error.
    public func runQuery(_ sql: String, control: QueryControl? = nil) throws -> QueryResult {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        guard !trimmed.isEmpty else {
            throw SQLiteError.executionFailed(query: sql, message: "Empty query.")
        }
        if trimmed.contains(";") {
            throw SQLiteError.executionFailed(query: sql, message: "One statement at a time.")
        }
        let firstWord = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "(" })
            .first.map { $0.uppercased() } ?? ""
        let allowed: Set<String> = ["SELECT", "WITH", "VALUES", "PRAGMA", "EXPLAIN"]
        guard allowed.contains(firstWord) else {
            throw SQLiteError.executionFailed(query: sql, message: "Read-only viewer: only SELECT / WITH / PRAGMA / EXPLAIN are allowed.")
        }

        let start = DispatchTime.now()
        let capped = "SELECT * FROM (\(trimmed)) LIMIT \(Doc.queryRowCap + 1)"
        // PRAGMA/EXPLAIN can't be wrapped in a subquery; run those raw.
        let effective = (firstWord == "PRAGMA" || firstWord == "EXPLAIN") ? trimmed : capped

        let raw = try bg.query(effective, control: control)
        let names = queryColumnNames(effective, fallbackCount: raw.first?.count ?? 0)
        let truncated = (firstWord != "PRAGMA" && firstWord != "EXPLAIN") && raw.count > Doc.queryRowCap
        let rows = truncated ? Array(raw.prefix(Doc.queryRowCap)) : raw
        let micros = Int64((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1000)
        return QueryResult(columns: names, rows: rows, truncated: truncated, micros: micros, sql: trimmed)
    }

    /// Executes a compiled Banquet or SQL query and wraps the result in a `Page` for the main table grid.
    public func banquetPage(
        sql: String, table: String, startOffset: Int64 = 0, control: QueryControl? = nil
    ) throws -> Page {
        let qr = try runQuery(sql, control: (control ?? QueryControl()).forPage(rowKeyed: false))
        let baseCols = (try? columns(for: table)) ?? []
        let cols: [Column] = qr.columns.enumerated().map { idx, name in
            if let existing = baseCols.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return existing
            }
            var inferredType = "TEXT"
            for row in qr.rows where idx < row.count {
                switch row[idx] {
                case .integer:
                    inferredType = "INTEGER"
                case .real:
                    inferredType = "REAL"
                case .blob:
                    inferredType = "BLOB"
                case .text, .textPrefix:
                    inferredType = "TEXT"
                case .null:
                    continue
                }
                break
            }
            return Column(name: name, type: inferredType, notNull: false, pk: false, pkIndex: 0)
        }
        let rowIDs = qr.rows.indices.map { startOffset + Int64($0) + 1 }
        return Page(
            table: table,
            columns: cols,
            rows: qr.rows,
            text: qr.text,
            rowIDs: rowIDs,
            start: startOffset,
            approx: false,
            path: "banquet-sql",
            micros: qr.micros
        )
    }

    /// Column names for a prepared statement (SQLite can report them even for 0 rows).
    private func queryColumnNames(_ sql: String, fallbackCount: Int) -> [String] {
        var names: [String] = []
        bg.withPreparedColumnNames(sql) { names = $0 }
        if names.isEmpty {
            names = (0..<max(fallbackCount, 0)).map { "col\($0 + 1)" }
        }
        return names
    }

    // MARK: - View Lineage, Implicit Relational Links & Partition Quick-Switcher

    /// Extracts documentation comments (`-- ...`) and upstream/downstream table/view dependencies
    /// for a table or view from `sqlite_master`.
    public func viewLineage(for tableName: String) -> (comment: String?, upstream: [String], downstream: [String]) {
        guard let masterRows = try? fg.query(
            "SELECT name, type, COALESCE(sql, '') FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'"
        ) else {
            return (nil, [], [])
        }

        var ddlByTable: [String: String] = [:]
        var allNames: [String] = []
        for r in masterRows where r.count >= 3 {
            guard let name = r[0].textValue else { continue }
            let sql = r[2].textValue ?? ""
            ddlByTable[name] = sql
            allNames.append(name)
        }

        let currentDDL = ddlByTable[tableName] ?? ""
        var commentLines: [String] = []
        for rawLine in currentDDL.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--") {
                let cleaned = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                // Skip mechanical filename headers like "-- 01_v_daily_bars.sql"
                if !cleaned.isEmpty && !cleaned.hasSuffix(".sql") {
                    commentLines.append(cleaned)
                }
            } else if let dashRange = trimmed.range(of: "--") {
                let cleaned = String(trimmed[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty && !cleaned.hasSuffix(".sql") {
                    commentLines.append(cleaned)
                }
            }
        }
        let comment = commentLines.isEmpty ? nil : commentLines.joined(separator: " ")

        func sqlReferences(_ ddl: String, identifier target: String) -> Bool {
            guard !ddl.isEmpty else { return false }
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: target) + "\\b"
            return ddl.range(of: pattern, options: .regularExpression) != nil
        }

        var upstream: [String] = []
        let isCurrentView = (table(named: tableName)?.isView ?? false)
        if isCurrentView {
            for candidate in allNames where candidate.lowercased() != tableName.lowercased() {
                if sqlReferences(currentDDL, identifier: candidate) {
                    upstream.append(candidate)
                }
            }
        }

        var downstream: [String] = []
        for candidate in allNames where candidate.lowercased() != tableName.lowercased() {
            if let candTable = table(named: candidate), candTable.isView,
               let candDDL = ddlByTable[candidate],
               sqlReferences(candDDL, identifier: tableName) {
                downstream.append(candidate)
            }
        }

        return (comment, upstream, downstream)
    }

    /// Finds sibling tables/views in the same database that contain a column with `columnName`
    /// (enabling 1-click drill-down across `runs`, `performance_summary`, `trades`, `signals`, `equity_curve`).
    public func relatedTables(forColumn columnName: String, excluding currentTable: String) -> [String] {
        let target = columnName.lowercased()
        var matches: [String] = []
        for t in tables where !t.hidden && t.name.lowercased() != currentTable.lowercased() {
            if let cols = try? columns(for: t.name),
               cols.contains(where: { $0.name.lowercased() == target }) {
                matches.append(t.name)
            }
        }
        return matches
    }

    /// Detects the best leading partition/filter column (e.g. `symbol`, `strategy_id`, `regime`, `win`, `run_id`)
    /// and returns up to 40 distinct values using an index-friendly bounded query.
    public func partitionQuickValues(for tableName: String) -> (column: String, values: [String])? {
        guard let cols = try? columns(for: tableName), !cols.isEmpty else { return nil }
        let preferredNames = ["symbol", "strategy_id", "regime", "win", "run_id", "kind", "exit_reason"]

        var candidateCol: String?
        // 1. Check preferred analytical partition columns
        for pref in preferredNames {
            if let found = cols.first(where: { $0.name.lowercased() == pref }) {
                candidateCol = found.name
                break
            }
        }
        // 2. Otherwise check leading column of a composite PK or index
        if candidateCol == nil {
            let pkCols = cols.filter { $0.pkIndex > 0 }.sorted { $0.pkIndex < $1.pkIndex }
            if pkCols.count >= 2 {
                candidateCol = pkCols[0].name
            } else if let sch = try? tableSchema(for: tableName),
                      let firstIdxCol = sch.indexes.first?.columns.first {
                candidateCol = firstIdxCol
            }
        }

        guard let col = candidateCol else { return nil }
        let qCol = Doc.quoteIdent(col)
        let qTable = Doc.quoteIdent(tableName)

        // Try direct DISTINCT (uses loose index scan on indexed leading columns in SQLite)
        // under `schema.probe_budget_ms`, falling back to a 5,000-row prefix sample on unindexed huge tables.
        let sqlDirect = "SELECT DISTINCT CAST(\(qCol) AS TEXT) FROM \(qTable) WHERE \(qCol) IS NOT NULL ORDER BY \(qCol) LIMIT 40"
        let rows = bg.queryWithTimeout(sqlDirect, maxMillis: BehaviorConfig.schemaProbeBudgetMs)
            ?? bg.queryWithTimeout(
                "SELECT DISTINCT CAST(\(qCol) AS TEXT) FROM (SELECT \(qCol) FROM \(qTable) WHERE \(qCol) IS NOT NULL LIMIT 5000) ORDER BY 1 LIMIT 40",
                maxMillis: BehaviorConfig.schemaProbeBudgetMs
            )
        guard let validRows = rows else { return nil }
        let vals = validRows.compactMap { $0.first?.textValue }.filter { !$0.isEmpty }
        guard vals.count >= 2 else { return nil }
        return (col, vals)
    }
}
