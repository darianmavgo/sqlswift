import Foundation
import SQLDocCore

/// Read access to a filestudio database that another process (the Go worker) is writing.
///
/// Two read-only connections by role, never `immutable` (an immutable connection would never see
/// the worker's commits): `fast` for the small snapshot queries the UI shows several times a
/// second, `slow` for heavy views (v_reclaim_ready scans every local file) so they can never
/// hold up a progress update. `changeCounter()` is `PRAGMA data_version`, which moves whenever
/// another connection commits: checking it costs microseconds, so polling it often is cheap and
/// nothing is re-read unless something changed.
public final class LiveDB: @unchecked Sendable {
    public let path: String
    let fast: SQLiteConnection
    let slow: SQLiteConnection
    private let versionConn: SQLiteConnection

    /// Opens the writer first, then the readers. Order matters: a read-only connection cannot open a
    /// WAL database that no one else has open (it would have to create the -shm file), which is
    /// exactly the state before the worker starts. The writer creates and holds the WAL files.
    public static func open(path: String) throws -> (LiveDB, Commands) {
        guard FileManager.default.fileExists(atPath: path) else { throw LiveDBError.missing(path) }
        let cmd = try Commands(path: path)
        return (try LiveDB(path: path), cmd)
    }

    /// Prefer `open(path:)`; this alone fails on a WAL db nobody else has open.
    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw LiveDBError.missing(path)
        }
        self.path = path
        fast = try SQLiteConnection(path: path, readOnly: true, immutable: false)
        slow = try SQLiteConnection(path: path, readOnly: true, immutable: false)
        versionConn = try SQLiteConnection(path: path, readOnly: true, immutable: false)
        // A filestudio db is always WAL (the Go side opens it that way). Refuse anything we could
        // only read as a frozen snapshot: the whole app is about watching it change.
        let mode = try fast.queryRow("PRAGMA journal_mode")?.first?.textValue ?? ""
        if mode.lowercased() != "wal" {
            throw LiveDBError.notLive(path, mode)
        }
        let hasActions = try fast.queryRow(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('actions','sources','backup_runs')"
        )?.first?.intValue ?? 0
        if hasActions < 3 {
            throw LiveDBError.notFilestudio(path)
        }
    }

    /// Moves whenever any other connection commits to the database.
    public func changeCounter() -> Int64 {
        (try? versionConn.queryRow("PRAGMA data_version")?.first?.intValue) ?? -1
    }

    /// Rows from the fast lane (small queries; 250 ms budget so a surprise can't stall a refresh).
    public func rows(_ sql: String, _ args: [Any] = [], budgetMs: Int = 250) throws -> [Row] {
        try fast.query(sql, args: args, control: QueryControl(budgetMs: budgetMs)).map(Row.init)
    }

    public func row(_ sql: String, _ args: [Any] = [], budgetMs: Int = 250) throws -> Row? {
        try fast.queryRow(sql, args: args, control: QueryControl(budgetMs: budgetMs)).map(Row.init)
    }

    /// Rows from the slow lane, cancellable.
    public func slowRows(_ sql: String, _ args: [Any] = [], token: CancelToken? = nil, budgetMs: Int = 30_000) throws -> [Row] {
        try slow.query(sql, args: args, control: QueryControl(budgetMs: budgetMs, token: token)).map(Row.init)
    }
}

public enum LiveDBError: LocalizedError, Equatable {
    case missing(String)
    case notLive(String, String)
    case notFilestudio(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let p): return "No database at \(p)."
        case .notLive(let p, let m):
            return "\(p) is in journal mode '\(m)', not WAL. Open it once with filestudio so it can be watched live."
        case .notFilestudio(let p):
            return "\(p) is not a filestudio database (or it predates backups). Run `filestudio -db \(p) worker` once to upgrade it."
        }
    }
}

/// One result row with typed accessors by column index.
public struct Row: Sendable {
    public let values: [SQLiteValue]
    init(_ values: [SQLiteValue]) { self.values = values }

    public func int(_ i: Int) -> Int64 {
        guard i < values.count else { return 0 }
        switch values[i] {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        case .text(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    public func double(_ i: Int) -> Double { i < values.count ? (values[i].doubleValue ?? 0) : 0 }
    public func optDouble(_ i: Int) -> Double? { i < values.count ? values[i].doubleValue : nil }
    public func string(_ i: Int) -> String { i < values.count ? (values[i].textValue ?? "") : "" }
    public func bool(_ i: Int) -> Bool { int(i) != 0 }
}
