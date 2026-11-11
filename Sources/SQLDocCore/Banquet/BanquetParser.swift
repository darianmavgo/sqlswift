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
        while str.hasSuffix(";") {
            str = String(str.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        } else if let ampIdx = path.firstIndex(of: "&") {
            rawQuery = String(path[path.index(after: ampIdx)...])
            path = String(path[..<ampIdx])
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

        // Check if the entire input is a standalone SQL SELECT statement
        if let sqlParsed = parseEmbeddedSQLStatement(in: cleaned) {
            let extraQueryParams = parseExtraQueryParams(rawQuery)
            return Banquet(
                scheme: scheme,
                host: host,
                port: port,
                dataSetPath: "",
                isCollection: false,
                table: sqlParsed.table,
                select: sqlParsed.select,
                sortColumn: sqlParsed.sortColumn,
                isSortDesc: sqlParsed.isSortDesc,
                whereClause: sqlParsed.whereClause,
                limit: sqlParsed.limit,
                offset: sqlParsed.offset,
                groupBy: sqlParsed.groupBy,
                having: sqlParsed.having,
                extraQueryParams: extraQueryParams,
                rawQuery: rawQuery,
                rawURL: rawURL
            )
        }

        // Decompose path into DataSetPath, Table, and ColumnPath
        var (dataSetPath, isCollection, table, columnPath) = parseDataSetColumnPath(path)

        // If dataset was empty but host was parsed (and host has database extension), use host
        if dataSetPath.isEmpty, let h = host, knownExtensions.contains(where: { h.lowercased().hasSuffix($0) }) {
            dataSetPath = h
            host = nil
        }

        // Check if columnPath contains a pasted/edited SQL SELECT query (e.g. "daily_bars.db/daily_bar[0:100]/select count(*), min(date), max(date) from daily_bar where symbol='QQQ'")
        let fullColumnPath = rawQuery.isEmpty ? columnPath : "\(columnPath)?\(rawQuery)"
        if let (prefixPath, sqlPart) = splitPrefixAndSQL(fullColumnPath),
           let sqlParsed = parseEmbeddedSQLStatement(in: sqlPart) {
            var fallbackTable = table
            if fallbackTable.isEmpty {
                fallbackTable = parseTable(prefixPath)
            }
            if let bracketIdx = fallbackTable.firstIndex(of: "[") {
                fallbackTable = String(fallbackTable[..<bracketIdx])
            }
            let (sliceLimit, sliceOffset) = parseSlice(prefixPath)
            let finalTable = !sqlParsed.table.isEmpty ? sqlParsed.table : fallbackTable
            return Banquet(
                scheme: scheme,
                host: host,
                port: port,
                dataSetPath: dataSetPath,
                isCollection: false,
                table: finalTable,
                select: sqlParsed.select,
                sortColumn: sqlParsed.sortColumn,
                isSortDesc: sqlParsed.isSortDesc,
                whereClause: sqlParsed.whereClause,
                limit: sqlParsed.limit ?? sliceLimit,
                offset: sqlParsed.offset ?? sliceOffset,
                groupBy: sqlParsed.groupBy,
                having: sqlParsed.having,
                rawQuery: rawQuery,
                rawURL: rawURL
            )
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
        // Anything after `?` that isn't a reserved key is a WHERE condition.
        let bareWhere = parseBareConditions(rawQuery)
        let queryWhere = [parseWhere(rawQuery), bareWhere].filter { !$0.isEmpty }.joined(separator: " AND ")
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
        // Collections keep every unrecognised param (catalog search etc.); for tables
        // only operator-less ones remain — the rest became WHERE conditions above.
        let extraQueryParams = isCollection ? parseExtraQueryParams(rawQuery) : parseExtraQueryParams(rawQuery).filter { !isCondition($0) }

        return Banquet(
            scheme: scheme,
            host: host,
            port: port,
            dataSetPath: dataSetPath,
            isCollection: isCollection,
            table: table,
            select: select,
            sortColumn: sortCol,
            isSortDesc: isSortDesc,
            whereClause: whereClause,
            limit: limit,
            offset: offset,
            groupBy: groupBy,
            having: having,
            extraQueryParams: extraQueryParams,
            rawQuery: rawQuery,
            rawURL: rawURL
        )
    }

    // MARK: - Internal Decomposers

    private static func parseDataSetColumnPath(_ rawpath: String) -> (dataSetPath: String, isCollection: Bool, table: String, columnPath: String) {
        // Explicit semicolon delimiter notation: dataset;table;columns
        if rawpath.contains(";") {
            let parts = rawpath.components(separatedBy: ";")
            let dataSet = parts.first ?? ""
            let table = parts.count > 1 ? parts[1] : ""
            let columnPath = parts.count > 2 ? parts.dropFirst(2).joined(separator: ";") : ""
            return (dataSet, false, table, columnPath)
        }

        // Heuristic slash-delimited notation: path/to/file.ext/table/column
        let parts = rawpath.components(separatedBy: "/")
        for (i, part) in parts.enumerated() {
            let lower = part.lowercased()
            if knownExtensions.contains(where: { lower.hasSuffix($0) }) && lower != "test.html" {
                let datasetPath = parts[0...i].joined(separator: "/")
                let columnPath = (i + 1 < parts.count) ? parts[(i + 1)...].joined(separator: "/") : ""
                return (datasetPath, false, "", columnPath)
            }
        }

        // Collection notation: container path with no recognized extension
        var containerPath: [String] = []
        var catalogTable = ""
        var restPath: [String] = []
        var foundCatalogOrClause = false

        for part in parts {
            if foundCatalogOrClause {
                restPath.append(part)
                continue
            }

            let lower = part.lowercased()
            let isClauseLike = part.contains(",") || part.hasPrefix("+") || part.hasPrefix("-") || part.contains("!=") || part.contains("=") || (part.hasPrefix("[") && part.contains(":"))
            
            if lower == "databases" || lower == "tables" {
                catalogTable = lower
                foundCatalogOrClause = true
            } else if isClauseLike {
                catalogTable = "databases"
                restPath.append(part)
                foundCatalogOrClause = true
            } else {
                containerPath.append(part)
            }
        }

        let datasetPath = containerPath.joined(separator: "/")
        let columnPath = restPath.joined(separator: "/")
        if catalogTable.isEmpty && columnPath.isEmpty {
            catalogTable = "databases"
        }

        return (datasetPath, true, catalogTable, columnPath)
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

    /// `id>6000`, `+id>=6000`, `-age<30` → (column, operator, value). The column is
    /// a plain identifier; any sort marker is dropped. `=` / `!=` are handled by
    /// the equality rules, so only ordering comparisons are matched here.
    private static func splitComparison(_ token: String) -> (column: String, op: String, value: String)? {
        var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("+") || t.hasPrefix("-") { t.removeFirst() }
        guard let opIdx = t.firstIndex(where: { $0 == "<" || $0 == ">" }) else { return nil }
        let column = String(t[..<opIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !column.isEmpty,
              column.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        var rest = t[opIdx...]
        var op = String(rest.removeFirst())
        if rest.first == "=" { op.append("="); rest.removeFirst() }
        let value = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return (column, op, value)
    }

    private static func parseSelect(_ columnPath: String) -> [String] {
        let segments = getSegments(columnPath)
        guard !segments.isEmpty else { return ["*"] }

        var collected: [String] = []
        var markedSort: [(Int, String)] = []
        for segment in segments {
            guard !segment.isEmpty else { continue }
            let cols = splitTopLevelCommas(segment)
            for rawCol in cols {
                var col = rawCol.trimmingCharacters(in: .whitespacesAndNewlines)
                if let bracketIdx = col.firstIndex(of: "["), col.contains(":") {
                    col = String(col[..<bracketIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !col.isEmpty else { continue }
                if col.contains("!=") || col.contains("=") { continue }
                if let cmp = splitComparison(col) {
                    // `id>6000` filters; `+id>6000` also sorts and shows `id`.
                    if col.hasPrefix("+") || col.hasPrefix("-") { markedSort.append((collected.count, cmp.column)) }
                    continue
                }
                if col.hasPrefix("+") || col.hasPrefix("-") {
                    // A sort marker also names a shown column — but only alongside
                    // other columns; on its own (`-Open`) it is sort-only → `*`.
                    let name = String(col.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { markedSort.append((collected.count, name)) }
                    continue
                }
                collected.append(col)
            }
        }

        guard !collected.isEmpty else { return ["*"] }
        // Re-insert marked columns at their written position among the plain ones.
        for (idx, (pos, name)) in markedSort.enumerated() {
            collected.insert(name, at: min(pos + idx, collected.count))
        }
        return collected
    }

    private static func parsePathConditions(_ columnPath: String) -> String {
        let segments = getSegments(columnPath)
        guard !segments.isEmpty else { return "" }

        var conditions: [String] = []
        for segment in segments {
            guard !segment.isEmpty else { continue }
            let parts = splitTopLevelCommas(segment)
            for part in parts {
                if let cmp = splitComparison(part) {
                    var val = cmp.value
                    if let decoded = val.removingPercentEncoding { val = decoded }
                    if (val.hasPrefix("'") && val.hasSuffix("'")) || (val.hasPrefix("\"") && val.hasSuffix("\"")), val.count >= 2 {
                        val = String(val.dropFirst().dropLast())
                    }
                    if Double(val) == nil {
                        val = "'\(val.replacingOccurrences(of: "'", with: "''"))'"
                    }
                    conditions.append("\(cmp.column) \(cmp.op) \(val)")
                } else if part.contains("!=") {
                    let kv = part.components(separatedBy: "!=")
                    if kv.count == 2 {
                        let col = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        var val = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let decoded = val.removingPercentEncoding {
                            val = decoded
                        }
                        if (val.hasPrefix("'") && val.hasSuffix("'")) || (val.hasPrefix("\"") && val.hasSuffix("\"")), val.count >= 2 {
                            val = String(val.dropFirst().dropLast())
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
                        if (val.hasPrefix("'") && val.hasSuffix("'")) || (val.hasPrefix("\"") && val.hasSuffix("\"")), val.count >= 2 {
                            val = String(val.dropFirst().dropLast())
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
                if col.hasPrefix("+") || col.hasPrefix("-") {
                    let name = splitComparison(col)?.column ?? String(col.dropFirst())
                    return (name, col.hasPrefix("+") ? "ASC" : "DESC")
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

    private static let sqlFunctionNames: Set<String> = [
        "count", "min", "max", "sum", "avg", "total", "group_concat",
        "coalesce", "round", "abs", "cast", "strftime", "date", "datetime",
        "julianday", "unixepoch", "ifnull", "nullif", "typeof", "length",
        "lower", "upper", "substr", "trim", "ltrim", "rtrim", "replace"
    ]

    private static func parseGroupBy(path: String, query: String) -> String? {
        if let g = parseQueryParam("groupby", in: query) {
            return g
        }
        if let start = path.firstIndex(of: "("), let end = path.firstIndex(of: ")"), start < end {
            let inside = String(path[path.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if inside == "*" || inside.isEmpty {
                return nil
            }
            // Extract the identifier right before '(' to verify it isn't a SQL aggregate/scalar function
            let prefix = path[..<start]
            let ident = prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last.map { String($0).lowercased() } ?? ""
            if sqlFunctionNames.contains(ident) {
                return nil
            }
            return inside
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

    private static let standardQueryParamKeys: Set<String> = [
        "where", "filter", "limit", "offset", "sort", "orderby", "order", "groupby", "having"
    ]

    /// A non-reserved `?` param is a condition only if it has a comparison operator.
    private static func isCondition(_ param: String) -> Bool {
        let p = (param.removingPercentEncoding ?? param).lowercased()
        if p == "display=summary" { return false }   // view mode, not a filter
        return p.contains("=") || p.contains("<") || p.contains(">")
            || p.contains(" like ") || p.contains(" in ") || p.contains(" is ") || p.contains(" between ")
    }

    /// Non-reserved `?` params as SQL conditions, ANDed. `a=b` / `a!=b` get the same
    /// value quoting as path conditions; anything else (`id>6000`) passes through.
    private static func parseBareConditions(_ query: String) -> String {
        parseExtraQueryParams(query).filter(isCondition).compactMap { param -> String? in
            let decoded = param.removingPercentEncoding ?? param
            let isEquality = decoded.contains("!=") || (decoded.contains("=") && !decoded.contains(">=") && !decoded.contains("<="))
            if isEquality {
                let c = parsePathConditions(decoded)
                return c.isEmpty ? nil : c
            }
            return decoded
        }.joined(separator: " AND ")
    }

    private static func parseExtraQueryParams(_ query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        let params = query.components(separatedBy: "&")
        var extra: [String] = []
        for p in params {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let kv = trimmed.components(separatedBy: "=")
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !standardQueryParamKeys.contains(key) {
                extra.append(trimmed)
            }
        }
        return extra
    }

    // MARK: - SQL Statement & Expression Helpers

    private static func splitTopLevelCommas(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        for ch in input {
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(ch)
            } else if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(ch)
            } else if !inSingleQuote && !inDoubleQuote {
                if ch == "(" {
                    parenDepth += 1
                    current.append(ch)
                } else if ch == ")" {
                    parenDepth = max(0, parenDepth - 1)
                    current.append(ch)
                } else if ch == "," && parenDepth == 0 {
                    result.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func splitPrefixAndSQL(_ columnPath: String) -> (prefix: String, sql: String)? {
        let trimmed = columnPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("select ") {
            return ("", trimmed)
        }
        if let range = trimmed.range(of: "/select ", options: .caseInsensitive) {
            let prefix = String(trimmed[..<range.lowerBound])
            let sql = String(trimmed[trimmed.index(after: range.lowerBound)...])
            return (prefix, sql)
        }
        return nil
    }

    private struct ParsedSQLSelect {
        var select: [String]
        var table: String
        var whereClause: String?
        var groupBy: String?
        var having: String?
        var sortColumn: String?
        var isSortDesc: Bool
        var limit: Int?
        var offset: Int?
    }

    /// Parses a SQL `SELECT ...` statement into Banquet components so pasted SQL in the Banquet bar
    /// can be edited and executed seamlessly.
    private static func parseEmbeddedSQLStatement(in raw: String) -> ParsedSQLSelect? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard s.lowercased().hasPrefix("select ") else { return nil }
        let afterSelect = String(s.dropFirst("select ".count)).trimmingCharacters(in: .whitespacesAndNewlines)

        // Find top-level SQL clauses outside parentheses and quotes
        let clauseKeywords = ["FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "OFFSET"]
        let chars = Array(afterSelect)
        let upperChars = Array(afterSelect.uppercased())
        var parenDepth = 0
        var inSingle = false
        var inDouble = false

        var hits: [(keyword: String, start: Int, afterEnd: Int)] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" && !inDouble {
                inSingle.toggle()
                i += 1
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                i += 1
                continue
            }
            if !inSingle && !inDouble {
                if ch == "(" { parenDepth += 1; i += 1; continue }
                if ch == ")" { parenDepth = max(0, parenDepth - 1); i += 1; continue }
                if parenDepth == 0 {
                    let prevIsBoundary = (i == 0) || chars[i - 1].isWhitespace
                    if prevIsBoundary {
                        for kw in clauseKeywords {
                            let kwChars = Array(kw)
                            if i + kwChars.count <= upperChars.count,
                               Array(upperChars[i..<(i + kwChars.count)]) == kwChars {
                                let afterIdx = i + kwChars.count
                                let nextIsBoundary = (afterIdx == upperChars.count) || chars[afterIdx].isWhitespace
                                if nextIsBoundary {
                                    hits.append((kw, i, afterIdx))
                                    i = afterIdx
                                    break
                                }
                            }
                        }
                    }
                }
            }
            i += 1
        }

        let selectEnd = hits.first?.start ?? chars.count
        let selectRaw = String(chars[0..<selectEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let selectCols = splitTopLevelCommas(selectRaw)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var table = ""
        var whereClause: String?
        var groupBy: String?
        var having: String?
        var sortColumn: String?
        var isSortDesc = false
        var limit: Int?
        var offset: Int?

        for (idx, hit) in hits.enumerated() {
            let valueStart = hit.afterEnd
            let valueEnd = (idx + 1 < hits.count) ? hits[idx + 1].start : chars.count
            let val = String(chars[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch hit.keyword {
            case "FROM":
                table = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            case "WHERE":
                whereClause = val.isEmpty ? nil : val
            case "GROUP BY":
                groupBy = val.isEmpty ? nil : val
            case "HAVING":
                having = val.isEmpty ? nil : val
            case "ORDER BY":
                let parts = val.split(whereSeparator: \.isWhitespace).map(String.init)
                if let first = parts.first {
                    sortColumn = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                    if parts.count > 1 && parts[1].uppercased() == "DESC" {
                        isSortDesc = true
                    }
                }
            case "LIMIT":
                limit = Int(val.split(whereSeparator: \.isWhitespace).first ?? "")
            case "OFFSET":
                offset = Int(val.split(whereSeparator: \.isWhitespace).first ?? "")
            default:
                break
            }
        }

        return ParsedSQLSelect(
            select: selectCols.isEmpty ? ["*"] : selectCols,
            table: table,
            whereClause: whereClause,
            groupBy: groupBy,
            having: having,
            sortColumn: sortColumn,
            isSortDesc: isSortDesc,
            limit: limit,
            offset: offset
        )
    }
}
