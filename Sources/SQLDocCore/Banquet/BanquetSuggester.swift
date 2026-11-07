import Foundation

/// One row of the Banquet bar's suggestion dropdown.
public struct BanquetSuggestion: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case keyword, table, column, openDoc, recent, history
    }

    public var id: String { kind.rawValue + "|" + completion }
    public let kind: Kind
    /// Main line shown in the row.
    public let display: String
    /// Secondary, dimmer line (path, "table", …).
    public let detail: String
    /// What replaces the bar's text when the row is accepted.
    public let completion: String
    /// Only history rows can be forgotten (Shift+fn+Delete).
    public var removable: Bool { kind == .history }

    public init(kind: Kind, display: String, detail: String = "", completion: String) {
        self.kind = kind
        self.display = display
        self.detail = detail
        self.completion = completion
    }
}

/// Everything the suggester may look at. Plain values, so it can be built from
/// whatever the app has already loaded — suggesting never touches a database.
public struct BanquetSuggestContext: Sendable {
    public struct File: Sendable, Equatable {
        public let path: String
        public let name: String
        public init(path: String, name: String) { self.path = path; self.name = name }
    }

    public var history: [String]
    public var recents: [File]
    public var openDocs: [File]
    public var activeDocPath: String?
    public var tables: [String]
    public var activeTable: String?
    public var columns: [String]

    public init(
        history: [String] = [], recents: [File] = [], openDocs: [File] = [],
        activeDocPath: String? = nil, tables: [String] = [],
        activeTable: String? = nil, columns: [String] = []
    ) {
        self.history = history
        self.recents = recents
        self.openDocs = openDocs
        self.activeDocPath = activeDocPath
        self.tables = tables
        self.activeTable = activeTable
        self.columns = columns
    }
}

/// Omnibox-style suggestions for the Banquet bar. Pure and synchronous.
///
/// Plain text is matched against tables, columns, open documents, recent files
/// and URL history. Text starting with `@` is a site-search-style keyword
/// (Chrome's `@tabs` / `@bookmarks` / `@history`): `@tables`, `@open`,
/// `@recent`, `@history`, each followed by an optional filter. Keywords are
/// resolved here only; `BanquetParser` never sees them.
public enum BanquetSuggester {
    public static let keywords: [(name: String, help: String)] = [
        ("@tables", "Tables in the open database"),
        ("@open", "Documents open now"),
        ("@recent", "Recently opened databases"),
        ("@history", "Banquet URLs you have used"),
    ]

    public static func suggestions(
        for text: String,
        context: BanquetSuggestContext,
        limit: Int = BehaviorConfig.omniboxSuggestionsMax
    ) -> [BanquetSuggestion] {
        guard limit > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("@") {
            // The space after the keyword is meaningful ("@tables " = list them all), so
            // only leading whitespace is dropped here.
            let kw = String(text.drop(while: { $0.isWhitespace }))
            return Array(keywordSuggestions(kw, context).prefix(limit))
        }
        if trimmed.isEmpty {
            // Down-arrow on an empty bar: what you used last.
            return Array(unique(historyRows(context, query: "") + recentRows(context, query: "")).prefix(limit))
        }
        let q = trimmed.lowercased()
        var scored: [(Int, Int, BanquetSuggestion)] = []   // (score, kind priority, row)
        func add(_ row: BanquetSuggestion, _ score: Int?, _ priority: Int) {
            if let score { scored.append((score, priority, row)) }
        }

        for row in columnRows(trimmed, context) { add(row.0, row.1, 0) }
        for t in context.tables {
            add(tableRow(t, context), match(q, t.lowercased()), 1)
        }
        for f in context.openDocs {
            add(.init(kind: .openDoc, display: f.name, detail: f.path, completion: f.path),
                best(q, f.name.lowercased(), f.path.lowercased()), 2)
        }
        for f in context.recents {
            add(.init(kind: .recent, display: f.name, detail: f.path, completion: f.path),
                best(q, f.name.lowercased(), f.path.lowercased()), 3)
        }
        for u in context.history where u != trimmed {
            add(.init(kind: .history, display: u, completion: u), best(q, u.lowercased(), lastComponent(u)), 4)
        }
        // Stable: better match first, then kind priority; array order (recency) breaks the rest.
        let ordered = scored.enumerated()
            .sorted { a, b in
                if a.element.0 != b.element.0 { return a.element.0 < b.element.0 }
                if a.element.1 != b.element.1 { return a.element.1 < b.element.1 }
                return a.offset < b.offset
            }
            .map { $0.element.2 }
        return Array(unique(ordered).prefix(limit))
    }

