import SwiftUI
import AppKit
import FileStudioKit
import SQLDocCore

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
        .windowStyle(.hiddenTitleBar)
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

/// SqlSwift's window layout: one bar in the title bar (sidebar / open / reload, a path field, actions),
/// a 255 pt navigator on the `head` surface, the content on `page`, and a status bar under it all.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @AppStorage("showSidebar") private var showSidebar = true

    private var palette: FSPalette { FSPalette.resolve(dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showSidebar: $showSidebar)
                .padding(.leading, 76) // clear the traffic lights
                .padding(.trailing, 10)
                .padding(.top, 5)
                .padding(.bottom, 6)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)
            HStack(spacing: 0) {
                if showSidebar { Navigator() }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.page)
            }
            StatusBar()
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.fsPalette, palette)
        .tint(FSPalette.hex(DesignToken.accent.light))
        .accentColor(FSPalette.hex(DesignToken.accent.light))
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
                       message: "Choose the filestudio.db you index into. The app watches it live while the worker backs up and frees space.",
                       action: ("Open Database…", { OpenPanel.chooseDatabase(model) }))
        } else if let err = model.openError {
            EmptyState(title: "Can't open this database", message: err, symbol: "exclamationmark.triangle",
                       action: ("Choose Another Database…", { OpenPanel.chooseDatabase(model) }))
        } else if !model.loaded {
            ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.section {
            case .overview: OverviewView()
            case .backup: BackupView()
            case .reclaim: ReclaimView()
            case .apps: AppsView()
            case .activity: ActivityView()
            case .settings: SettingsView()
            }
        }
    }
}

/// BanquetBarView's layout: left cluster, the address field (here the db path), right actions.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showSidebar: Bool

    var body: some View {
        let s = model.snapshot
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ToolbarButton(icon: "sidebar.left", isActive: showSidebar, help: "Toggle Navigator Sidebar (⌥⌘S)") {
                    withAnimation(.easeInOut(duration: 0.15)) { showSidebar.toggle() }
                }
                ToolbarButton(icon: "folder", help: "Open Database… (⌘O)") { OpenPanel.chooseDatabase(model) }
                ToolbarButton(icon: "arrow.clockwise", help: "Rebuild the reclaim summary now") {
                    model.refreshReclaim(force: true)
                }
                .disabled(model.dbPath == nil)
            }
            AddressField()
            HStack(spacing: 4) {
                if s.busyAction != nil {
                    ToolbarButton(icon: "stop.fill", label: "Stop", isActive: true,
                                  tint: FSPalette.hex(DesignToken.statusError.light), help: "Stop (⌘.)") { model.run("stop") }
                } else {
                    ToolbarButton(icon: "icloud.and.arrow.up", label: "Back Up", help: "Back Up Now (⌘B)") { model.run("backup") }
                        .disabled(!model.loaded)
                }
                ToolbarButton(icon: "sparkle.magnifyingglass", label: "Find Deletable",
                              help: "Find Files I Can Delete (⇧⌘F)") { model.run("free") }
                    .disabled(!model.loaded || s.busyAction != nil)
            }
        }
    }
}

/// The Banquet address field, read-only: what's open, plus a live telemetry pill.
private struct AddressField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 6)
            Text(model.dbPath.map(RouteLine.short) ?? "No database open")
                .font(FSFont.mono)
                .foregroundColor(model.dbPath == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.dbPath ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if let busy = model.snapshot.busyAction {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(Humanize.action(busy.name).lowercased())
                        .font(FSFont.monoSmall).foregroundColor(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10)))
                .help(busy.message)
            }
            if model.loaded, let live = model.snapshot.live, model.snapshot.run?.isActive == true {
                Text("⚡ \(Fmt.rate(live.speed))")
                    .font(FSFont.monoSmall)
                    .foregroundColor(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10)))
            }
            #if DEBUG
            Tag(text: "Dev", tint: .orange, icon: "bolt.fill").padding(.trailing, 6)
                .help("FileStudio development instance (hot reload active)")
            #endif
        }
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 1))
    }
}

