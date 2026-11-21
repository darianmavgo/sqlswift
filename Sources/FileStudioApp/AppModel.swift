import Foundation
import Observation
import SQLDocCore
import FileStudioKit

enum AppSection: String, CaseIterable, Identifiable {
    case overview, backup, reclaim, activity, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .backup: "Backup"
        case .reclaim: "Reclaim Space"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .backup: "icloud.and.arrow.up"
        case .reclaim: "externaldrive.badge.checkmark"
        case .activity: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// All window state. The main actor only ever swaps in values that background tasks produced:
/// it never runs a query (sqlswift rule 5), so the UI stays smooth while a backup writes to the
/// db ten times a second.
@MainActor @Observable
final class AppModel {
    var section: AppSection = .overview
    var reclaimFolder: String? // PlanFolder.id; kept while switching sections
    private(set) var dbPath: String?
    private(set) var openError: String?
    private(set) var snapshot = Snapshot()
    private(set) var loaded = false
    private(set) var reclaim = ReclaimSummary()
    private(set) var reclaimLoading = false
    /// Per-folder backup coverage of the source being backed up (slow lane, throttled).
    private(set) var coverage: CoverageReport?
    private(set) var workerStatus: WorkerSupervisor.Status = .stopped
    private(set) var speedHistory: [Double] = []
    var alert: String?
    var pendingCommand: String?

    @ObservationIgnored private var db: LiveDB?
    @ObservationIgnored private(set) var commands: Commands?
    @ObservationIgnored private var supervisor: WorkerSupervisor?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var reclaimTask: Task<Void, Never>?
    @ObservationIgnored private var reclaimToken: CancelToken?
    @ObservationIgnored private var reclaimKey = ""
    @ObservationIgnored private var coverageKey = ""
    @ObservationIgnored private var coverageLoading = false
    @ObservationIgnored private var coverageLoadedAt = Date.distantPast
    @ObservationIgnored private var lastStatsStamp = ""
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Keeps App Nap from throttling the live refresh while the worker is doing something.
    @ObservationIgnored private var activity: NSObjectProtocol?

    var database: LiveDB? { db }

    /// An action a hot reload interrupted; queued again once the new worker is up.
    @ObservationIgnored private var resumeAction: String?

    init() {
        if let raw = defaults.string(forKey: "section"), let s = AppSection(rawValue: raw) { section = s }
        if let f = defaults.string(forKey: "reload.folder") { reclaimFolder = f }
        resumeAction = defaults.string(forKey: "reload.resume")
        defaults.removeObject(forKey: "reload.folder")
        defaults.removeObject(forKey: "reload.resume")
        if let p = defaults.string(forKey: "dbPath") ?? WorkerSupervisor.defaultDatabase() {
            open(path: p)
        }
    }

    // MARK: open / close

