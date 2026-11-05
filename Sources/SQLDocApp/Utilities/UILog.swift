import Foundation
import os
import SQLDocCore

/// Dev-only UI telemetry for the edit → run → inspect feedback loop.
///
/// Two artifacts, both under `bin/` (gitignored) next to the dev app bundle:
///   - `ui.log`        one line per UI event, append-only, rotated on launch
///   - `ui-state.json` snapshot of what the window is showing right now
///
/// Both are plain text so Claude (or a human) can read them straight after
/// driving the app. Compiled out of release builds; installed apps never write.
enum UILog {
    private static let osLog = Logger(subsystem: "com.mavgo.sqlswift", category: "ui")

    #if DEBUG
    private static let queue = DispatchQueue(label: "sqlswift.uilog")
    private static let dir: URL? = {
        let env = ProcessInfo.processInfo.environment
        if let d = env["SQLSWIFT_UI_LOG_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        // Dev bundle lives at <repo>/bin/SqlSwift.app — log beside it.
        let bundle = Bundle.main.bundleURL
        guard bundle.path.contains("/bin/SqlSwift.app") else { return nil }
        return bundle.deletingLastPathComponent()
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var isEnabled: Bool { dir != nil }
    static var commandFilePath: String? { dir?.appendingPathComponent("ui-command.txt").path }

    /// Call once at launch: keeps the previous run as `ui.log.prev`.
    static func startSession() {
        guard let dir else { return }
        queue.async {
            let log = dir.appendingPathComponent("ui.log")
            let prev = dir.appendingPathComponent("ui.log.prev")
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: log, to: prev)
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        event("app", "launch", ["version": AppIdentity.version])
    }

    static func event(_ category: String, _ message: String, _ fields: [String: Any] = [:]) {
        let extras = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        osLog.debug("[\(category, privacy: .public)] \(message, privacy: .public) \(extras, privacy: .public)")
        guard let dir else { return }
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)\(extras.isEmpty ? "" : "  " + extras)\n"
        queue.async {
            let url = dir.appendingPathComponent("ui.log")
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    static func writeSnapshot(_ state: [String: Any]) {
        guard let dir else { return }
        var s = state
        s["time"] = ISO8601DateFormatter().string(from: Date())
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: dir.appendingPathComponent("ui-state.json"), options: .atomic)
        }
    }
    #else
    static var isEnabled: Bool { false }
    static var commandFilePath: String? { nil }
    static func startSession() {}
    static func event(_ category: String, _ message: String, _ fields: [String: Any] = [:]) {}
    static func writeSnapshot(_ state: [String: Any]) {}
    #endif
}

