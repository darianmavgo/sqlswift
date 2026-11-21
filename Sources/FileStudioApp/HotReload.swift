import AppKit
import Foundation

/// Debug dev bundle only: when `scripts/fs-hot-reload.sh` (make fs-watch) touches the stamp after a
/// rebuild, save where the window is, stop the worker cleanly and relaunch into the new build.
enum HotReload {
    @MainActor static func start(_ model: AppModel) {
        #if DEBUG
        guard let dir = FSLog.dir, Bundle.main.bundleURL.path.hasSuffix("/bin/FileStudio.app") else { return }
        let stamp = dir.appendingPathComponent(".fs-hot-reload.stamp").path
        let bundle = Bundle.main.bundleURL.path
        Task.detached(priority: .utility) {
            let first = modDate(stamp) ?? .distantPast
            while true {
                try? await Task.sleep(for: .milliseconds(400))
                guard let d = modDate(stamp), d > first,
                      FileManager.default.isExecutableFile(atPath: bundle + "/Contents/MacOS/FileStudio") else { continue }
                FSLog.event("hot", "reload")
                await model.prepareForReload()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-n", bundle]
                try? p.run()
                p.waitUntilExit()
                exit(0)
            }
        }
        #endif
    }

    private static func modDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
