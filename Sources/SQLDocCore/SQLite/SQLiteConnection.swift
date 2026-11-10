import Foundation
import SQLite3

/// Tells SQLite to copy a bound blob/text immediately, so we don't have to keep
/// the Swift buffer alive until the statement is stepped/finalized.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Lets another thread stop a statement that is already running. Per query
/// rather than `sqlite3_interrupt`, which is connection-wide and would land on
/// whichever statement holds the connection by the time it arrives.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Limits on one query: a wall-clock budget, a cancel token, a per-cell TEXT
/// byte cap, and a ceiling on the text the whole result may hold. Any
/// combination; all nil means run unbounded.
public struct QueryControl: Sendable {
    public var budgetMs: Int?
    public var token: CancelToken?
    public var maxTextBytes: Int?
    public var maxResultBytes: Int?
    public init(
        budgetMs: Int? = nil, token: CancelToken? = nil,
        maxTextBytes: Int? = nil, maxResultBytes: Int? = nil
    ) {
        self.budgetMs = budgetMs
        self.token = token
        self.maxTextBytes = maxTextBytes
        self.maxResultBytes = maxResultBytes
    }

    /// Fills in the limits every grid page carries, keeping whatever the caller
    /// set. `rowKeyed` pages can re-fetch a cell by rowid, so they take the small
    /// cell cap; the rest keep each cell whole up to the inspector's ceiling.
    public func forPage(rowKeyed: Bool) -> QueryControl {
        var c = self
        if c.maxTextBytes == nil {
            c.maxTextBytes = rowKeyed ? BehaviorConfig.textCellFetchMaxBytes : BehaviorConfig.inspectorTextMaxBytes
        }
        if c.maxResultBytes == nil { c.maxResultBytes = BehaviorConfig.queryResultMaxBytes }
        return c
    }
}

