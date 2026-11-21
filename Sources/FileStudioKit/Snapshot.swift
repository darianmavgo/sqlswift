import Foundation
import SQLDocCore

// Everything the app shows comes from fixed queries over tables the Go side owns. These are
// plain value types: the UI swaps a whole snapshot in when it differs from the last one, so
// SwiftUI only redraws what actually changed.

public struct ActionState: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name, state, message, updatedAt: String
    public var isBusy: Bool { state == "queued" || state == "running" }
}

public struct RunProgress: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let source, target, dest, state, message, startedAt, finishedAt: String
    public let filesTotal, bytesTotal, filesDone, bytesDone, filesUploaded, bytesUploaded, filesFailed: Int64
    public var fraction: Double {
        bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0)
    }
    public var isActive: Bool { state == "running" }
}

public struct LiveTransfer: Equatable, Sendable {
    public let runID: Int64
    public let bytes: Int64
    public let speed: Double   // bytes/s, smoothed by the worker
    public let eta: Double?    // seconds
    public let active: Int64
    public let errors: Int64
    public let lastError: String
    public let updatedAt: String
}

public struct ActiveFile: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let size, bytes: Int64
    public let speed: Double
    public let percentage: Int
}

public struct ItemProblem: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path, state, error: String
    public let size: Int64
    public let attempts: Int64
}

public struct JobLogEntry: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let at, action, state, message: String
}

public struct SourceInfo: Equatable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name, remote, table, backend, status: String
    public let fileCount: Int64
    public var isLocal: Bool { backend == "local" }
}

public struct BackupConfig: Equatable, Sendable {
    public let target: String     // default backup source ("" = none)
    public let prefix: String
    public let from: String       // local source to back up ("" = none)
    public let freeLocal: String  // settings.default_local, what "free" scans
}

public struct ApplyGate: Equatable, Sendable {
    public let planID: Int64
    public let files: Int64
    public let gb: Double
    public let phrase: String
}

public struct PlanFolder: Equatable, Sendable, Identifiable {
    public var id: String { source + "/" + folder }
    public let source, folder: String
    public let files, bytes, kept, deleted: Int64
}

public struct Coverage: Equatable, Sendable {
    public let files, bytes, provenFiles, provenBytes: Int64
    public init(files: Int64, bytes: Int64, provenFiles: Int64, provenBytes: Int64) {
        self.files = files; self.bytes = bytes; self.provenFiles = provenFiles; self.provenBytes = provenBytes
    }
    /// By bytes; a folder of empty files (0 bytes) goes by file count, and nothing at all is done.
    public var fraction: Double {
        if bytes > 0 { return Double(provenBytes) / Double(bytes) }
        return files > 0 ? Double(provenFiles) / Double(files) : 1
    }
    public var missingFiles: Int64 { files - provenFiles }
    public var missingBytes: Int64 { bytes - provenBytes }
    public var complete: Bool { provenFiles >= files }
}

/// How much of the backed-up source has a proven copy, per top-level folder. Read on the slow
/// lane (a join over every indexed file), throttled while a backup runs.
public struct CoverageReport: Equatable, Sendable {
    public struct Folder: Equatable, Sendable, Identifiable {
        public var id: String { folder }
        public let folder: String
        public let coverage: Coverage
    }
    public var source = ""
    public var folders: [Folder] = []
    public var total = Coverage(files: 0, bytes: 0, provenFiles: 0, provenBytes: 0)
    public init() {}
}

/// The fast snapshot: everything the window shows that is cheap to read (a few ms in total).
public struct Snapshot: Equatable, Sendable {
    public var workerSeen: String = ""
    public var workerAlive = false
    public var actions: [String: ActionState] = [:]
    public var run: RunProgress?
    public var runs: [RunProgress] = []
    public var live: LiveTransfer?
    public var activeFiles: [ActiveFile] = []
    public var stateCounts: [String: Int64] = [:]
    public var problems: [ItemProblem] = []
    public var jobLog: [JobLogEntry] = []
    public var sources: [SourceInfo] = []
    public var config = BackupConfig(target: "", prefix: "", from: "", freeLocal: "")
    public var settings: [String: String] = [:]
    public var gate: ApplyGate?
    public var planFolders: [PlanFolder] = []

