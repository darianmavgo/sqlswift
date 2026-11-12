#if DEBUG
import AppKit

/// Dev-only: renders the app's own window to a PNG beside `ui.log`, so the feedback loop can
/// look at the UI without Screen Recording permission (the app draws itself, nothing is captured
/// from the screen). Triggered by the `snapshot` UI command.
@MainActor
enum UIScreenshot {
    static func capture(name: String) {
        guard let dir = UILog.directory else { return }
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let file = dir.appendingPathComponent((safe.isEmpty ? "ui-snapshot" : safe) + ".png")
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            UILog.event("snapshot", "no window")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            UILog.event("snapshot", "encode failed")
            return
        }
        do {
            try png.write(to: file, options: .atomic)
            UILog.event("snapshot", "saved", ["file": file.lastPathComponent, "w": "\(rep.pixelsWide)", "h": "\(rep.pixelsHigh)"])
        } catch {
            UILog.event("snapshot", "write failed", ["error": error.localizedDescription])
        }
    }
}
#endif
