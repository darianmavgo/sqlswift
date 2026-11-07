import SwiftUI
import AppKit
import SQLDocCore

@main
struct SqlSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appVM = AppViewModel()

    var body: some Scene {
        WindowGroup {
            MainView(appVM: appVM)
                .navigationTitle(appVM.activeDocEntry.map { "\($0.name) — SqlSwift" } ?? "SqlSwift")
                .frame(minWidth: 700, minHeight: 450)
                .onOpenURL { url in
                    if url.scheme == "banquet" || url.scheme == "x-banquet" {
                        appVM.openBanquet(urlString: url.absoluteString)
                    } else {
                        appVM.open(url: url)
                    }
                }
                .onAppear {
                    // Maximize window to fill screen on launch and merge toolbar into titlebar
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                            AppDelegate.configureUnifiedTitleBar(for: window)
                            if let screen = window.screen ?? NSScreen.main {
                                window.setFrame(screen.visibleFrame, display: true, animate: false)
                            }
                        }
                    }

                    // Check if files or folders were passed via command line arguments
                    let cliArgs = Array(CommandLine.arguments.dropFirst())
                    for arg in cliArgs where !arg.hasPrefix("-") {
                        let resolved = FolderScanner.resolveLocalPath(arg)
                        if FileManager.default.fileExists(atPath: resolved) {
                            appVM.open(path: resolved)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .sqldocOpenFileOrFolder)) { note in
                    if let path = note.object as? String {
                        appVM.open(path: path)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppIdentity.displayName)") { Self.showAboutPanel() }
            }

            // Help menu: version line + one-click copy for bug reports.
            CommandGroup(replacing: .help) {
                Button("\(AppIdentity.displayName) \(BuildInfo.summary)") { Self.showAboutPanel() }
                Button("Copy Version Info") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString("\(AppIdentity.displayName) \(AppIdentity.version) · \(BuildInfo.detail)", forType: .string)
                }
                Divider()
                Button("Project Homepage") {
                    if let url = URL(string: AppIdentity.homepage) { NSWorkspace.shared.open(url) }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Database or Folder…") {
                    appVM.showOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Browse Folder…") {
                    appVM.showOpenFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("All SQLite Files & Folders") {
                    appVM.isFolderBrowserVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Divider()

                Button("Export Table as CSV…") {
                    appVM.exportCurrentTable()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)

                Button("Close Database") {
                    appVM.closeCurrentDoc()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Paste Path or Query into Banquet Bar") {
                    appVM.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button("Copy Banquet URL") {
                    appVM.copyBanquetURL(for: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(appVM.activeDocEntry == nil)
            }

            CommandGroup(after: .textEditing) {
                Button("Focus & Edit Banquet Bar") {
                    appVM.isBanquetBarEditing = true
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Back") { appVM.navigateBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!appVM.canNavigateBack)

                Button("Forward") { appVM.navigateForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!appVM.canNavigateForward)

                Button("Find in Table…") {
                    appVM.isFindBarVisible.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)

                Button("Jump to Row…") {
                    appVM.showJumpToRow = true
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)
            }

            CommandGroup(after: .toolbar) {
                Button("Table Schema…") {
                    appVM.showSchemaSheet = true
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(appVM.selectedTableName.isEmpty)

                Button("Query Console…") {
                    appVM.showQueryConsole = true
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(appVM.activeDocEntry == nil)

                Button("Toggle Table Sidebar") {
                    appVM.showSidebar.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(appVM.activeDocEntry == nil)

                Divider()

                Picker("Column View", selection: Binding(
                    get: { appVM.activeTableVM?.displayKind ?? .raw },
                    set: { appVM.activeTableVM?.setDisplayKind($0) }
                )) {
                    ForEach(DisplayKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .disabled(appVM.activeTableVM == nil)

                Toggle("Row Detail Panel", isOn: $appVM.showRowDetail)
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(!appVM.isThinTable)

                Divider()

                Menu("Appearance") {
                    Button("Match System") {
                        appVM.setThemeMode(.system)
                    }
                    Button("Light Mode") {
                        appVM.setThemeMode(.light)
                    }
                    Button("Dark Mode") {
                        appVM.setThemeMode(.dark)
                    }
                }

                Divider()

                Button("Zoom In") {
                    appVM.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    appVM.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    appVM.zoomReset()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

extension SqlSwiftApp {
    /// Standard macOS About panel, populated with the marketing version and the
    /// exact build revision.
    static func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.displayName,
            .applicationVersion: AppIdentity.version,
            .version: "\(BuildInfo.commit)\(BuildInfo.dirty ? " (modified)" : "")",
            .init(rawValue: "Copyright"): AppIdentity.copyright,
            .credits: NSAttributedString(
                string: "\(AppIdentity.tagline)\n\n\(BuildInfo.detail)",
                attributes: [.font: NSFont.systemFont(ofSize: 10)]
            )
        ])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotReloadTimer: Timer?
    private var initialStampDate: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.processName = "SqlSwift"
        // Ensure window bounds to screen visible frame on launch and unified titlebar
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                Self.configureUnifiedTitleBar(for: window)
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true, animate: false)
                }
            }
        }
        UILog.startSession()
        startHotReloadWatcher()
    }

    static func configureUnifiedTitleBar(for window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        let isDev = Bundle.main.bundleIdentifier == "com.mavgo.sqlswift.dev"
        window.title = isDev ? "SqlSwift (Dev)" : "SqlSwift"
    }

    private func startHotReloadWatcher() {
        #if !DEBUG
        // Installed / production release builds NEVER run the hot-reload watcher.
        return
        #else
        // In debug builds, only run hot-reload if running out of the development
        // workspace (bin/ or .build/), and NEVER when running as an installed application.
        let bundlePath = Bundle.main.bundleURL.path
        if bundlePath.hasPrefix("/Applications") || bundlePath.contains("/Applications/") {
            return
        }

        let isRepoDev = bundlePath.contains("/sqlswift/bin/") || bundlePath.contains("/.build/")
        let isDevBundle = Bundle.main.bundleIdentifier == "com.mavgo.sqlswift.dev"
        let isExplicitEnv = ProcessInfo.processInfo.environment["SQLSWIFT_HOT_RELOAD"] == "1"
        guard isRepoDev || isDevBundle || isExplicitEnv else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let repoBinDir = "\(home)/Documents/view_sqlite/sqlswift/bin"
        let stampPath = "\(repoBinDir)/.hot-reload.stamp"
        let appBundlePath = "\(repoBinDir)/SqlSwift.app"
        let appBinaryPath = "\(appBundlePath)/Contents/MacOS/SqlSwift"

        initialStampDate = Self.modDate(of: stampPath) ?? Self.modDate(of: appBinaryPath)

        hotReloadTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentDate = Self.modDate(of: stampPath)
                guard let currentDate else { return }
                if let prev = self.initialStampDate, currentDate <= prev {
                    return
                }
                self.initialStampDate = currentDate
                guard FileManager.default.isExecutableFile(atPath: appBinaryPath) else { return }

                UserDefaults.standard.synchronize()

                // Relaunch into the freshly compiled dev binary as an independent instance
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-n", appBundlePath]
                try? proc.run()
                exit(0)
            }
        }
        #endif
    }

    private static func modDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let resolved = FolderScanner.resolveLocalPath(filename)
            if FileManager.default.fileExists(atPath: resolved) {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .sqldocOpenFileOrFolder, object: resolved)
                }
            }
        }
    }
}

extension Notification.Name {
    static let sqldocOpenFileOrFolder = Notification.Name("sqldocOpenFileOrFolder")
}
