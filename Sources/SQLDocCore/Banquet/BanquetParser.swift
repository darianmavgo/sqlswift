import Foundation

/// Parser conforming to the Banquet URL Specification.
/// Converts raw URL strings into structured `Banquet` queries.
public enum BanquetParser {

    private static let knownExtensions: [String] = [
        ".sqlite3", ".sqlite", ".db", ".csv", ".tsv", ".json", ".xlsx", ".xls", ".txt", ".zip", ".html"
    ]

    /// Cleans and standardizes raw URL strings before parsing.
    public static func cleanURL(_ rawURL: String) -> String {
        var str = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if str == "/" { return "." }
        if str.hasPrefix("/") {
            str = String(str.dropFirst())
        }

        // Fix single-slash scheme formatting (e.g. "gs:/path" -> "gs://path", "http:/domain" -> "http://domain")
        if let regex = try? NSRegularExpression(pattern: "(?<!:):/(?!/)") {
            let range = NSRange(location: 0, length: str.utf16.count)
            str = regex.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "://")
        }

        // Guard against colon in first path segment when no scheme is present
        if !str.contains("://") && str.contains(":") {
            let slashIdx = str.firstIndex(of: "/")
            let colonIdx = str.firstIndex(of: ":")
            if let colon = colonIdx {
                if let slash = slashIdx {
                    if colon < slash {
                        str = "./" + str
                    }
                } else {
                    str = "./" + str
                }
            }
        }