/// Low-level wrapper around a single SQLite3 connection handle (sqlite3*).
/// Designed for high-throughput read-only queries with zero memory bloat.
public final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: String
    public let isImmutable: Bool

    public let isReadOnly: Bool

    public init(path: String, readOnly: Bool = true, immutable: Bool = false) throws {
        self.path = path
        self.isReadOnly = readOnly
        self.isImmutable = immutable

        var handle: OpaquePointer?
        let flags: Int32
        if readOnly {
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        } else {
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        }

        let uriPath: String
        if immutable && readOnly {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            uriPath = "file:\(encoded)?immutable=1&mode=ro"
        } else {
            uriPath = path
        }

        let rc = sqlite3_open_v2(uriPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let validHandle = handle else {
            let msg = handle != nil ? String(cString: sqlite3_errmsg(handle)) : "Unknown open error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.openFailed(path: path, code: rc, message: msg)
        }
        self.db = validHandle

        // Configure optimal pragmas
        try applyPragmas()
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle = db {
            sqlite3_close(handle)
            db = nil
        }
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return db != nil
    }

    private func applyPragmas() throws {
        // Generated from the connect_pragma table in sqldoc.db (see ConnectPragmas.swift).
        var pragmas = sqldocConnectPragmas
        if !isReadOnly {
            pragmas.removeAll { $0.contains("query_only") }
        }
        for p in pragmas {
            _ = try? exec(p)
        }
    }

    @discardableResult
    public func exec(_ sql: String) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.openFailed(path: path, code: -1, message: "Database is closed") }

        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg != nil ? String(cString: errmsg!) : String(cString: sqlite3_errmsg(db))
            sqlite3_free(errmsg)
            throw SQLiteError.executionFailed(query: sql, message: msg)
        }
        return rc
    }

    /// Executes a query with arguments and returns all rows with cell values.
    /// With a `control`, the statement stops early on cancel or when its time
    /// budget runs out, throwing `.cancelled` / `.timedOut`.
    public func query(_ sql: String, args: [Any] = [], control: QueryControl? = nil) throws -> [[SQLiteValue]] {
        var rows: [[SQLiteValue]] = []
        rows.reserveCapacity(128)
        try run(sql, args: args, control: control) { row in
            rows.append(row)
            return true
        }
        return rows
    }

    /// Executes a query and returns the first row, or nil if empty.
    public func queryRow(_ sql: String, args: [Any] = [], control: QueryControl? = nil) throws -> [SQLiteValue]? {
        var first: [SQLiteValue]?
        try run(sql, args: args, control: control) { row in
            first = row
            return false
        }
        return first
    }

    /// Executes a single-row query with a hard wall-clock time budget (in milliseconds)
    /// enforced via `sqlite3_progress_handler`. Returns `nil` if the budget expires,
    /// preventing background `COUNT(*)` scans on 20 GB tables or heavy views from thrashing disk I/O.
    public func queryRowWithTimeout(_ sql: String, args: [Any] = [], maxMillis: Int) -> [SQLiteValue]? {
        (try? queryRow(sql, args: args, control: QueryControl(budgetMs: maxMillis))) ?? nil
    }

    /// Executes a multi-row query with a hard wall-clock time budget (in milliseconds)
    /// enforced via `sqlite3_progress_handler`. Returns `nil` if the budget expires.
    public func queryWithTimeout(_ sql: String, args: [Any] = [], maxMillis: Int) -> [[SQLiteValue]]? {
        try? query(sql, args: args, control: QueryControl(budgetMs: maxMillis))
    }

    /// Executes a streaming query, invoking a row callback for each row without buffering everything in memory.
    public func queryStreaming(
        _ sql: String, args: [Any] = [], control: QueryControl? = nil,
        onRow: (Int64, [SQLiteValue]) throws -> Bool
    ) throws {
        var rowNumber: Int64 = 0
        try run(sql, args: args, control: control) { row in
            let shouldContinue = try onRow(rowNumber, row)
            rowNumber += 1
            return shouldContinue
        }
    }

    /// What the progress handler reads on each tick. A class so its address is
    /// stable for the C callback; only touched while the connection lock is held,
    /// apart from the token, which carries its own lock.
    private final class ProgressContext {
        let deadlineNano: UInt64   // 0 = no deadline
        let token: CancelToken?
        var timedOut = false
        init(deadlineNano: UInt64, token: CancelToken?) {
            self.deadlineNano = deadlineNano
            self.token = token
        }
    }

    /// The one stepping loop behind every row-returning call. `onRow` returns
    /// false to stop early.
    private func run(
        _ sql: String, args: [Any], control: QueryControl?,
        onRow: ([SQLiteValue]) throws -> Bool
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.openFailed(path: path, code: -1, message: "Database is closed") }

        // A request superseded while it waited for the lock never starts.
        if control?.token?.isCancelled == true { throw SQLiteError.cancelled }

        var context: ProgressContext?
        if let control, control.budgetMs != nil || control.token != nil {
            // The budget is measured from here, not from when the caller queued.
            let deadline = control.budgetMs.map {
                DispatchTime.now().uptimeNanoseconds &+ (UInt64(max(1, $0)) &* 1_000_000)
            } ?? 0
            let ctx = ProgressContext(deadlineNano: deadline, token: control.token)
            context = ctx
            sqlite3_progress_handler(
                db,
                SQLiteConnection.progressOps,
                { raw -> Int32 in
                    guard let raw else { return 0 }
                    let ctx = Unmanaged<ProgressContext>.fromOpaque(raw).takeUnretainedValue()
                    if ctx.token?.isCancelled == true { return 1 }
                    if ctx.deadlineNano != 0, DispatchTime.now().uptimeNanoseconds > ctx.deadlineNano {
                        ctx.timedOut = true
                        return 1
                    }
                    return 0
                },
                Unmanaged.passUnretained(ctx).toOpaque()
            )
        }
        defer {
            if context != nil { sqlite3_progress_handler(db, 0, nil, nil) }
        }

        func interruption() -> SQLiteError {
            if context?.timedOut == true { return .timedOut(millis: control?.budgetMs ?? 0) }
            return .cancelled
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if rc == SQLITE_INTERRUPT { throw interruption() }
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(query: sql, code: rc, message: msg)
        }
        defer { sqlite3_finalize(stmt) }

        try bindArgs(stmt: stmt, args: args)

        let colCount = sqlite3_column_count(stmt)
        let maxTextBytes = control?.maxTextBytes
        let maxResultBytes = control?.maxResultBytes
        var resultBytes = 0

        while true {
            let stepRc = sqlite3_step(stmt)
            if stepRc == SQLITE_ROW {
                var row: [SQLiteValue] = []
                row.reserveCapacity(Int(colCount))
                for i in 0..<colCount {
                    row.append(readColumn(stmt: stmt, index: i, maxTextBytes: maxTextBytes))
                }
                if let maxResultBytes {
                    for case .text(let s) in row { resultBytes += s.utf8.count }
                    for case .textPrefix(let s, _) in row { resultBytes += s.utf8.count }
                    if resultBytes > maxResultBytes { throw SQLiteError.resultTooLarge(limitBytes: maxResultBytes) }
                }
                if try !onRow(row) { break }
            } else if stepRc == SQLITE_DONE {
                break
            } else if stepRc == SQLITE_INTERRUPT {
                throw interruption()
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.stepFailed(code: stepRc, message: msg)
            }
        }
    }

    /// VM opcodes between progress-handler ticks: frequent enough that a cancel
    /// lands in well under a frame, rare enough to cost nothing measurable.
    private static let progressOps: Int32 = 10_000

    /// Runs a query expected to return a single BLOB in the first column of the
    /// first row, and returns its raw bytes. Used by the cell inspector — blob
    /// bytes are otherwise never materialized.
    public func queryBlob(_ sql: String, args: [Any] = []) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        try bindArgs(stmt: stmt, args: args)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let ptr = sqlite3_column_blob(stmt, 0) else { return Data() }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: ptr, count: n)
    }

    /// Prepares `sql`, hands the result column names to `body`, and finalizes.
    /// Used to label an ad-hoc query's grid even when it returns zero rows.
    public func withPreparedColumnNames(_ sql: String, _ body: ([String]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { body([]); return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { body([]); return }
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        var names: [String] = []
        names.reserveCapacity(Int(n))
        for i in 0..<n {
            if let c = sqlite3_column_name(stmt, i) {
                names.append(String(cString: c))
            } else {
                names.append("col\(i + 1)")
            }
        }
        body(names)
    }

    private func bindArgs(stmt: OpaquePointer, args: [Any]) throws {
        for (index, arg) in args.enumerated() {
            let idx = Int32(index + 1)
            let rc: Int32
            switch arg {
            case let intVal as Int64:
                rc = sqlite3_bind_int64(stmt, idx, intVal)
            case let intVal as Int:
                rc = sqlite3_bind_int64(stmt, idx, Int64(intVal))
            case let intVal as Int32:
                rc = sqlite3_bind_int(stmt, idx, intVal)
            case let dblVal as Double:
                rc = sqlite3_bind_double(stmt, idx, dblVal)
            case let strVal as String:
                rc = sqlite3_bind_text(stmt, idx, strVal, -1, SQLITE_TRANSIENT)
            case is NSNull:
                rc = sqlite3_bind_null(stmt, idx)
            default:
                rc = sqlite3_bind_text(stmt, idx, String(describing: arg), -1, SQLITE_TRANSIENT)
            }
            if rc != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.bindFailed(index: idx, code: rc, message: msg)
            }
        }
    }

    private func readColumn(stmt: OpaquePointer, index: Int32, maxTextBytes: Int? = nil) -> SQLiteValue {
        let type = sqlite3_column_type(stmt, index)
        switch type {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            guard let cStr = sqlite3_column_text(stmt, index) else { return .text("") }
            if let cap = maxTextBytes {
                let total = Int(sqlite3_column_bytes(stmt, index))
                if total > cap {
                    // SQLite has the value in hand, but we copy and keep only its head.
                    // Back up to a scalar boundary so the cut never splits a character.
                    var end = max(0, cap)
                    while end > 0 && (cStr[end] & 0xC0) == 0x80 { end -= 1 }
                    let head = String(decoding: UnsafeBufferPointer(start: cStr, count: end), as: UTF8.self)
                    return .textPrefix(head, totalBytes: total)
                }
            }
            return .text(String(cString: cStr))
        case SQLITE_BLOB:
            let bytes = sqlite3_column_bytes(stmt, index)
            return .blob(bytes: Int(bytes))
        case SQLITE_NULL:
            return .null
        default:
            return .null
        }
    }
}