    public init() {}

    public var busyAction: ActionState? { actions.values.first { $0.isBusy } }
}

/// The slow snapshot: heavy views, read on the slow lane only after a job finishes.
public struct ReclaimSummary: Equatable, Sendable {
    public struct Folder: Equatable, Sendable, Identifiable {
        public var id: String { source + "/" + folder }
        public let source, folder, kinds: String
        public let files, bytes, verifiedFiles: Int64
    }
    public var folders: [Folder] = []
    public var totalBytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }
    public var totalFiles: Int64 { folders.reduce(0) { $0 + $1.files } }
    public var loadedAt = Date.distantPast
    public init() {}
}

/// One file in a plan, with the proof that makes it safe.
public struct PlanFile: Equatable, Sendable, Identifiable {
    public var id: String { source + "\u{0}" + path }
    public let planID: Int64
    public let source, path, reason, confidence, keepCopy, status: String
    public let size: Int64
    public let keep: Bool
    /// Why apply refused it (status "refused"), e.g. the file changed after its backup.
    public var note: String = ""
}

public struct DeletedEntry: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let at, source, path, reason, keepCopy: String
    public let size: Int64
}

public extension LiveDB {
    /// Reads the fast snapshot. Each query is small and indexed; a failure in one section leaves
    /// that section empty rather than failing the whole refresh.
    func loadSnapshot() -> Snapshot {
        var s = Snapshot()
        if let r = try? row("SELECT value, value > datetime('now','-15 seconds') FROM app_flags WHERE key='worker_seen'") {
            s.workerSeen = r.string(0)
            s.workerAlive = r.bool(1)
        }
        for r in (try? rows("SELECT name, state, message, coalesce(updated_at,'') FROM actions")) ?? [] {
            s.actions[r.string(0)] = ActionState(name: r.string(0), state: r.string(1), message: r.string(2), updatedAt: r.string(3))
        }
        s.runs = ((try? rows(Self.runSQL + " ORDER BY id DESC LIMIT 12")) ?? []).map(Self.run)
        s.run = s.runs.first
        if let run = s.run {
            if let r = try? row("SELECT run_id, coalesce(bytes,0), coalesce(speed,0), eta_s, coalesce(active,0), coalesce(errors,0), coalesce(last_error,''), coalesce(updated_at,'') FROM transfer_stats WHERE id=1"),
               r.int(0) == run.id {
                s.live = LiveTransfer(runID: r.int(0), bytes: r.int(1), speed: r.double(2), eta: r.optDouble(3),
                                      active: r.int(4), errors: r.int(5), lastError: r.string(6), updatedAt: r.string(7))
            }
            if run.isActive {
                s.activeFiles = ((try? rows("SELECT path, coalesce(size,0), coalesce(bytes,0), coalesce(speed,0), coalesce(percentage,0) FROM transfer_active ORDER BY size DESC LIMIT 16")) ?? []).map {
                    ActiveFile(path: $0.string(0), size: $0.int(1), bytes: $0.int(2), speed: $0.double(3), percentage: Int($0.int(4)))
                }
            }
            for r in (try? rows("SELECT state, count(*) FROM backup_items WHERE run_id=? GROUP BY state", [run.id])) ?? [] {
                s.stateCounts[r.string(0)] = r.int(1)
            }
            s.problems = ((try? rows("""
                SELECT path, state, error, size, attempts FROM backup_items
                WHERE run_id=? AND state NOT IN ('queued','verified') ORDER BY size DESC LIMIT 200
                """, [run.id])) ?? []).map {
                ItemProblem(path: $0.string(0), state: $0.string(1), error: $0.string(2), size: $0.int(3), attempts: $0.int(4))
            }
        }
        s.jobLog = ((try? rows("SELECT id, coalesce(at,''), coalesce(action,''), coalesce(state,''), coalesce(message,'') FROM job_log ORDER BY id DESC LIMIT 50")) ?? []).map {
            JobLogEntry(id: $0.int(0), at: $0.string(1), action: $0.string(2), state: $0.string(3), message: $0.string(4))
        }
        s.sources = ((try? rows("SELECT name, remote, tbl, coalesce(backend,''), coalesce(status,''), coalesce(file_count,0) FROM sources ORDER BY name")) ?? []).map {
            SourceInfo(name: $0.string(0), remote: $0.string(1), table: $0.string(2), backend: $0.string(3), status: $0.string(4), fileCount: $0.int(5))
        }
        for r in (try? rows("SELECT key, coalesce(value,'') FROM settings WHERE key LIKE 'bk_%' OR key='default_local'")) ?? [] {
            s.settings[r.string(0)] = r.string(1)
        }
        let t = try? row("SELECT source, prefix, from_source FROM backup_targets WHERE is_default=1")
        s.config = BackupConfig(target: t?.string(0) ?? "", prefix: t?.string(1) ?? "", from: t?.string(2) ?? "",
                                freeLocal: s.settings["default_local"] ?? "")
        if let r = try? row("SELECT plan_id, files, gb, coalesce(phrase,'') FROM v_apply_gate") {
            s.gate = ApplyGate(planID: r.int(0), files: r.int(1), gb: r.double(2), phrase: r.string(3))
        }
        s.planFolders = ((try? rows("SELECT source, folder, files, bytes, kept, deleted FROM v_plan_folders ORDER BY bytes DESC LIMIT 500")) ?? []).map {
            PlanFolder(source: $0.string(0), folder: $0.string(1), files: $0.int(2), bytes: $0.int(3), kept: $0.int(4), deleted: $0.int(5))
        }
        return s
    }

