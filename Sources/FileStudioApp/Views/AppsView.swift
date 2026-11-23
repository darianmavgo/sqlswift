import SwiftUI
import AppKit
import FileStudioKit

/// Apps & Games: every app and game on this Mac with its size, ticks for removal, and the
/// typed-phrase remove (worker actions apps_scan / apps_remove; table app_library).
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var apps: [LibraryApp] = []
    @State private var loaded = false
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var sort = [KeyPathComparator(\LibraryApp.size, order: .reverse)]
    @State private var confirming = false
    @State private var icons: [String: NSImage] = [:]

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", games = "Games", apps = "Apps", picked = "Picked", macOS = "Part of macOS"
        var id: String { rawValue }
    }

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 0) {
            header.padding([.horizontal, .top], 20).padding(.bottom, 12)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                EmptyState(title: "No apps listed yet",
                           message: "Find Apps & Games lists everything in Applications, Steam and Epic with its size. It removes nothing.",
                           symbol: "square.grid.2x2",
                           action: model.workerHealthy && s.busyAction == nil ? ("Find Apps & Games", { model.run("apps_scan") }) : nil)
            } else {
                toolbar.padding(.horizontal, 16).padding(.vertical, 8)
                table
            }
            if let gate = s.appsGate, gate.apps > 0 { removeBar(gate) }
        }
        .sheet(isPresented: $confirming) {
            if let gate = model.snapshot.appsGate { ConfirmRemoveAppsSheet(gate: gate, apps: apps.filter(\.pick)) }
        }
        .task(id: reloadKey) { await reload() }
    }

    /// Re-read app_library when a scan or remove finishes, or a tick changes the gate.
    private var reloadKey: String {
        let s = model.snapshot
        return [s.actions["apps_scan"]?.updatedAt, s.actions["apps_remove"]?.updatedAt,
                s.appsGate.map { "\($0.apps)/\($0.bytes)" }].map { $0 ?? "" }.joined(separator: "|")
    }

    private func reload() async {
        guard let db = model.database else { return }
        let rows = await Task.detached(priority: .userInitiated) { (try? db.appLibrary()) ?? [] }.value
        if Task.isCancelled { return }
        apps = rows
        loaded = true
        for a in rows where icons[a.path] == nil {
            icons[a.path] = NSWorkspace.shared.icon(forFile: a.path)
        }
    }

    private var removable: [LibraryApp] { apps.filter(\.removable) }

    private var header: some View {
        let s = model.snapshot
        let bytes = removable.reduce(Int64(0)) { $0 + $1.size }
        let games = removable.filter { $0.kind == "game" }
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.bytes(bytes)).font(.system(size: 28, weight: .semibold, design: .monospaced))
                    Text("in apps and games you can remove").foregroundStyle(.secondary)
                }
                Text(apps.isEmpty ? "Not scanned yet."
                     : "\(Fmt.files(Int64(removable.count), "app")) (\(Fmt.files(Int64(games.count), "game")), \(Fmt.bytes(games.reduce(0) { $0 + $1.size }))). Apps from the App Store, Steam or a vendor can be installed again.")
                    .font(FSFont.body).foregroundStyle(.secondary)
            }
            Spacer()
            if let a = s.actions["apps_scan"], a.isBusy {
                ProgressView().controlSize(.small)
                Text(a.message).font(FSFont.body).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 260)
            } else if let a = s.actions["apps_remove"], a.isBusy {
                ProgressView().controlSize(.small)
                Text(a.message).font(FSFont.body).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 300)
            }
            Button { model.run("apps_scan") } label: {
                Label(apps.isEmpty ? "Find Apps & Games" : "Scan Again", systemImage: "magnifyingglass")
            }
            .disabled(s.busyAction != nil || !model.workerHealthy)
            .help("Lists every app and game with its size and data folders. Removes nothing.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 440)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            Spacer()
            if let msg = lastRemoveMessage {
                Text(msg).font(FSFont.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 420, alignment: .trailing)
            }
        }
    }

    private var lastRemoveMessage: String? {
        guard let a = model.snapshot.actions["apps_remove"], !a.isBusy, !a.message.isEmpty else { return nil }
        return Humanize.message(a.message)
    }

    private var shown: [LibraryApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return apps.filter { a in
            switch filter {
            case .all: a.removable
            case .games: a.removable && a.kind == "game"
            case .apps: a.removable && a.kind != "game"
            case .picked: a.pick
            case .macOS: !a.removable
            }
        }
        .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        .sorted(using: sort)
    }

    private var table: some View {
        Table(shown, sortOrder: $sort) {
            TableColumn("") { a in
                Toggle("", isOn: Binding(get: { a.pick }, set: { on in setPick(a, on) }))
                    .labelsHidden().disabled(!a.removable)
                    .help(a.removable ? "Remove this app" : a.note)
            }.width(24)
            TableColumn("Name", value: \.name) { a in
                HStack(spacing: 8) {
                    if let img = icons[a.path] { Image(nsImage: img).resizable().frame(width: 20, height: 20) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).lineLimit(1)
                        Text(a.path).font(FSFont.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .help(a.path + (a.version.isEmpty ? "" : " · version \(a.version)"))
                .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) } }
            }
            TableColumn("Kind", value: \.kind) { a in Text(a.kind == "game" ? "Game" : "App").foregroundStyle(.secondary) }.width(50)
            TableColumn("Size", value: \.size) { a in Text(Fmt.bytes(a.size)).monospacedDigit() }.width(80)
            TableColumn("Its data", value: \.dataSize) { a in dataCell(a) }.width(130)
            TableColumn("Last used", value: \.lastUsed) { a in
                Text(a.lastUsed.isEmpty ? "—" : Fmt.ago(a.lastUsed)).foregroundStyle(.secondary).help(a.lastUsed)
            }.width(100)
            TableColumn("From", value: \.store) { a in Text(source(a)).foregroundStyle(.secondary).lineLimit(1) }.width(90)
            TableColumn("Note", value: \.note) { a in
                HStack(spacing: 4) {
                    if !a.removable { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    else if a.needsAdmin { Image(systemName: "key.fill").foregroundStyle(.secondary).help("Removing it asks for your Mac password") }
                    Text(a.note).font(FSFont.caption).foregroundStyle(.secondary).lineLimit(2).help(a.note)
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)
    }

    @ViewBuilder private func dataCell(_ a: LibraryApp) -> some View {
        if !a.removable || (a.dataSize == 0 && a.store != "steam") {
            Text(a.dataSize > 0 ? Fmt.bytes(a.dataSize) : "—").foregroundStyle(.secondary).monospacedDigit()
        } else {
            Toggle(isOn: Binding(get: { a.withData }, set: { on in setWithData(a, on) })) {
                Text(a.dataSize > 0 ? Fmt.bytes(a.dataSize) : "settings").monospacedDigit()
            }
            .toggleStyle(.checkbox)
            .help("Also remove its settings, caches and saved data from ~/Library. Without this, reinstalling it picks up where you left off.")
        }
    }

    private func source(_ a: LibraryApp) -> String {
        switch a.store {
        case "app store": "App Store"
        case "steam": "Steam"
        case "epic": "Epic"
        default: a.vendor == "apple" ? "Apple" : "Downloaded"
        }
    }

    private func setPick(_ a: LibraryApp, _ on: Bool) {
        update(a.path) { $0.with(pick: on) }
        model.perform("pick") { try $0.setAppPick(path: a.path, pick: on) }
    }

    private func setWithData(_ a: LibraryApp, _ on: Bool) {
        update(a.path) { $0.with(withData: on) }
        model.perform("with_data") { try $0.setAppWithData(path: a.path, on: on) }
    }

    /// Show a tick at once; the db write follows and the reload confirms it.
    private func update(_ path: String, _ f: (LibraryApp) -> LibraryApp) {
        if let i = apps.firstIndex(where: { $0.path == path }) { apps[i] = f(apps[i]) }
    }

    private func removeBar(_ gate: AppsGate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text("Removed permanently (no Trash). Apps that macOS owns ask for your password once.")
                .font(FSFont.body).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Clear") { model.perform("clear picks") { try $0.clearAppPicks() } }
                .disabled(model.snapshot.busyAction != nil)
            Button(role: .destructive) { confirming = true } label: {
                Text("Remove \(Fmt.files(gate.apps, "App")) (\(Fmt.bytes(gate.bytes)))…")
            }
            .buttonStyle(.borderedProminent)
            .tint(.fsError)
            .disabled(model.snapshot.busyAction != nil || !model.workerHealthy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// Typing the exact phrase is the confirmation the db's trigger and the worker both check.
private struct ConfirmRemoveAppsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gate: AppsGate
    let apps: [LibraryApp]
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Remove \(Fmt.files(gate.apps, "app")) permanently?", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.fsError)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(apps) { a in
                        HStack {
                            Text(a.name)
                            if a.withData { Text("+ its data").foregroundStyle(.secondary) }
                            Spacer()
                            Text(Fmt.bytes(a.size + (a.withData ? a.dataSize : 0))).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(FSFont.body)
                    }
                }
            }
            .frame(maxHeight: 160)
            Text("They are deleted from this Mac (no Trash). Quit them first; a running app is skipped. Apps owned by macOS make it ask for your password once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("To confirm, type:").font(FSFont.body)
            Text(gate.phrase).font(.system(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
            TextField("Type the phrase above", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent).tint(.fsError)
                    .disabled(typed != gate.phrase)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func confirm() {
        guard typed == gate.phrase else { return }
        let phrase = typed
        model.perform("apps_remove") { try $0.removeApps(confirm: phrase) }
        dismiss()
    }
}
