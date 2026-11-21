import Foundation
import os

/// Dev-only telemetry for FileStudio, the same loop as sqlswift's UILog: when the dev bundle runs
/// from `<repo>/bin/FileStudio.app` (or FILESTUDIO_UI_LOG_DIR is set) it writes, in
/// `~/Library/Caches/com.mavgo.filestudio.dev/` (or that dir),
///   - `fs-ui.log`        `[category] event  key=value` lines, including
///                        `[perf] main thread stalled  ms=…` whenever the main thread is unresponsive
///                        for over 120 ms (check for it after any rendering or loading change)
///   - `fs-ui-state.txt`  what the window shows right now (section, run numbers, worker)
/// and runs commands written one per line to `fs-ui-command.txt` (`section <name>`, `run <action>`,
/// `open <db path>`). Compiled out of release builds.
enum FSLog {
    private static let osLog = Logger(subsystem: "com.mavgo.filestudio", category: "ui")

    #if DEBUG
    private static let queue = DispatchQueue(label: "filestudio.fslog")
    static let dir: URL? = {
        if let d = ProcessInfo.processInfo.environment["FILESTUDIO_UI_LOG_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        guard Bundle.main.bundleURL.path.hasSuffix("/bin/FileStudio.app") else { return nil }
        // not beside the bundle: the repo is under ~/Documents, and the app reading there needs a
        // privacy grant that an ad-hoc signed rebuild may ask for again
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.mavgo.filestudio.dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func startSession() {
        guard let dir else { return }
        queue.sync {
            let log = dir.appendingPathComponent("fs-ui.log")
            let prev = dir.appendingPathComponent("fs-ui.log.prev")
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: log, to: prev)
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        event("app", "launch")
        let thread = Thread {
            let answered = DispatchSemaphore(value: 0)
            while true {
                let asked = DispatchTime.now()
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1_000_000
                if ms > 120 { event("perf", "main thread stalled", ["ms": Int(ms)]) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "filestudio.hang-monitor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    static var commandFile: URL? { dir?.appendingPathComponent("fs-ui-command.txt") }

    static func state(_ text: String) {
        guard let dir else { return }
        queue.async {
            try? text.write(to: dir.appendingPathComponent("fs-ui-state.txt"), atomically: true, encoding: .utf8)
        }
    }
    #else
    static func startSession() {}
    static var commandFile: URL? { nil }
    static func state(_ text: String) {}
    #endif

    static func event(_ category: String, _ message: String, _ fields: [String: Any] = [:]) {
        let extras = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        osLog.debug("[\(category, privacy: .public)] \(message, privacy: .public) \(extras, privacy: .public)")
        #if DEBUG
        guard let dir else { return }
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)\(extras.isEmpty ? "" : "  " + extras)\n"
        queue.async {
            guard let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("fs-ui.log")) else { return }
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
        }
        #endif
    }
}
