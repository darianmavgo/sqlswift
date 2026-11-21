import Foundation

/// Keeps one `filestudio worker` running for the open database: starts it, restarts it with
/// backoff if it exits, and stops it (SIGTERM, so it clears its heartbeat and marks an
/// interrupted backup resumable) when the app quits. If a worker the app did not start is
/// already heartbeating (someone ran it in a terminal), the supervisor leaves it alone.
public final class WorkerSupervisor: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case stopped
        case starting
        case running(pid: Int32)
        case external          // another process is the worker
        case missingBinary
        case crashed(String)   // exited; restarting after a delay
    }

    private let lock = NSLock()
    private var process: Process?
    private var wantRunning = false
    private var failures = 0
    private var _status: Status = .stopped
    private let dbPath: String
    private let binary: String?
    private let logURL: URL
    public var onStatus: (@Sendable (Status) -> Void)?
    /// Called (off the main thread) when the child dies unexpectedly, before it is restarted:
    /// release its lease so the restart is immediate (Commands.releaseWorkerLease).
    public var onChildDied: (@Sendable (Int32) -> Void)?

    public init(dbPath: String, binary: String?) {
        self.dbPath = dbPath
        self.binary = binary
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FileStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("worker.log")
    }

    public var status: Status { lock.withLock { _status } }
    public var logPath: String { logURL.path }

    /// Starts the worker unless `externalAlive` says another one is already serving this db.
    public func ensureRunning(externalAlive: Bool) {
        lock.lock()
        wantRunning = true
        let running = process?.isRunning == true
        lock.unlock()
        if running { return }
        if externalAlive {
            set(.external)
            return
        }
        launch()
    }

    public func stop() {
        lock.lock()
        wantRunning = false
        let p = process
        process = nil
        lock.unlock()
        guard let p, p.isRunning else { set(.stopped); return }
        p.terminate() // SIGTERM: the worker finishes the files in flight and records the run as stopped
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        set(.stopped)
    }

    private func launch() {
        // one child at a time: ensureRunning and a scheduled restart can both get here
        if lock.withLock({ process?.isRunning == true }) { return }
        guard let binary, FileManager.default.isExecutableFile(atPath: binary) else {
            set(.missingBinary)
            return
        }
        set(.starting)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-db", dbPath, "worker", "-with-parent"] // never outlives the app
        p.currentDirectoryURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] proc in self?.exited(proc) }
        do {
            try p.run()
        } catch {
            set(.crashed(error.localizedDescription))
            scheduleRestart()
            return
        }
        lock.withLock { process = p }
        set(.running(pid: p.processIdentifier))
    }

    private func exited(_ p: Process) {
        lock.lock()
        let wanted = wantRunning
        let current = process === p
        if current { process = nil }
        lock.unlock()
        guard wanted, current else { return }
        onChildDied?(p.processIdentifier)
        set(.crashed("worker exited with status \(p.terminationStatus); see \(logURL.path)"))
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay: Double = lock.withLock {
            failures += 1
            return min(30, pow(2, Double(failures - 1))) // 1, 2, 4 ... 30 s
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lock.withLock({ self.wantRunning && self.process == nil }) else { return }
            self.launch()
        }
    }

    /// Called when the worker is seen heartbeating: a healthy run resets the backoff.
    public func healthy() {
        lock.withLock { failures = 0 }
    }

    private func set(_ s: Status) {
        lock.withLock { _status = s }
        onStatus?(s)
    }

    /// Where to find the filestudio binary: $FILESTUDIO_BIN, inside the app bundle, beside the
    /// sqlswift checkout's sibling filestudio repo (dev builds), then the usual install dirs.
    public static func locateBinary(bundle: Bundle = .main) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["FILESTUDIO_BIN"], !env.isEmpty { candidates.append(env) }
        if let res = bundle.resourceURL { candidates.append(res.appendingPathComponent("filestudio").path) }
        // dev: <repo>/bin/FileStudio.app or <repo>/.build/... -> <repo>/../filestudio/bin/filestudio
        var dir = bundle.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("../filestudio/bin/filestudio").standardizedFileURL.path)
            dir = dir.deletingLastPathComponent()
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/go/bin/filestudio", "\(home)/.local/bin/filestudio", "/opt/homebrew/bin/filestudio", "/usr/local/bin/filestudio"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Where the db usually is: $FILESTUDIO_DB, then ~/.filestudio/filestudio.db (the CLI's order).
    public static func defaultDatabase() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FILESTUDIO_DB"], fm.fileExists(atPath: env) { return env }
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent(".filestudio/filestudio.db").path
        return fm.fileExists(atPath: home) ? home : nil
    }
}
