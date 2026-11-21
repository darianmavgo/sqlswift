import SwiftUI
import AppKit
import FileStudioKit

@main
struct FileStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        FSLog.startSession()
    }

    var body: some Scene {
        Window("FileStudio", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    delegate.model = model
                    DevCommands.start(model)
                    HotReload.start(model)
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Database…") { OpenPanel.chooseDatabase(model) }.keyboardShortcut("o")
            }
            CommandMenu("Backup") {
                Button("Back Up Now") { model.run("backup") }
                    .keyboardShortcut("b")
                    .disabled(model.snapshot.busyAction != nil)
                Button("Stop") { model.run("stop") }
                    .keyboardShortcut(".")
                    .disabled(model.snapshot.busyAction == nil)
                Button("Retry Failed") { model.run("retry_failed") }
                    .disabled(model.snapshot.busyAction != nil || (model.snapshot.run?.filesFailed ?? 0) == 0)
                Divider()
                Button("Find Files I Can Delete") { model.run("free") }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.snapshot.busyAction != nil)
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { model.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?
    private var sigterm: DispatchSourceSignal?

    /// SIGTERM (pkill, logout, a supervisor) becomes a normal quit, so the worker is stopped cleanly.
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Stop the worker cleanly (it records an unfinished backup as resumable).
    @MainActor func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding($model.section)) { s in
                Label(s.title, systemImage: s.symbol)
                    .badge(badge(for: s))
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if let busy = model.snapshot.busyAction {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(Humanize.action(busy.name)).font(.callout)
                        }
                        .help(busy.message)
                    }
                    WorkerBadge()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            detail
                // one fixed title: SwiftUI does not re-measure the title when it changes, so per-section
                // titles get truncated; the sidebar already says where you are
                .navigationTitle("FileStudio")
                // short enough to read whole; the full path is in the title bar's proxy icon menu
                .navigationSubtitle(model.dbPath.map(RouteLine.short) ?? "")
                .documentProxy(model.dbPath)
        }
        .alert("FileStudio", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .onChange(of: model.section) {
            UserDefaults.standard.set(model.section.rawValue, forKey: "section")
            FSLog.event("nav", "section", ["to": model.section.rawValue])
        }
    }

    @ViewBuilder private var detail: some View {
        if model.dbPath == nil {
            EmptyState(title: "Open a filestudio database",
                       message: "Choose the filestudio.db you index into (File › Open Database…). The app watches it live while the worker backs up and frees space.")
                .toolbar { Button("Open Database…") { OpenPanel.chooseDatabase(model) } }
        } else if let err = model.openError {
            EmptyState(title: "Can't open this database", message: err, symbol: "exclamationmark.triangle")
                .toolbar { Button("Open Database…") { OpenPanel.chooseDatabase(model) } }
        } else if !model.loaded {
            ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.section {
            case .overview: OverviewView()
            case .backup: BackupView()
            case .reclaim: ReclaimView()
            case .activity: ActivityView()
            case .settings: SettingsView()
            }
        }
    }

    /// Glanceable numbers in the sidebar: failures (or coverage) on Backup, space on Reclaim.
    private func badge(for s: AppSection) -> Text? {
        switch s {
        case .backup:
            if !model.snapshot.problems.isEmpty { return Text("\(model.snapshot.problems.count)").foregroundStyle(.orange) }
            return model.coverage.map { Text(Fmt.percent($0.total.fraction)) }
        case .reclaim:
            let mine = model.reclaimBySource.first { $0.source == model.snapshot.config.freeLocal }
            return mine.map { Text(Fmt.bytes($0.bytes)) }
        default: return nil
        }
    }
}

enum OpenPanel {
    @MainActor static func chooseDatabase(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = "Open a filestudio database"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "db")].compactMap { $0 } + [.data]
        if let p = model.dbPath { panel.directoryURL = URL(fileURLWithPath: p).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            model.open(path: url.path)
        }
    }
}

