import Foundation
import SQLite3

/// Options controls how a document is opened.
public struct DocOptions: Sendable {
    /// Promises SQLite that the file will not change while open.
    /// Skips locking and WAL recovery entirely for the fastest cold start.
    public var isImmutable: Bool

    public init(isImmutable: Bool = false) {
        self.isImmutable = isImmutable
    }
}

/// TableState holds per-table facts that cost a query to learn.
/// Loaded on-demand on first access.
public final class TableState: @unchecked Sendable {
    public let name: String
    public let quoted: String
    private let lock = NSRecursiveLock()

    private var _cols: [Column]?
    private var _colExpr: String?
    private var _minID: Int64?
    private var _maxID: Int64?
    private var _hasBounds: Bool = false
    private var _boundsChecked: Bool = false

    public init(name: String) {
        self.name = name
        self.quoted = Doc.quoteIdent(name)
    }

    public func getColumns(loader: () throws -> [Column]) throws -> (cols: [Column], colExpr: String) {
        lock.lock()
        defer { lock.unlock() }
        if let cols = _cols, let expr = _colExpr {
            return (cols, expr)
        }
        let cols = try loader()
        let expr = cols.map { Doc.quoteIdent($0.name) }.joined(separator: ", ")
        self._cols = cols
        self._colExpr = expr
        return (cols, expr)
    }

    public func getBounds(loader: () -> (min: Int64, max: Int64, ok: Bool)) -> (min: Int64, max: Int64, ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if _boundsChecked {
            return (_minID ?? 0, _maxID ?? 0, _hasBounds)
        }
        let res = loader()
        self._boundsChecked = true
        self._hasBounds = res.ok
        if res.ok {
            self._minID = res.min
            self._maxID = res.max
        }
        return res
    }
}

/// Doc is an open, read-only SQLite document.
/// Everything is built around one rule: never do work proportional to database size before first paint.
public final class Doc: @unchecked Sendable {
    public let path: String
    public let size: Int64
    public let modified: Date
    public let options: DocOptions

    public let fg: SQLiteConnection

    // The background connection is only needed once work that isn't first paint
    // starts (exact counts, column sampling, find). Opening it — with its mmap and
    // cache pragmas — is deferred off the open path.
    private let bgLock = NSLock()
    private var _bg: SQLiteConnection?
    public var bg: SQLiteConnection {
        bgLock.lock()
        defer { bgLock.unlock() }
        if let existing = _bg { return existing }
        if let opened = try? SQLiteConnection(path: path, readOnly: true, immutable: options.isImmutable) {
            _bg = opened
            return opened
        }
        // Degrade to sharing the foreground connection rather than crashing.
        return fg
    }

    private let stateLock = NSLock()
    private var states: [String: TableState] = [:]
    private var _tables: [Table] = []
    private var _style: Style = .default

    // Idle tracking: background work waits for a 300ms lull in foreground reads
    private var lastReadNano: UInt64 = DispatchTime.now().uptimeNanoseconds
    private static let idleGraceNano: UInt64 = 300_000_000 // 300ms

    // Background workers
    public let counterWorker: CounterWorker
    public let columnSampler: ColumnSampler
    public let finder: Finder

