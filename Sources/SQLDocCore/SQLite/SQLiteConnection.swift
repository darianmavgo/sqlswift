import Foundation
import SQLite3

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
        var pragmas = [
            "PRAGMA cache_size = -65536",    // 64MB cache
            "PRAGMA mmap_size = 268435456",  // 256MB mmap
            "PRAGMA temp_store = 2",         // Memory
            "PRAGMA busy_timeout = 5000"
        ]
        if isReadOnly {
            pragmas.insert("PRAGMA query_only = 1", at: 0)
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
    public func query(_ sql: String, args: [Any] = []) throws -> [[SQLiteValue]] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.openFailed(path: path, code: -1, message: "Database is closed") }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(query: sql, code: rc, message: msg)
        }
        defer { sqlite3_finalize(stmt) }

        try bindArgs(stmt: stmt, args: args)

        var rows: [[SQLiteValue]] = []
        rows.reserveCapacity(128)
        let colCount = sqlite3_column_count(stmt)

        while true {
            let stepRc = sqlite3_step(stmt)
            if stepRc == SQLITE_ROW {
                var row: [SQLiteValue] = []
                row.reserveCapacity(Int(colCount))
                for i in 0..<colCount {
                    row.append(readColumn(stmt: stmt, index: i))
                }
                rows.append(row)
            } else if stepRc == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.stepFailed(code: stepRc, message: msg)
            }
        }
        return rows
    }

    /// Executes a query and returns the first row, or nil if empty.
    public func queryRow(_ sql: String, args: [Any] = []) throws -> [SQLiteValue]? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.openFailed(path: path, code: -1, message: "Database is closed") }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(query: sql, code: rc, message: msg)
        }
        defer { sqlite3_finalize(stmt) }

        try bindArgs(stmt: stmt, args: args)

        let stepRc = sqlite3_step(stmt)
        if stepRc == SQLITE_ROW {
            let colCount = sqlite3_column_count(stmt)
            var row: [SQLiteValue] = []
            row.reserveCapacity(Int(colCount))
            for i in 0..<colCount {
                row.append(readColumn(stmt: stmt, index: i))
            }
            return row
        } else if stepRc == SQLITE_DONE {
            return nil
        } else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.stepFailed(code: stepRc, message: msg)
        }
    }

    /// Executes a streaming query, invoking a row callback for each row without buffering everything in memory.
    public func queryStreaming(_ sql: String, args: [Any] = [], onRow: (Int64, [SQLiteValue]) throws -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.openFailed(path: path, code: -1, message: "Database is closed") }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(query: sql, code: rc, message: msg)
        }
        defer { sqlite3_finalize(stmt) }

        try bindArgs(stmt: stmt, args: args)

        let colCount = sqlite3_column_count(stmt)
        var rowNumber: Int64 = 0

        while true {
            let stepRc = sqlite3_step(stmt)
            if stepRc == SQLITE_ROW {
                var row: [SQLiteValue] = []
                row.reserveCapacity(Int(colCount))
                for i in 0..<colCount {
                    row.append(readColumn(stmt: stmt, index: i))
                }
                let shouldContinue = try onRow(rowNumber, row)
                if !shouldContinue { break }
                rowNumber += 1
            } else if stepRc == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.stepFailed(code: stepRc, message: msg)
            }
        }
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
                rc = sqlite3_bind_text(stmt, idx, NSString(string: strVal).utf8String, -1, nil)
            case is NSNull:
                rc = sqlite3_bind_null(stmt, idx)
            default:
                rc = sqlite3_bind_text(stmt, idx, NSString(string: String(describing: arg)).utf8String, -1, nil)
            }
            if rc != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.bindFailed(index: idx, code: rc, message: msg)
            }
        }
    }

    private func readColumn(stmt: OpaquePointer, index: Int32) -> SQLiteValue {
        let type = sqlite3_column_type(stmt, index)
        switch type {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            if let cStr = sqlite3_column_text(stmt, index) {
                return .text(String(cString: cStr))
            }
            return .text("")
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