/// Debug builds: run commands written to fs-ui-command.txt beside the dev bundle, and keep
/// fs-ui-state.txt current, so the app can be driven and checked without clicking.
enum DevCommands {
    @MainActor static func start(_ model: AppModel) {
        #if DEBUG
        guard let file = FSLog.commandFile else { return }
        // dev channel: never let App Nap stall it while the window is in the background
        let keepAwake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "FileStudio dev commands")
        _ = keepAwake
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(400))
                writeState(model)
                // file I/O off the main thread: a privacy prompt can hold open() indefinitely
                let text: String? = await Task.detached {
                    guard let t = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                    try? FileManager.default.removeItem(at: file)
                    return t
                }.value
                guard let text else { continue }
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    guard let verb = parts.first else { continue }
                    let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                    FSLog.event("cmd-file", verb, ["arg": arg])
                    switch verb {
                    case "section": if let s = AppSection(rawValue: arg) { model.section = s }
                    case "run": model.run(arg)
                    case "open": model.open(path: arg)
                    case "apply": model.perform("apply") { try $0.apply(confirm: arg) } // same as the typed sheet
                    case "shot": shot(to: arg)
                    case "folder": model.reclaimFolder = arg // "<source>/<top folder>"
                    case "keep": // "<source> <path>": the same call as the Keep toggle on a plan row
                        let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
                        if kv.count == 2, let plan = model.snapshot.gate?.planID {
                            model.perform("keep") { try $0.setKeep(planID: plan, source: kv[0], path: kv[1], keep: true) }
                        }
                    default: FSLog.event("error", "unknown command", ["verb": verb])
                    }
                }
            }
        }
        #endif
    }

    /// Renders the main window into a PNG (no screen-recording permission needed).
    @MainActor private static func shot(to path: String) {
        // the frame view (contentView's superview) includes the title bar and toolbar
        guard let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let v = Optional(content.superview ?? content),
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        FSLog.event("cmd-file", "shot", ["path": path])
    }

    @MainActor private static func writeState(_ model: AppModel) {
        let s = model.snapshot
        var lines = [
            "db=\(model.dbPath ?? "")",
            "loaded=\(model.loaded) error=\(model.openError ?? "")",
            "section=\(model.section.rawValue)",
            "worker=\(model.workerLabel) alive=\(s.workerAlive)",
            "busy=\(s.busyAction.map { "\($0.name):\($0.state):\($0.message)" } ?? "")",
            "config from=\(s.config.from) target=\(s.config.target) prefix=\(s.config.prefix) free=\(s.config.freeLocal)",
        ]
        if let r = s.run {
            lines.append("run id=\(r.id) state=\(r.state) proven=\(r.filesDone)/\(r.filesTotal) sent=\(r.filesUploaded) failed=\(r.filesFailed)")
        }
        if let l = s.live { lines.append("live speed=\(Int(l.speed)) eta=\(l.eta ?? -1) active=\(l.active)") }
        if let c = model.coverage { lines.append("coverage proven=\(c.total.provenFiles)/\(c.total.files) folders=\(c.folders.count)") }
        lines.append("reclaim bytes=\(model.reclaim.totalBytes) files=\(model.reclaim.totalFiles) loading=\(model.reclaimLoading)")
        lines.append("plan=\(s.gate?.planID ?? 0) files=\(s.gate?.files ?? 0) phrase=\(s.gate?.phrase ?? "") folders=\(s.planFolders.count)")
        lines.append("alert=\(model.alert ?? "")")
        FSLog.state(lines.joined(separator: "\n") + "\n")
    }
}

private extension View {
    /// The title bar's proxy icon (and its path menu) for the open db; nothing when none is open.
    @ViewBuilder func documentProxy(_ path: String?) -> some View {
        if let path { navigationDocument(URL(fileURLWithPath: path)) } else { self }
    }
}
