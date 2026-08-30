import Foundation
import SQLite3

public enum ExportFormat: String, CaseIterable, Sendable {
    case csv, tsv, json, sql, markdown, html

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .json: return "json"
        case .sql: return "sql"
        case .markdown: return "md"
        case .html: return "html"
        }
    }

    public var label: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .json: return "JSON"
        case .sql: return "SQL (INSERT statements)"
        case .markdown: return "Markdown table"
        case .html: return "HTML page"
        }
    }
}

extension Doc {
    /// Streams an entire table out in the requested format.
    public func export(table tableName: String, as format: ExportFormat) throws -> String {
        guard table(named: tableName) != nil else { throw SQLiteError.tableNotFound(tableName) }
        let cols = try columns(for: tableName)
        let colExpr = cols.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")
        let query = "SELECT \(colExpr) FROM \(Doc.quoteIdent(tableName))"

        switch format {
        case .csv, .tsv:
            let sep = format == .csv ? "," : "\t"
            var out = cols.map { escapeDelimited($0.name, sep: sep) }.joined(separator: sep) + "\n"
            try fg.queryStreaming(query) { _, row in
                out += row.map { format == .csv ? $0.csvText : tsvCell($0) }.joined(separator: sep) + "\n"
                return true
            }
            return out

        case .json:
            var items: [String] = []
            try fg.queryStreaming(query) { _, row in
                var obj: [String] = []
                for (i, c) in cols.enumerated() where i < row.count {
                    obj.append("\(jsonString(c.name)): \(jsonValue(row[i]))")
                }
                items.append("  { \(obj.joined(separator: ", ")) }")
                return true
            }
            return "[\n" + items.joined(separator: ",\n") + "\n]\n"

        case .sql:
            let q = Doc.quoteIdent(tableName)
            let colList = cols.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")
            var out = "BEGIN TRANSACTION;\n"
            try fg.queryStreaming(query) { _, row in
                let vals = row.map { sqlLiteral($0) }.joined(separator: ", ")
                out += "INSERT INTO \(q) (\(colList)) VALUES (\(vals));\n"
                return true
            }
            out += "COMMIT;\n"
            return out

        case .markdown:
            var out = "| " + cols.map { mdCell($0.name) }.joined(separator: " | ") + " |\n"
            out += "| " + cols.map { _ in "---" }.joined(separator: " | ") + " |\n"
            try fg.queryStreaming(query) { _, row in
                out += "| " + row.map { mdCell($0.displayText) }.joined(separator: " | ") + " |\n"
                return true
            }
            return out

        case .html:
            return try exportHTML(for: tableName)
        }
    }

    /// Backwards-compatible CSV entry point.
    public func exportCSV(for tableName: String) throws -> String {
        try export(table: tableName, as: .csv)
    }

    /// A self-contained HTML page: the whole table inlined, styled from the
    /// document's own `_style` / `_head`. Share it the way you'd share a web page.
    public func exportHTML(for tableName: String) throws -> String {
        let cols = try columns(for: tableName)
        let colExpr = cols.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")
        let s = style
        let pageTitle = s.title ?? tableName
        let accent = s.accent
        let dark = s.theme.lowercased() == "dark"
        let bg = s.bgColor ?? (dark ? "#16171a" : "#ffffff")
        let fg = s.textColor ?? (dark ? "#e8eaed" : "#202124")
        let rule = dark ? "#35373b" : "#e3e5e8"
        let head = dark ? "#292a2d" : "#f5f6f7"
        let font = s.fontFamily ?? "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"

        var body = "<tr>" + cols.map { "<th>\(htmlEscape($0.name))</th>" }.joined() + "</tr>\n"
        var count = 0
        try self.fg.queryStreaming("SELECT \(colExpr) FROM \(Doc.quoteIdent(tableName))") { _, row in
            count += 1
            body += "<tr>" + row.enumerated().map { i, v in
                let numeric = i < cols.count && cols[i].isNumeric
                return "<td class=\"\(numeric ? "num" : "")\">\(htmlEscape(v.displayText))</td>"
            }.joined() + "</tr>\n"
            return true
        }

        var extraHead = ""
        if let fav = s.favicon { extraHead += "<link rel=\"icon\" href=\"\(htmlEscape(fav))\">\n" }
        if let desc = s.description { extraHead += "<meta name=\"description\" content=\"\(htmlEscape(desc))\">\n" }
        if let author = s.author { extraHead += "<meta name=\"author\" content=\"\(htmlEscape(author))\">\n" }
        if let css = s.customCSS { extraHead += "<style>\(css)</style>\n" }

        return """
        <!doctype html>
        <html lang="en" data-theme="\(dark ? "dark" : "light")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="sqlswift">
        <title>\(htmlEscape(pageTitle))</title>
        \(extraHead)<style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          body { margin: 0; background: \(bg); color: \(fg); font-family: \(font); font-size: 13px; }
          header { padding: 20px 24px; border-bottom: 1px solid \(rule); }
          h1 { margin: 0; font-size: 18px; }
          .meta { color: \(dark ? "#9aa0a6" : "#5f6368"); font-size: 12px; margin-top: 4px; }
          .wrap { overflow-x: auto; }
          table { border-collapse: collapse; width: 100%; }
          th, td { padding: 5px 12px; border-bottom: 1px solid \(rule); text-align: left; white-space: nowrap; }
          th { position: sticky; top: 0; background: \(head); font-weight: 600; }
          td.num { text-align: right; font-variant-numeric: tabular-nums; }
          tr:hover td { background: \(accent)14; }
        </style>
        </head>
        <body>
        <header><h1>\(htmlEscape(pageTitle))</h1><div class="meta">\(htmlEscape(tableName)) · \(count) rows · exported by sqlswift</div></header>
        <div class="wrap"><table>
        \(body)</table></div>
        </body>
        </html>
        """
    }
}

// MARK: - Cell encoders

private func escapeDelimited(_ s: String, sep: String) -> String {
    if s.contains(sep) || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return s
}

private func tsvCell(_ v: SQLiteValue) -> String {
    switch v {
    case .null: return ""
    case .text(let s): return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    default: return v.displayText
    }
}

private func jsonString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s])
    if let data, let str = String(data: data, encoding: .utf8) {
        return String(str.dropFirst().dropLast()) // strip [ ]
    }
    return "\"\(s)\""
}

private func jsonValue(_ v: SQLiteValue) -> String {
    switch v {
    case .null: return "null"
    case .integer(let i): return "\(i)"
    case .real(let r): return r.isFinite ? "\(r)" : "null"
    case .text(let s): return jsonString(s)
    case .blob(let n): return jsonString("<BLOB \(n) bytes>")
    }
}

private func sqlLiteral(_ v: SQLiteValue) -> String {
    switch v {
    case .null: return "NULL"
    case .integer(let i): return "\(i)"
    case .real(let r): return r.isFinite ? "\(r)" : "NULL"
    case .text(let s): return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
    case .blob(let n): return "'<BLOB \(n) bytes>'"
    }
}

private func mdCell(_ s: String) -> String {
    s.replacingOccurrences(of: "|", with: "\\|")
     .replacingOccurrences(of: "\n", with: " ")
}

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}