        return str
    }

    /// Parses a raw URL or path into a structured `Banquet` instance.
    public static func parse(_ rawURL: String) throws -> Banquet {
        let cleaned = cleanURL(rawURL)

        // Handle nested URLs (e.g. "http://localhost:8080/gs://bucket/file.db;table")
        if let lastSchemeRange = cleaned.range(of: "://", options: .backwards),
           let firstSchemeRange = cleaned.range(of: "://"),
           firstSchemeRange != lastSchemeRange {
            let prefix = cleaned[..<lastSchemeRange.lowerBound]
            if let slashBeforeInner = prefix.lastIndex(of: "/") {
                let fullInner = String(cleaned[cleaned.index(after: slashBeforeInner)...])
                return try parseDirect(fullInner)
            }
        }

        return try parseDirect(cleaned)
    }

    private static func parseDirect(_ rawURL: String) throws -> Banquet {
        let cleaned = cleanURL(rawURL)

        var scheme: String?
        var host: String?
        var port: String?
        var path = cleaned
        var rawQuery = ""

        // Separate query string if present
        if let queryIdx = path.firstIndex(of: "?") {
            rawQuery = String(path[path.index(after: queryIdx)...])
            path = String(path[..<queryIdx])
        }

        // Separate scheme and host if standard URL format
        if let schemeRange = path.range(of: "://") {
            scheme = String(path[..<schemeRange.lowerBound])
            let afterScheme = String(path[schemeRange.upperBound...])
            if let slashIdx = afterScheme.firstIndex(of: "/") {
                let hostPort = String(afterScheme[..<slashIdx])
                path = String(afterScheme[slashIdx...])
                if let colonIdx = hostPort.firstIndex(of: ":") {
                    host = String(hostPort[..<colonIdx])
                    port = String(hostPort[hostPort.index(after: colonIdx)...])
                } else {
                    host = hostPort
                }
            } else {
                host = afterScheme
                path = ""
            }
        }

        // Clean leading slash from path for parsing
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        // Decompose path into DataSetPath, Table, and ColumnPath
        var (dataSetPath, table, columnPath) = parseDataSetColumnPath(path)

        // If dataset was empty but host was parsed (and host has database extension), use host
        if dataSetPath.isEmpty, let h = host, knownExtensions.contains(where: { h.lowercased().hasSuffix($0) }) {
            dataSetPath = h
            host = nil
        }

        // Heuristic table deduction if not explicit
        if table.isEmpty {
            table = parseTable(columnPath)
        }

        // Clean table from trailing slice notation
        if let bracketIdx = table.firstIndex(of: "[") {
            table = String(table[..<bracketIdx])
        }

        // Columns
        var select = parseSelect(columnPath)
        if select.count == 1 && select[0] == table {
            select = ["*"]
        }

        // Conditions & WHERE
        let queryWhere = parseWhere(rawQuery)
        let pathWhere = parsePathConditions(columnPath)
        var whereClause: String? = nil
        if !pathWhere.isEmpty && !queryWhere.isEmpty {
            whereClause = "\(queryWhere) AND \(pathWhere)"
        } else if !pathWhere.isEmpty {
            whereClause = pathWhere
        } else if !queryWhere.isEmpty {
            whereClause = queryWhere
        }

        // Sort
        let (sortCol, sortDir) = parseOrderBy(columnPath: columnPath, query: rawQuery)
        let isSortDesc = (sortDir.uppercased() == "DESC")

        // Limit & Offset (from slice notation or query params)
        let (sliceLimit, sliceOffset) = parseSlice(path)
        let queryLimit = parseQueryParam("limit", in: rawQuery).flatMap { Int($0) }
        let queryOffset = parseQueryParam("offset", in: rawQuery).flatMap { Int($0) }

        let limit = queryLimit ?? sliceLimit
        let offset = queryOffset ?? sliceOffset

        // GroupBy & Having
        let groupBy = parseGroupBy(path: path, query: rawQuery)
        let having = parseHaving(rawQuery)

        return Banquet(
            scheme: scheme,
            host: host,
            port: port,
            dataSetPath: dataSetPath,
            table: table,
            select: select,
            sortColumn: sortCol,
            isSortDesc: isSortDesc,
            whereClause: whereClause,
            limit: limit,
            offset: offset,
            groupBy: groupBy,
            having: having,
            rawQuery: rawQuery,
            rawURL: rawURL
        )
    }

    // MARK: - Internal Decomposers

    private static func parseDataSetColumnPath(_ rawpath: String) -> (dataSetPath: String, table: String, columnPath: String) {
        // Explicit semicolon delimiter notation: dataset;table;columns
        if rawpath.contains(";") {
            let parts = rawpath.components(separatedBy: ";")
            let dataSet = parts.first ?? ""
            let table = parts.count > 1 ? parts[1] : ""
            let columnPath = parts.count > 2 ? parts.dropFirst(2).joined(separator: ";") : ""
            return (dataSet, table, columnPath)
        }

        // Heuristic slash-delimited notation: path/to/file.ext/table/column
        let parts = rawpath.components(separatedBy: "/")
        for (i, part) in parts.enumerated() {
            let lower = part.lowercased()
            if knownExtensions.contains(where: { lower.hasSuffix($0) }) && lower != "test.html" {
                let datasetPath = parts[0...i].joined(separator: "/")
                let columnPath = (i + 1 < parts.count) ? parts[(i + 1)...].joined(separator: "/") : ""
                return (datasetPath, "", columnPath)
            }
        }

        return (rawpath, "", "")
    }

    private static func getSegments(_ columnPath: String) -> [String] {
        guard !columnPath.isEmpty else { return [] }
        let parts = columnPath.components(separatedBy: "/")
        if parts.isEmpty || (parts.count == 1 && parts[0].isEmpty) {
            return []
        }

        for (i, part) in parts.enumerated() {
            if part.contains(",") ||
                part.hasPrefix("+") ||
                part.hasPrefix("-") ||
                part.contains("!=") ||
                part.contains("=") ||
                (part.hasPrefix("[") && part.contains(":")) {
                return Array(parts[i...])
            }
        }

        return [parts.last!]
    }

    private static func parseTable(_ columnPath: String) -> String {
        guard !columnPath.isEmpty else { return "" }
        let trimmed = columnPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.components(separatedBy: "/")
        guard let first = parts.first, !first.isEmpty else { return "" }

        // If segment has clear selector/filter/sort clues, it's not a table name
        if first.contains(",") ||
            first.hasPrefix("+") ||
            first.hasPrefix("-") ||
            first.contains("!=") ||
            first.contains("=") ||
            first.contains(">") ||
            first.contains("<") ||
            (first.hasPrefix("[") && first.contains(":")) {
            return ""
        }

        return first
    }

    private static func parseSelect(_ columnPath: String) -> [String] {
        let segments = getSegments(columnPath)
        guard !segments.isEmpty else { return ["*"] }

        var collected: [String] = []
        for segment in segments {
            guard !segment.isEmpty else { continue }
            let cols = segment.components(separatedBy: ",")
            for rawCol in cols {
                var col = rawCol.trimmingCharacters(in: .whitespacesAndNewlines)
                if let bracketIdx = col.firstIndex(of: "["), col.contains(":") {
                    col = String(col[..<bracketIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !col.isEmpty else { continue }
                if col.contains("!=") || col.contains("=") { continue }
                if col.hasPrefix("+") || col.hasPrefix("-") { continue }
                collected.append(col)
            }
        }

        return collected.isEmpty ? ["*"] : collected
    }

    private static func parsePathConditions(_ columnPath: String) -> String {
        let segments = getSegments(columnPath)
        guard !segments.isEmpty else { return "" }

        var conditions: [String] = []
        for segment in segments {
            guard !segment.isEmpty else { continue }
            let parts = segment.components(separatedBy: ",")
            for part in parts {
                if part.contains("!=") {
                    let kv = part.components(separatedBy: "!=")
                    if kv.count == 2 {
                        let col = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        var val = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let decoded = val.removingPercentEncoding {
                            val = decoded
                        }
                        if Double(val) == nil {
                            let escaped = val.replacingOccurrences(of: "'", with: "''")
                            val = "'\(escaped)'"
                        }
                        conditions.append("\(col) != \(val)")
                    }
                } else if part.contains("=") && !part.contains(">=") && !part.contains("<=") {
                    let kv = part.components(separatedBy: "=")
                    if kv.count == 2 {
                        let col = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        var val = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let decoded = val.removingPercentEncoding {
                            val = decoded
                        }
                        if Double(val) == nil {
                            let escaped = val.replacingOccurrences(of: "'", with: "''")
                            val = "'\(escaped)'"
                        }
                        conditions.append("\(col) = \(val)")
                    }
                }
            }
        }

        return conditions.joined(separator: " AND ")
    }

    private static func parseWhere(_ query: String) -> String {
        guard !query.isEmpty else { return "" }
        if let whereVal = parseQueryParam("where", in: query) {
            return whereVal
        }
        if let filterVal = parseQueryParam("filter", in: query) {
            return filterVal
        }
        return ""
    }

    private static func parseOrderBy(columnPath: String, query: String) -> (column: String?, direction: String) {
        if let ob = parseQueryParam("orderby", in: query) ?? parseQueryParam("sort", in: query) {
            let dir = parseQueryParam("order", in: query)?.uppercased() == "DESC" ? "DESC" : "ASC"
            return (ob, dir)
        }

        let parts = columnPath.components(separatedBy: "/")
        for part in parts {
            let cols = part.components(separatedBy: ",")
            for rawCol in cols {
                var col = rawCol.trimmingCharacters(in: .whitespacesAndNewlines)
                if let bracketIdx = col.firstIndex(of: "[") {
                    col = String(col[..<bracketIdx])
                }
                if col.hasPrefix("+") {
                    return (String(col.dropFirst()), "ASC")
                }
                if col.hasPrefix("-") {
                    return (String(col.dropFirst()), "DESC")
                }
            }
        }

        return (nil, "")
    }

    private static func parseSlice(_ pathStr: String) -> (limit: Int?, offset: Int?) {
        guard let startBracket = pathStr.lastIndex(of: "["),
              let endBracket = pathStr.range(of: "]", range: startBracket..<pathStr.endIndex)?.lowerBound else {
            return (nil, nil)
        }

        let content = String(pathStr[pathStr.index(after: startBracket)..<endBracket])
        guard content.contains(":") else { return (nil, nil) }

        let parts = content.components(separatedBy: ":")
        guard parts.count == 2 else { return (nil, nil) }

        let startStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let endStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        let start = Int(startStr) ?? 0
        let offset = start

        if let end = Int(endStr) {
            let limit = max(0, end - start)
            return (limit, offset)
        }

        return (nil, offset > 0 ? offset : nil)
    }

    private static func parseGroupBy(path: String, query: String) -> String? {
        if let g = parseQueryParam("groupby", in: query) {
            return g
        }
        if let start = path.firstIndex(of: "("), let end = path.firstIndex(of: ")"), start < end {
            return String(path[path.index(after: start)..<end])
        }
        return nil
    }

    private static func parseHaving(_ query: String) -> String? {
        parseQueryParam("having", in: query)
    }

    private static func parseQueryParam(_ name: String, in query: String) -> String? {
        guard !query.isEmpty else { return nil }
        let params = query.components(separatedBy: "&")
        for p in params {
            let kv = p.components(separatedBy: "=")
            if kv.count >= 2, kv[0].lowercased() == name.lowercased() {
                let val = kv.dropFirst().joined(separator: "=")
                return val.removingPercentEncoding ?? val
            }
        }
        return nil
    }
}