/// TableSidebarView: the db name, sections with count pills, then the indexed sources.
struct Navigator: View {
    @Environment(AppModel.self) private var model
    @Environment(\.fsPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "cylinder.split.1x2.fill")
                            .font(.system(size: 10)).foregroundColor(.accentColor)
                        Text((model.dbPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "FileStudio").uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

                    SectionHeader(title: "Sections", count: AppSection.allCases.count)
                    ForEach(AppSection.allCases) { s in
                        row(s).padding(.horizontal, 8)
                    }

                    let sources = model.snapshot.sources
                    if !sources.isEmpty {
                        SectionHeader(title: "Sources", count: sources.count).padding(.top, 8)
                        ForEach(sources) { src in
                            sourceRow(src).padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            Divider()
            WorkerBadge()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 255)
        .background(palette.head)
        .overlay(Rectangle().frame(width: 1).foregroundColor(palette.rule), alignment: .trailing)
    }

    private func row(_ s: AppSection) -> some View {
        let selected = model.section == s
        return Button { model.section = s } label: {
            HStack(spacing: 6) {
                Image(systemName: s.symbol)
                    .font(.system(size: 10))
                    .foregroundColor(selected ? .white : .accentColor)
                    .frame(width: 14)
                Text(s.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(selected ? .white : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let b = badge(for: s) { Pill(text: b.text, tint: b.tint, selected: selected) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear)
            .cornerRadius(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ src: SourceInfo) -> some View {
        let chosen = src.name == model.snapshot.config.from
        return HStack(spacing: 6) {
            Image(systemName: src.isLocal ? "internaldrive" : "cloud")
                .font(.system(size: 10))
                .foregroundColor(chosen ? .accentColor : .secondary)
                .frame(width: 14)
            Text(src.name)
                .font(.system(size: 11, weight: chosen ? .semibold : .medium, design: .monospaced))
                .foregroundColor(chosen ? .accentColor : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Compact.count(src.fileCount))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(chosen ? Color.accentColor.opacity(0.14) : .clear))
        .help("\(src.remote) · \(src.status)")
    }

    /// Glanceable numbers: failures (or coverage) on Backup, space on Reclaim.
    private func badge(for s: AppSection) -> (text: String, tint: Color?)? {
        switch s {
        case .backup:
            if !model.snapshot.problems.isEmpty { return ("\(model.snapshot.problems.count)", .orange) }
            return model.coverage.map { (Fmt.percent($0.total.fraction), nil) }
        case .reclaim:
            let mine = model.reclaimBySource.first { $0.source == model.snapshot.config.freeLocal }
            return mine.map { (Fmt.bytes($0.bytes), nil) }
        default: return nil
        }
    }
}

/// StatusBarView: timing badge, what the worker is doing, then the db path and build.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if model.loaded { timingBadge; Divider().frame(height: 12) }
            if let busy = model.snapshot.busyAction {
                Label(busy.message.isEmpty ? Humanize.action(busy.name) : busy.message, systemImage: "hourglass")
                    .font(FSFont.caption).foregroundColor(.secondary).lineLimit(1)
            } else if let run = model.snapshot.run {
                Text("last backup · \(StateChip.label(for: run.state).lowercased())")
                    .font(FSFont.caption).foregroundColor(.secondary)
            }
            Spacer()
            if let path = model.dbPath {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive").font(.system(size: 10)).foregroundColor(.secondary)
                    Text(path).font(FSFont.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .layoutPriority(-1)
                Divider().frame(height: 12)
            }
            Text("\(AppIdentity.version)·\(BuildInfo.commit)\(BuildInfo.dirty ? "+" : "")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.75))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    private var timingBadge: some View {
        let us = model.lastLoadMicros
        let slow = us >= 15_000
        let color = FSPalette.hex(slow ? DesignToken.statusWarn.light : DesignToken.statusOk.light)
        return HStack(spacing: 4) {
            Image(systemName: slow ? "bolt.trianglebadge.exclamationmark.fill" : "bolt.fill").font(.system(size: 10))
            Text("\(Compact.micros(us)) · snapshot").font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12))
        .cornerRadius(4)
        .help("The last live snapshot of the db took \(Compact.micros(us)) to read (off the main thread)")
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
                    case "appearance": // dark | light | system
                        NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua)
                            : arg == "light" ? NSAppearance(named: .aqua) : nil
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