    public static func quoteIdent(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    public static func open(path: String, options: DocOptions = DocOptions()) throws -> Doc {
        let expanded = (path as NSString).expandingTildeInPath
        let resolvedPath: String
        if (expanded as NSString).isAbsolutePath {
            resolvedPath = URL(fileURLWithPath: expanded).standardized.path
        } else {
            let currentDir = FileManager.default.currentDirectoryPath
            resolvedPath = URL(fileURLWithPath: (currentDir as NSString).appendingPathComponent(expanded)).standardized.path
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), !isDir.boolValue else {
            throw SQLiteError.notADatabase(path: resolvedPath)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: resolvedPath)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date()

        let fg = try SQLiteConnection(path: resolvedPath, readOnly: true, immutable: options.isImmutable)

        // Verify valid SQLite header via cheap pragma
        guard let _ = try? fg.queryRow("PRAGMA journal_mode") else {
            fg.close()
            throw SQLiteError.notADatabase(path: resolvedPath)
        }

        let doc = Doc(path: resolvedPath, size: size, modified: modified, options: options, fg: fg)
        try doc.discover()
        doc.loadStyle()
        return doc
    }

    private init(
        path: String,
        size: Int64,
        modified: Date,
        options: DocOptions,
        fg: SQLiteConnection
    ) {
        self.path = path
        self.size = size
        self.modified = modified
        self.options = options
        self.fg = fg

        self.counterWorker = CounterWorker()
        self.columnSampler = ColumnSampler()
        self.finder = Finder()
    }

    deinit {
        close()
    }

    public func close() {
        fg.close()
        bgLock.lock()
        _bg?.close()
        _bg = nil
        bgLock.unlock()
    }

    public func touch() {
        stateLock.lock()
        lastReadNano = DispatchTime.now().uptimeNanoseconds
        stateLock.unlock()
    }

    private func getElapsedIdleNanos() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= lastReadNano ? now - lastReadNano : 0
    }

    public func waitIdle() async {
        while true {
            let elapsed = getElapsedIdleNanos()
            if elapsed >= Doc.idleGraceNano {
                return
            }
            let remainingNanos = Doc.idleGraceNano - elapsed
            try? await Task.sleep(nanoseconds: remainingNanos)
        }
    }

