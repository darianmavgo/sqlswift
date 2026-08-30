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

    // MARK: - Ad-hoc read-only query (the console)

    public static let queryRowCap = 5000

    /// Runs a single read-only statement and returns up to `queryRowCap` rows.
    /// The connection is already `query_only=1`, so writes fail at the engine;
    /// this additionally rejects multi-statement input and obvious DDL/DML up
    /// front for a clearer error.
    public func runQuery(_ sql: String) throws -> QueryResult {
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

        let raw = try bg.query(effective)
        let names = queryColumnNames(effective, fallbackCount: raw.first?.count ?? 0)
        let truncated = (firstWord != "PRAGMA" && firstWord != "EXPLAIN") && raw.count > Doc.queryRowCap
        let rows = truncated ? Array(raw.prefix(Doc.queryRowCap)) : raw
        let micros = Int64((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1000)
        return QueryResult(columns: names, rows: rows, truncated: truncated, micros: micros, sql: trimmed)
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
}