    // MARK: - Keywords

    private static func keywordSuggestions(_ text: String, _ c: BanquetSuggestContext) -> [BanquetSuggestion] {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let word = (parts.first.map(String.init) ?? "@").lowercased()
        let hasSpace = text.contains(" ")
        let query = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased() : ""

        guard hasSpace, let known = keywords.first(where: { $0.name == word }) else {
            // Still typing the keyword itself: offer the keywords.
            return keywords
                .filter { $0.name.hasPrefix(word) }
                .map { .init(kind: .keyword, display: $0.name, detail: $0.help, completion: $0.name + " ") }
        }
        switch known.name {
        case "@tables":
            return c.tables.filter { query.isEmpty || match(query, $0.lowercased()) != nil }
                .map { tableRow($0, c) }
        case "@open":
            return c.openDocs.filter { query.isEmpty || best(query, $0.name.lowercased(), $0.path.lowercased()) != nil }
                .map { .init(kind: .openDoc, display: $0.name, detail: $0.path, completion: $0.path) }
        case "@recent":
            return recentRows(c, query: query)
        default:
            return historyRows(c, query: query)
        }
    }

    // MARK: - Rows

    private static func tableRow(_ table: String, _ c: BanquetSuggestContext) -> BanquetSuggestion {
        let completion = c.activeDocPath.map { $0 + "/" + table } ?? table
        return .init(kind: .table, display: table, detail: "table", completion: completion)
    }

    private static func historyRows(_ c: BanquetSuggestContext, query: String) -> [BanquetSuggestion] {
        c.history.filter { query.isEmpty || $0.lowercased().contains(query) }
            .map { .init(kind: .history, display: $0, completion: $0) }
    }

    private static func recentRows(_ c: BanquetSuggestContext, query: String) -> [BanquetSuggestion] {
        c.recents.filter { query.isEmpty || best(query, $0.name.lowercased(), $0.path.lowercased()) != nil }
            .map { .init(kind: .recent, display: $0.name, detail: $0.path, completion: $0.path) }
    }

    /// Column completion for the last path segment: `db/table/na` → `db/table/name`.
    /// Only offered when the text already names the active table.
    private static func columnRows(_ text: String, _ c: BanquetSuggestContext) -> [(BanquetSuggestion, Int?)] {
        guard let table = c.activeTable?.lowercased(), !c.columns.isEmpty else { return [] }
        let segments = text.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              segments.dropLast().contains(where: { $0.lowercased().hasPrefix(table) || $0.lowercased() == table })
        else { return [] }
        // The fragment after the last separator (/ or ,), minus a leading sort marker.
        guard let cut = text.lastIndex(where: { $0 == "/" || $0 == "," }) else { return [] }
        var head = String(text[...cut])
        var fragment = String(text[text.index(after: cut)...])
        if let first = fragment.first, first == "+" || first == "-" {
            head.append(first)
            fragment.removeFirst()
        }
        guard !fragment.isEmpty, !fragment.contains("["), !fragment.contains("?") else { return [] }
        let f = fragment.lowercased()
        return c.columns.compactMap { col in
            guard let s = match(f, col.lowercased()), col.lowercased() != f else { return nil }
            return (.init(kind: .column, display: col, detail: "column", completion: head + col), s)
        }
    }

    // MARK: - Matching

    /// 0 = prefix, 1 = prefix of a word after `/ . _ - space`, 2 = substring, nil = no match.
    static func match(_ q: String, _ candidate: String) -> Int? {
        guard !q.isEmpty else { return 0 }
        if candidate.hasPrefix(q) { return 0 }
        guard let r = candidate.range(of: q) else { return nil }
        if r.lowerBound > candidate.startIndex {
            let before = candidate[candidate.index(before: r.lowerBound)]
            if "/._- ".contains(before) { return 1 }
        }
        return 2
    }

    private static func best(_ q: String, _ candidates: String...) -> Int? {
        candidates.compactMap { match(q, $0) }.min()
    }

    private static func lastComponent(_ url: String) -> String {
        url.split(separator: "/").last.map { String($0).lowercased() } ?? url.lowercased()
    }

    private static func unique(_ rows: [BanquetSuggestion]) -> [BanquetSuggestion] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.completion).inserted }
    }
}