    public var tables: [Table] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _tables
    }

    public var style: Style {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _style
    }

    public func table(named name: String) -> Table? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _tables.first { $0.name.lowercased() == name.lowercased() }
    }

    public func tableState(for name: String) -> TableState {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = states[name] {
            return existing
        }
        let ts = TableState(name: name)
        states[name] = ts
        return ts
    }

    // MARK: - Schema Discovery

    /// Reads every table and view in a single scan of sqlite_master.
    private func discover() throws {
        let sql = """
            SELECT name, type, COALESCE(sql, '')
            FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
        """
        let rows = try fg.query(sql)
        var list: [Table] = []

        for row in rows {
            guard row.count >= 3,
                  let name = row[0].textValue,
                  let type = row[1].textValue else { continue }
            let ddl = row[2].textValue ?? ""
            let isWithoutRowID = ddl.uppercased().contains("WITHOUT ROWID")
            let hasRowID = (type.lowercased() == "table") && !isWithoutRowID

            let t = Table(name: name, type: type, hasRowID: hasRowID)
            list.append(t)
        }

        self._tables = applyNav(list)
    }

    /// Applies optional _nav table overrides for labels, order, and visibility.
    private func applyNav(_ rawTables: [Table]) -> [Table] {
        struct Override {
            var label: String = ""
            var pos: Int = 0
            var hidden: Bool = false
            var set: Bool = false
        }
        var overrides: [String: Override] = [:]

        if rawTables.contains(where: { $0.name == "_nav" }) {
            if let rows = try? fg.query("SELECT table_name, COALESCE(label,''), COALESCE(position,0), COALESCE(hidden,0) FROM _nav") {
                for r in rows where r.count >= 4 {
                    if let name = r[0].textValue {
                        let label = r[1].textValue ?? ""
                        let pos = Int(r[2].intValue ?? 0)
                        let hidden = (r[3].intValue ?? 0) != 0
                        overrides[name] = Override(label: label, pos: pos, hidden: hidden, set: true)
                    }
                }
            }
        }

        var result: [Table] = []
        var posMap: [String: Int] = [:]

        for var t in rawTables {
            if let ov = overrides[t.name], ov.set {
                if !ov.label.isEmpty {
                    t.label = ov.label
                }
                t.hidden = t.hidden || ov.hidden
                posMap[t.name] = ov.pos
            } else {
                posMap[t.name] = 1 << 20
            }
            result.append(t)
        }

        result.sort { a, b in
            if a.hidden != b.hidden {
                return !a.hidden
            }
            let posA = posMap[a.name] ?? (1 << 20)
            let posB = posMap[b.name] ?? (1 << 20)
            if posA != posB {
                return posA < posB
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        return result
    }

    /// Reads optional _style or _head key-value tables.
    private func loadStyle() {
        var s = Style.default
        let styleTables = ["_style", "_head"]

        for tbl in styleTables {
            guard _tables.contains(where: { $0.name == tbl }) else { continue }
            if let rows = try? fg.query("SELECT key, COALESCE(value, '') FROM \(Doc.quoteIdent(tbl))") {
                for r in rows where r.count >= 2 {
                    guard let key = r[0].textValue?.lowercased(),
                          let val = r[1].textValue, !val.isEmpty else { continue }
                    switch key {
                    case "title":
                        s.title = val
                    case "accent", "accent_color", "accentcolor":
                        s.accent = val
                    case "theme", "dark_mode", "darkmode", "color_scheme":
                        s.theme = val
                    case "favicon", "icon", "shortcut_icon":
                        s.favicon = val
                    case "description":
                        s.description = val
                    case "author":
                        s.author = val
                    case "font_family", "font":
                        s.fontFamily = val
                    case "bg_color", "bg", "background":
                        s.bgColor = val
                    case "text_color", "text", "ink":
                        s.textColor = val
                    case "custom_css", "css":
                        s.customCSS = (s.customCSS ?? "") + "\n" + val
                    case "page_size", "pagesize":
                        if let n = Int(val), n > 0 { s.pageSize = n }
                    default:
                        break
                    }
                }
            }
        }
        self._style = s
    }

    // MARK: - Column Introspection

    public func columns(for tableName: String) throws -> [Column] {
        let ts = tableState(for: tableName)
        let (cols, _) = try ts.getColumns {
            let sql = "PRAGMA table_info(\(ts.quoted))"
            let rows = try fg.query(sql)
            var result: [Column] = []
            for r in rows where r.count >= 6 {
                let name = r[1].textValue ?? ""
                let type = r[2].textValue ?? ""
                let notNull = (r[3].intValue ?? 0) != 0
                let pk = (r[5].intValue ?? 0) != 0
                result.append(Column(name: name, type: type, notNull: notNull, pk: pk))
            }
            return result
        }
        return cols
    }

    // MARK: - Bounds Calculation

    /// Returns min and max rowid in O(1) index seeks using two scalar subqueries.
    /// Pass `using:` a background connection when calling off the main thread so
    /// the first-paint foreground connection isn't contended.
    public func bounds(for tableName: String, using conn: SQLiteConnection? = nil) -> (min: Int64, max: Int64, ok: Bool) {
        let ts = tableState(for: tableName)
        let connection = conn ?? fg
        return ts.getBounds {
            let q = "SELECT (SELECT min(rowid) FROM \(ts.quoted)), (SELECT max(rowid) FROM \(ts.quoted))"
            guard let row = try? connection.queryRow(q), row.count >= 2,
                  let minVal = row[0].intValue,
                  let maxVal = row[1].intValue else {
                return (0, 0, false)
            }
            return (minVal, maxVal, true)
        }
    }

    /// Computes the exact row position (ordinal) of a rowid within the table.
    public func ordinal(for tableName: String, rowID: Int64) -> Int64 {
        guard let t = table(named: tableName), t.hasRowID else { return 0 }
        let (lo, hi, ok) = bounds(for: tableName, using: bg)
        guard ok else { return 0 }

        let count = count(for: tableName)
        if count.known && count.exact && count.rows == (hi - lo + 1) {
            return max(0, rowID - lo)
        }

        let q = "SELECT COUNT(*) FROM \(Doc.quoteIdent(tableName)) WHERE rowid < ?"
        if let row = try? bg.queryRow(q, args: [rowID]), let n = row.first?.intValue {
            return n
        }
        return 0
    }
}
