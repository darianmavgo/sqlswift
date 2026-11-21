import Foundation
import SQLDocCore

/// The app's only write path. It can do exactly what the db-as-app protocol allows a person to do
/// with single-cell edits (see filestudio pkg/store/app.go): queue an action, type the delete
/// phrase, protect a plan file, change an allowed setting, choose the backup. Every statement is
/// fixed and parameterised; nothing here accepts SQL. The triggers in the db still have the final
/// say (one action at a time, the exact phrase for apply), and their messages come back as errors.
public final class Commands: @unchecked Sendable {
    private let conn: SQLiteConnection
    private let lock = NSLock()

    public static let actions: Set<String> = ["free", "apply", "backup", "retry_failed", "stop"]
    public static let settingKeys: Set<String> = [
        "bk_transfers", "bk_big_transfers", "bk_checkers", "bk_multi_thread_streams",
        "bk_s3_upload_concurrency", "bk_s3_chunk_size", "bk_s3_upload_cutoff", "bk_retries",
        "default_local",
    ]

    public init(path: String) throws {
        conn = try SQLiteConnection(path: path, readOnly: false, immutable: false)
    }

    /// Queues an action (the worker picks it up within ~150 ms).
    public func run(_ action: String) throws {
        guard Self.actions.contains(action), action != "apply" else { throw CommandError.notAllowed(action) }
        try write("UPDATE actions SET run='go' WHERE name=? RETURNING id", [action])
    }

    /// Deletes the latest plan's files: needs the exact phrase from v_apply_gate, which the trigger
    /// checks again and the worker checks a third time against the live numbers.
    public func apply(confirm phrase: String) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            _ = try conn.exec("BEGIN IMMEDIATE")
            _ = try conn.query("UPDATE actions SET confirm=? WHERE name='apply'", args: [phrase])
            _ = try conn.query("UPDATE actions SET run='go' WHERE name='apply'")
            _ = try conn.exec("COMMIT")
        } catch {
            _ = try? conn.exec("ROLLBACK")
            throw CommandError.refused(Self.message(error))
        }
    }

    /// Protects (or unprotects) one file of a plan. Only plan_items.keep changes.
    public func setKeep(planID: Int64, source: String, path: String, keep: Bool) throws {
        try write("UPDATE plan_items SET keep=? WHERE plan_id=? AND source=? AND path=? AND status='pending' RETURNING plan_id",
                  [keep ? 1 : 0, planID, source, path])
    }

    /// Protects or unprotects every pending file of a plan under one top-level folder.
    public func setKeep(planID: Int64, source: String, folder: String, keep: Bool) throws {
        if folder == "." {
            _ = try locked { try conn.query("UPDATE plan_items SET keep=? WHERE plan_id=? AND source=? AND status='pending' AND instr(path,'/')=0",
                                             args: [keep ? 1 : 0, planID, source]) }
        } else {
            _ = try locked { try conn.query("UPDATE plan_items SET keep=? WHERE plan_id=? AND source=? AND status='pending' AND path >= ? AND path < ?",
                                             args: [keep ? 1 : 0, planID, source, folder + "/", folder + "0"]) }
        }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        guard Self.settingKeys.contains(key) else { throw CommandError.notAllowed(key) }
        _ = try locked {
            try conn.query("INSERT INTO settings (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           args: [key, value])
        }
    }

    /// Makes `target` (an indexed source) the default backup, with its prefix, backing up `from`.
    public func setBackup(target: String, prefix: String, from: String) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            _ = try conn.exec("BEGIN IMMEDIATE")
            guard try conn.queryRow("SELECT 1 FROM sources WHERE name=?", args: [target]) != nil else {
                throw CommandError.refused("unknown backup source \(target)")
            }
            if !from.isEmpty {
                guard try conn.queryRow("SELECT 1 FROM sources WHERE name=? AND backend='local'", args: [from]) != nil else {
                    throw CommandError.refused("\(from) is not a local source")
                }
            }
            _ = try conn.query("UPDATE backup_targets SET is_default=0")
            _ = try conn.query("""
                INSERT INTO backup_targets (source, prefix, is_default, from_source) VALUES (?,?,1,?)
                ON CONFLICT(source) DO UPDATE SET prefix=excluded.prefix, is_default=1, from_source=excluded.from_source
                """, args: [target, prefix, from])
            _ = try conn.exec("COMMIT")
        } catch {
            _ = try? conn.exec("ROLLBACK")
            if let e = error as? CommandError { throw e }
            throw CommandError.refused(Self.message(error))
        }
    }

    /// Frees the worker lease held by `pid`, a process the caller knows is dead (its own child that
    /// crashed), so a new worker can start now instead of after the heartbeat goes stale. Does
    /// nothing if another worker holds the lease.
    public func releaseWorkerLease(deadPID pid: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            _ = try conn.exec("BEGIN IMMEDIATE")
            if try conn.queryRow("SELECT 1 FROM app_flags WHERE key='worker_pid' AND value=?", args: [String(pid)]) != nil {
                _ = try conn.query("UPDATE app_flags SET value='' WHERE key IN ('worker_seen','worker_pid')")
            }
            _ = try conn.exec("COMMIT")
        } catch {
            _ = try? conn.exec("ROLLBACK")
            throw CommandError.refused(Self.message(error))
        }
    }

    private func write(_ sql: String, _ args: [Any]) throws {
        let rows: [[SQLiteValue]]
        do {
            rows = try locked { try conn.query(sql, args: args) }
        } catch {
            throw CommandError.refused(Self.message(error))
        }
        if rows.isEmpty { throw CommandError.noSuchRow }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The trigger's RAISE text, without SQLite's wrapping.
    static func message(_ error: Error) -> String {
        switch error {
        case let SQLiteError.executionFailed(_, message): return message
        case let SQLiteError.stepFailed(_, message): return message
        case let SQLiteError.prepareFailed(_, _, message): return message
        default: return error.localizedDescription
        }
    }
}

public enum CommandError: LocalizedError, Equatable {
    case notAllowed(String)
    case refused(String)
    case noSuchRow

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let w): return "\(w) can't be changed from the app."
        case .refused(let m): return m
        case .noSuchRow: return "Nothing to change (the row is gone or already done)."
        }
    }
}
