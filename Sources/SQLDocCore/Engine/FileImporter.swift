import Foundation

/// Converts a handful of plain-text formats into a throwaway SQLite database so
/// the viewer can open them. A tiny native subset of what `mksqlite` does — no
/// Excel or PDF (those need libraries); those extensions return a clear error.
public enum FileImporter {
    public static let supportedExtensions: Set<String> = ["csv", "tsv", "json", "ndjson", "jsonl"]

    public static func canImport(path: String) -> Bool {
        supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Converts `path` to a new `.db` in a temp directory and returns its path.
    public static func importToTempDB(path: String) throws -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let data = try String(contentsOfFile: path, encoding: .utf8)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sqlswift-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("\(base).db").path

        let conn = try SQLiteConnection(path: dbPath, readOnly: false)
        defer { conn.close() }
        try conn.exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF")

        switch ext {
        case "csv":  try loadDelimited(data, sep: ",", table: sanitize(base), into: conn, source: name)
        case "tsv":  try loadDelimited(data, sep: "\t", table: sanitize(base), into: conn, source: name)
        case "json", "ndjson", "jsonl": try loadJSON(data, table: sanitize(base), into: conn, source: name)
        default:
            throw SQLiteError.notADatabase(path: path)
        }
        return dbPath
    }

    // MARK: - CSV / TSV

    private static func loadDelimited(_ text: String, sep: Character, table: String,
                                     into conn: SQLiteConnection, source: String) throws {
        var rows = parseDelimited(text, sep: sep)
        guard !rows.isEmpty else { throw SQLiteError.executionFailed(query: "import", message: "Empty file.") }

        var header = rows.removeFirst()
        // De-duplicate / fill blank column names.
        var seen: [String: Int] = [:]
        header = header.enumerated().map { i, raw in
            var n = sanitize(raw.isEmpty ? "col\(i + 1)" : raw)
            if let c = seen[n] { seen[n] = c + 1; n = "\(n)_\(c + 1)" } else { seen[n] = 1 }
            return n
        }

        let cols = header.map { Doc.quoteIdent($0) }.joined(separator: ", ")
        try conn.exec("CREATE TABLE \(Doc.quoteIdent(table)) (\(header.map { "\(Doc.quoteIdent($0)) TEXT" }.joined(separator: ", ")))")
        try conn.exec("CREATE TABLE _style (key TEXT, value TEXT)")
        try conn.exec("INSERT INTO _style VALUES ('title', \(sqlStr(source)))")

        let placeholders = header.map { _ in "?" }.joined(separator: ", ")
        let insert = "INSERT INTO \(Doc.quoteIdent(table)) (\(cols)) VALUES (\(placeholders))"
        try conn.exec("BEGIN")
        for r in rows where !(r.count == 1 && r[0].isEmpty) {
            var vals = r
            if vals.count < header.count { vals += Array(repeating: "", count: header.count - vals.count) }
            if vals.count > header.count { vals = Array(vals.prefix(header.count)) }
            _ = try conn.query(insert, args: vals.map { $0 as Any })
        }
        try conn.exec("COMMIT")
    }

    /// A forgiving delimited parser: RFC-4180-ish quoting, `\r\n` or `\n`.
    static func parseDelimited(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case sep: record.append(field); field = ""
                case "\r": break
                case "\n": record.append(field); rows.append(record); record = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); rows.append(record) }
        return rows
    }

    // MARK: - JSON

    private static func loadJSON(_ text: String, table: String,
                                into conn: SQLiteConnection, source: String) throws {
        var objects: [[String: Any]] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            if let arr = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [[String: Any]] {
                objects = arr
            }
        } else {
            // NDJSON: one object per line.
            for line in trimmed.split(separator: "\n") {
                if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    objects.append(o)
                }
            }
        }
        guard !objects.isEmpty else {
            throw SQLiteError.executionFailed(query: "import", message: "No JSON objects found (expected an array or NDJSON).")
        }

        // Union of keys, first-seen order.
        var keys: [String] = []
        var keySet = Set<String>()
        for o in objects { for k in o.keys where !keySet.contains(k) { keySet.insert(k); keys.append(k) } }

        let cols = keys.map { "\(Doc.quoteIdent(sanitize($0))) TEXT" }.joined(separator: ", ")
        try conn.exec("CREATE TABLE \(Doc.quoteIdent(table)) (\(cols))")
        try conn.exec("CREATE TABLE _style (key TEXT, value TEXT)")
        try conn.exec("INSERT INTO _style VALUES ('title', \(sqlStr(source)))")

        let colList = keys.map { Doc.quoteIdent(sanitize($0)) }.joined(separator: ", ")
        let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
        let insert = "INSERT INTO \(Doc.quoteIdent(table)) (\(colList)) VALUES (\(placeholders))"
        try conn.exec("BEGIN")
        for o in objects {
            let vals: [Any] = keys.map { k in
                switch o[k] {
                case let s as String: return s
                case let n as NSNumber: return n.stringValue
                case is NSNull, nil: return NSNull()
                case let v: return String(describing: v!)
                }
            }
            _ = try conn.query(insert, args: vals)
        }
        try conn.exec("COMMIT")
    }

    // MARK: - helpers

    private static func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        out.removeAll { !($0.isLetter || $0.isNumber || $0 == "_") }
        if out.isEmpty { out = "col" }
        if let f = out.first, f.isNumber { out = "_" + out }
        return out
    }
    private static func sqlStr(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "''"))'" }
}