    /// Per-folder coverage of a local source (see CoverageReport). The joins are on verified's
    /// primary key: ~90 ms for 110k files.
    public func loadCoverage(of source: SourceInfo, token: CancelToken?) throws -> CoverageReport {
        var out = CoverageReport()
        out.source = source.name
        guard Self.safeIdent(source.table) else { return out }
        // Files the ignore patterns keep out of the backup (.git, .venv, .DS_Store…) are not
        // "missing": leave them out, or coverage could never reach 100%. Older dbs have no
        // backup_ignored table until the worker opens them.
        let hasIgnored = ((try? row("SELECT 1 FROM sqlite_master WHERE type='table' AND name='backup_ignored'")) ?? nil) != nil
        let skip = hasIgnored ? "WHERE NOT EXISTS (SELECT 1 FROM backup_ignored i WHERE i.source=?1 AND i.path=f.path)" : ""
        let rows = try slowRows("""
            SELECT CASE WHEN instr(f.path, '/') > 0 THEN substr(f.path, 1, instr(f.path, '/') - 1) ELSE '.' END AS folder,
              count(*), coalesce(sum(f.size),0), count(v.path), coalesce(sum(CASE WHEN v.path IS NOT NULL THEN f.size END),0)
            FROM "\(source.table)" f LEFT JOIN verified v
              ON v.source=?1 AND v.path=f.path AND v.size=f.size AND v.mod_time=f.mod_time AND v.method IN ('hash','download')
            \(skip)
            GROUP BY 1 ORDER BY 3 DESC
            """, [source.name], token: token)
        var t = (0 as Int64, 0 as Int64, 0 as Int64, 0 as Int64)
        out.folders = rows.map {
            let c = Coverage(files: $0.int(1), bytes: $0.int(2), provenFiles: $0.int(3), provenBytes: $0.int(4))
            t = (t.0 + c.files, t.1 + c.bytes, t.2 + c.provenFiles, t.3 + c.provenBytes)
            return CoverageReport.Folder(folder: $0.string(0), coverage: c)
        }
        out.total = Coverage(files: t.0, bytes: t.1, provenFiles: t.2, provenBytes: t.3)
        return out
    }