    func open(path: String) {
        close()
        dbPath = path
        openError = nil
        loaded = false
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (db, cmd) = try LiveDB.open(path: path)
                let first = db.loadSnapshot()
                await self?.opened(path: path, db: db, commands: cmd, first: first)
            } catch {
                await self?.failed(path: path, error)
            }
        }
    }

    private func opened(path: String, db: LiveDB, commands: Commands, first: Snapshot) {
        guard dbPath == path else { return }
        self.db = db
        self.commands = commands
        defaults.set(path, forKey: "dbPath")
        apply(first)
        loaded = true
        let sup = WorkerSupervisor(dbPath: path, binary: WorkerSupervisor.locateBinary())
        // a supervisor being shut down (previous db) still reports; only the current one counts
        sup.onStatus = { [weak self, weak sup] s in
            Task { @MainActor in
                guard let self, let sup, self.supervisor === sup else { return }
                self.workerStatus = s
            }
        }
        sup.onChildDied = { pid in try? commands.releaseWorkerLease(deadPID: pid) }
        supervisor = sup
        let alive = first.workerAlive
        Task.detached { sup.ensureRunning(externalAlive: alive) }
        startPolling(db)
        refreshReclaim(force: true)
        FSLog.event("db", "opened", ["path": path])
    }

    private func failed(path: String, _ error: Error) {
        guard dbPath == path else { return }
        openError = error.localizedDescription
        FSLog.event("error", "open failed", ["path": path, "error": error.localizedDescription])
    }

    func close() {
        poller?.cancel()
        poller = nil
        reclaimToken?.cancel()
        reclaimTask?.cancel()
        if let sup = supervisor { Task.detached { sup.stop() } } // never wait on the main thread
        supervisor = nil
        db = nil
        commands = nil
        snapshot = Snapshot()
        reclaim = ReclaimSummary()
        coverage = nil
        coverageKey = ""
        speedHistory = []
    }

    /// Called at quit: stop the worker cleanly so an unfinished backup resumes next time.
    func shutdown() {
        supervisor?.stop()
    }

    /// Hot reload: remember the place and any running job, then stop the worker (off the main
    /// thread) so the relaunched app starts its own at once.
    func prepareForReload() async {
        defaults.set(section.rawValue, forKey: "section")
        if let f = reclaimFolder { defaults.set(f, forKey: "reload.folder") }
        if let busy = snapshot.busyAction?.name, ["backup", "retry_failed", "free"].contains(busy) {
            // a stopped backup resumes where it was; retry_failed has already requeued its files
            defaults.set(busy == "retry_failed" ? "backup" : busy, forKey: "reload.resume")
        }
        defaults.synchronize()
        // stop refreshing first: the poller would otherwise start a new worker once this one stops
        poller?.cancel()
        poller = nil
        let sup = supervisor
        supervisor = nil
        if let sup { await Task.detached { sup.stop() }.value }
    }

    // MARK: live refresh

    private func startPolling(_ db: LiveDB) {
        poller = Task.detached(priority: .userInitiated) { [weak self] in
            var last: Int64 = db.changeCounter()
            var lastFull = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let v = db.changeCounter()
                // re-read on any commit; also every 5 s so "worker alive" and "ago" texts stay true
                guard v != last || Date().timeIntervalSince(lastFull) > 5 else { continue }
                last = v
                lastFull = Date()
                let snap = db.loadSnapshot()
                await self?.apply(snap)
            }
        }
    }

    private func apply(_ snap: Snapshot) {
        if let live = snap.live, live.updatedAt != lastStatsStamp, snap.run?.isActive == true {
            lastStatsStamp = live.updatedAt
            speedHistory.append(live.speed)
            if speedHistory.count > 240 { speedHistory.removeFirst(speedHistory.count - 240) }
        }
        if snap != snapshot { snapshot = snap }
        if let r = resumeAction, snap.workerAlive, snap.busyAction == nil {
            resumeAction = nil
            FSLog.event("hot", "resume", ["action": r])
            run(r)
        }
        updateActivity(busy: snap.busyAction != nil)
        if let sup = supervisor {
            if snap.workerAlive { sup.healthy() }
            switch sup.status {
            case .running, .starting: break
            default:
                let alive = snap.workerAlive
                Task.detached { sup.ensureRunning(externalAlive: alive) }
            }
        }
        // the heavy reclaim summary only changes when a job finishes or the plan changes
        let key = "\(snap.jobLog.first?.id ?? 0)/\(snap.gate?.planID ?? 0)/\(snap.config.freeLocal)"
        if key != reclaimKey { refreshReclaim(force: false, key: key) }
        refreshCoverageIfNeeded()
    }

    /// Coverage moves with every proven file; re-read at most every 1.5 s, one load at a time.
    private func refreshCoverageIfNeeded() {
        guard let db, !coverageLoading else { return }
        let s = snapshot
        let key = "\(s.config.from)/\(s.run?.id ?? 0):\(s.run?.filesDone ?? 0)/\(s.jobLog.first?.id ?? 0)/\(s.sources.count)"
        guard key != coverageKey else { return }
        guard let src = s.sources.first(where: { $0.name == s.config.from }) else {
            coverageKey = key
            coverage = nil
            return
        }
        let wait = max(0, 1.5 - Date().timeIntervalSince(coverageLoadedAt))
        coverageLoading = true
        coverageKey = key
        Task.detached(priority: .utility) { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let t0 = Date()
            let r = try? db.loadCoverage(of: src, token: nil)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await self?.coverageLoaded(r, ms: ms)
        }
    }

    private func coverageLoaded(_ r: CoverageReport?, ms: Int) {
        coverageLoading = false
        coverageLoadedAt = Date()
        if let r, r.source == snapshot.config.from, r != coverage { coverage = r }
        if ms > 100 { FSLog.event("perf", "coverage slow", ["ms": ms, "folders": r?.folders.count ?? -1]) }
        refreshCoverageIfNeeded() // something may have changed while loading
    }

    private func updateActivity(busy: Bool) {
        #if DEBUG
        let hold = true // the dev command channel must keep running in the background
        #else
        let hold = busy
        #endif
        if hold, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Showing backup progress")
        } else if !hold, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    func refreshReclaim(force: Bool, key: String? = nil) {
        guard let db else { return }
        if let key { reclaimKey = key }
        reclaimToken?.cancel()
        let token = CancelToken()
        reclaimToken = token
        reclaimLoading = true
        reclaimTask = Task.detached(priority: .utility) { [weak self] in
            let t0 = Date()
            let result = try? db.loadReclaimSummary(token: token)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await self?.reclaimLoaded(result, token: token, ms: ms)
        }
    }

    private func reclaimLoaded(_ r: ReclaimSummary?, token: CancelToken, ms: Int) {
        guard token === reclaimToken else { return }
        reclaimLoading = false
        if let r { reclaim = r }
        FSLog.event("perf", "reclaim summary", ["ms": ms, "folders": r?.folders.count ?? -1])
    }

    // MARK: commands (written off the main thread; the poller shows the effect)

    func perform(_ label: String, _ body: @escaping @Sendable (Commands) throws -> Void) {
        guard let commands else { return }
        pendingCommand = label
        FSLog.event("cmd", label)
        Task.detached { [weak self] in
            var message: String?
            do { try body(commands) } catch { message = error.localizedDescription }
            await self?.commandDone(label, message)
        }
    }

    private func commandDone(_ label: String, _ error: String?) {
        if pendingCommand == label { pendingCommand = nil }
        if let error {
            alert = error
            FSLog.event("error", label, ["error": error])
        }
    }

    func run(_ action: String) { perform(action) { try $0.run(action) } }

    // MARK: derived

    var isBackupRunning: Bool {
        snapshot.actions["backup"]?.isBusy == true || snapshot.actions["retry_failed"]?.isBusy == true
    }

    /// While a new backup first re-lists the source folder (before any file is sent): how far it
    /// got, e.g. "12,000 files checked". nil once the transfers start, or when no backup runs.
    var backupScanProgress: String? {
        guard isBackupRunning, let m = snapshot.busyAction?.message,
              m.hasPrefix("looking for new and changed files") else { return nil }
        if let r = m.range(of: ": ", options: .backwards),
           let n = Int64(m[r.upperBound...].split(separator: " ").first ?? "") {
            return "\(Fmt.count(n)) files checked"
        }
        return "Starting…"
    }

    var workerLabel: String {
        switch workerStatus {
        case .running: snapshot.workerAlive ? "Worker running" : "Worker starting"
        case .starting: "Worker starting"
        case .external: snapshot.workerAlive ? "Worker running (external)" : "Worker not responding"
        case .missingBinary: "filestudio binary not found"
        case .crashed: "Worker restarting"
        case .stopped: "Worker stopped"
        }
    }

    var workerHealthy: Bool { snapshot.workerAlive }

    /// Reclaimable bytes/files per local source (the summary covers them all).
    var reclaimBySource: [(source: String, files: Int64, bytes: Int64)] {
        var d: [String: (Int64, Int64)] = [:]
        for f in reclaim.folders { d[f.source, default: (0, 0)].0 += f.files; d[f.source, default: (0, 0)].1 += f.bytes }
        return d.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.bytes > $1.bytes }
    }

    /// Switch the source Reclaim works on (settings.default_local).
    func setFreeLocal(_ source: String) {
        reclaimFolder = nil
        perform("default_local") { try $0.setSetting("default_local", source) }
    }
}