    /// Heavy: v_reclaim looks at every local file. Slow lane, cancellable.
    func loadReclaimSummary(token: CancelToken?) throws -> ReclaimSummary {
        var out = ReclaimSummary()
        out.folders = try slowRows("""
            SELECT source, folder, coalesce(kinds,''), files, coalesce(bytes,0), coalesce(verified_files,0)
            FROM v_reclaim_ready ORDER BY bytes DESC
            """, token: token).map {
            ReclaimSummary.Folder(source: $0.string(0), folder: $0.string(1), kinds: $0.string(2),
                                  files: $0.int(3), bytes: $0.int(4), verifiedFiles: $0.int(5))
        }
        out.loadedAt = Date()
        return out
    }

    /// Files of the latest plan under one top-level folder, biggest first, in pages. Keyset paging
    /// on (size, path), never OFFSET, so page 50 costs what page 1 does.
    func planFiles(source: String, folder: String, after: PlanFile? = nil, limit: Int = 300) throws -> [PlanFile] {
        // plan_items.note arrives with the worker's migration; an older db reads it as ''
        let hasNote = ((try? row("SELECT 1 FROM pragma_table_info('plan_items') WHERE name='note'")) ?? nil) != nil
        var sql = """
            SELECT plan_id, source, path, coalesce(reason,''), coalesce(confidence,''), coalesce(keep_copy,''),
              status, size, keep, \(hasNote ? "note" : "''") FROM plan_items
            WHERE plan_id=(SELECT max(id) FROM plans) AND source=?
            """
        var args: [Any] = [source]
        if folder == "." {
            sql += " AND instr(path,'/')=0"
        } else {
            sql += " AND path >= ? AND path < ?"
            args += [folder + "/", folder + "0"] // '0' sorts right after '/'
        }
        if let a = after {
            sql += " AND (size < ? OR (size = ? AND path > ?))"
            args += [a.size, a.size, a.path]
        }
        sql += " ORDER BY size DESC, path LIMIT \(limit)"
        return try slowRows(sql, args, budgetMs: 5_000).map {
            PlanFile(planID: $0.int(0), source: $0.string(1), path: $0.string(2), reason: $0.string(3),
                     confidence: $0.string(4), keepCopy: $0.string(5), status: $0.string(6), size: $0.int(7), keep: $0.bool(8),
                     note: $0.string(9))
        }
    }

    func deleted(matching q: String, limit: Int = 300) throws -> [DeletedEntry] {
        let pattern = "%" + q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return try slowRows("""
            SELECT id, coalesce(deleted_at,''), coalesce(source,''), coalesce(path,''), coalesce(reason,''), coalesce(keep_copy,''), coalesce(size,0)
            FROM deleted_log WHERE ?='' OR path LIKE ? ESCAPE '\\' ORDER BY id DESC LIMIT \(limit)
            """, [q, pattern], budgetMs: 5_000).map {
            DeletedEntry(id: $0.int(0), at: $0.string(1), source: $0.string(2), path: $0.string(3),
                         reason: $0.string(4), keepCopy: $0.string(5), size: $0.int(6))
        }
    }

    internal static let runSQL = """
        SELECT id, source, target, dest, state, coalesce(message,''), coalesce(started_at,''), coalesce(finished_at,''),
          files_total, bytes_total, files_done, bytes_done, files_uploaded, bytes_uploaded, files_failed FROM backup_runs
        """

    internal static func run(_ r: Row) -> RunProgress {
        RunProgress(id: r.int(0), source: r.string(1), target: r.string(2), dest: r.string(3), state: r.string(4),
                    message: r.string(5), startedAt: r.string(6), finishedAt: r.string(7),
                    filesTotal: r.int(8), bytesTotal: r.int(9), filesDone: r.int(10), bytesDone: r.int(11),
                    filesUploaded: r.int(12), bytesUploaded: r.int(13), filesFailed: r.int(14))
    }

    /// Table names come from the db (sources.tbl); only plain identifiers are ever interpolated.
    internal static func safeIdent(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
