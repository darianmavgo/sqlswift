import SwiftUI
import FileStudioKit

/// Free space safely: what is ready now (live), the frozen plan by folder, the files with their
/// proof, protect toggles, and the typed-phrase delete.
struct ReclaimView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 0) {
            summary
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            Divider()
            if s.planFolders.isEmpty {
                NoPlanView()
            } else {
                HSplitView {
                    folderList.frame(minWidth: 220, idealWidth: 260, maxHeight: .infinity)
                    PlanFilesView(folder: s.planFolders.first { $0.id == model.reclaimFolder })
                        .frame(minWidth: 420, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let gate = s.gate, gate.files > 0 { deleteBar(gate) }
        }
        .sheet(isPresented: $confirming) {
            if let gate = model.snapshot.gate { ConfirmDeleteSheet(gate: gate) }
        }
        .onChange(of: s.gate?.planID) { model.reclaimFolder = nil; selectFirst() }
        .onAppear { selectFirst() }
    }

    /// Open on the biggest folder rather than an empty pane.
    private func selectFirst() {
        let folders = model.snapshot.planFolders
        if model.reclaimFolder == nil || !folders.contains(where: { $0.id == model.reclaimFolder }) {
            model.reclaimFolder = folders.first?.id
        }
    }

    private var summary: some View {
        let s = model.snapshot
        let busy = s.busyAction
        // only the source being freed; the summary view covers every local source
        let mine = model.reclaim.folders.filter { $0.source == s.config.freeLocal }
        let bytes = mine.reduce(Int64(0)) { $0 + $1.bytes }
        let files = mine.reduce(Int64(0)) { $0 + $1.files }
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.bytes(bytes))
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("ready to reclaim on").foregroundStyle(.secondary)
                    sourceMenu
                    if model.reclaimLoading { ProgressView().controlSize(.small) }
                }
                Text(mine.isEmpty
                     ? ((model.snapshot.gate?.planID ?? 0) > 0
                        ? "Nothing more to reclaim right now. Protected files and files changed since their backup are left out."
                        : "Back up first; files appear here once their copy is proven.")
                     : "\(Fmt.files(files)) in \(Fmt.files(Int64(mine.count), "folder")). Only checksum-proven copies, same-content duplicates and regenerable files qualify.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let a = s.actions["free"], a.isBusy {
                ProgressView().controlSize(.small)
                Text(a.message).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 260)
            }
            let noPlan = s.planFolders.isEmpty
            Button { model.run("free") } label: {
                Label(noPlan ? "Find Files I Can Delete" : "Find Again", systemImage: "magnifyingglass")
            }
            .buttonStyle(ProminentIf(noPlan && !mine.isEmpty))
            .disabled(busy != nil || !model.workerHealthy)
                .help("Verifies candidates against your backup by checksum and saves a plan. Deletes nothing.")
        }
    }

    /// The local source to free, with what each one has ready.
    private var sourceMenu: some View {
        let s = model.snapshot
        let ready = Dictionary(model.reclaimBySource.map { ($0.source, $0.bytes) }, uniquingKeysWith: +)
        return Menu {
            ForEach(s.sources.filter(\.isLocal)) { src in
                Button {
                    model.setFreeLocal(src.name)
                } label: {
                    Text(src.name + (ready[src.name].map { "  —  \(Fmt.bytes($0))" } ?? ""))
                    if src.name == s.config.freeLocal { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Text(s.config.freeLocal.isEmpty ? "choose a source" : s.config.freeLocal)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(s.busyAction != nil)
        .help("The local source Find Files I Can Delete looks at")
    }

    private var folderList: some View {
        let folders = model.snapshot.planFolders
        let peak = Double(folders.map(\.bytes).max() ?? 1)
        @Bindable var model = model
        return List(selection: $model.reclaimFolder) {
            Section(planTitle) {
                ForEach(folders) { f in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(f.folder == "." ? "(top level)" : f.folder).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.bytes(f.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Meter(fraction: Double(f.bytes) / max(peak, 1), tint: f.kept > 0 ? .orange : .accentColor, height: 4)
                        Text(Fmt.files(f.files) + (f.kept > 0 ? " · \(Fmt.count(f.kept)) protected" : "") + (f.deleted > 0 ? " · \(Fmt.count(f.deleted)) deleted" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(f.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The gate counts what will really go (not protected, not done) but rounds to 0.01 GB; below
    /// that, the plan's folder total is the better number.
    private func planBytes(_ gate: ApplyGate) -> Int64 {
        if gate.gb >= 0.01 { return Int64(gate.gb * 1e9) }
        return model.snapshot.planFolders.reduce(Int64(0)) { $0 + $1.bytes }
    }

    private var planTitle: String {
        let s = model.snapshot
        let srcs = Set(s.planFolders.map(\.source))
        return "Plan \(s.gate?.planID ?? 0)" + (srcs.count == 1 ? " · \(srcs.first!)" : "")
    }

    private func deleteBar(_ gate: ApplyGate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            Text("Each file is checked again against the disk right before it is deleted. Deletes are permanent (no Trash) and logged with where the copy is.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button(role: .destructive) { confirming = true } label: {
                Text("Delete \(Fmt.files(gate.files).capitalized) (\(Fmt.bytes(planBytes(gate))))…")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.snapshot.busyAction != nil || !model.workerHealthy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// The files of one plan folder, biggest first, paged by keyset; protect toggles write plan_items.keep.
private struct PlanFilesView: View {
    @Environment(AppModel.self) private var model
    let folder: PlanFolder?
    @State private var files: [PlanFile] = []
    @State private var loading = false
    @State private var exhausted = false
    @State private var overrides: [PlanFile.ID: Bool] = [:]

    var body: some View {
        Group {
            if let folder {
                VStack(spacing: 0) {
                    HStack {
                        Text(folder.folder == "." ? "(top level)" : folder.folder).font(.headline).lineLimit(1)
                        Text("\(Fmt.files(folder.files)) · \(Fmt.bytes(folder.bytes))").foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                        Spacer()
                        Button("Protect All") { protectFolder(folder, keep: true) }
                        Button("Unprotect All") { protectFolder(folder, keep: false) }.disabled(folder.kept == 0)
                    }
                    .padding(12)
                    Divider()
                    Table(files) {
                        TableColumn("Keep") { f in
                            Toggle("", isOn: Binding(get: { overrides[f.id] ?? f.keep }, set: { setKeep(f, $0) }))
                                .labelsHidden()
                                .disabled(f.status != "pending")
                                .help("Protect this file: it stays out of the delete.")
                        }.width(36)
                        TableColumn("File and proof") { f in
                            VStack(alignment: .leading, spacing: 2) {
                                // the folder is in the header; show the path inside it
                                Text(f.path.hasPrefix(folder.folder + "/") ? String(f.path.dropFirst(folder.folder.count + 1)) : f.path)
                                    .lineLimit(1).truncationMode(.middle).help(f.path)
                                    .foregroundStyle(f.status == "done" ? .secondary : .primary)
                                    .strikethrough(f.status == "done")
                                if f.status == "refused" {
                                    Label("Not deleted: \(Humanize.reason(f.note))", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                        .lineLimit(1).truncationMode(.tail)
                                        .help(f.note)
                                } else {
                                    Text(Self.why(f.confidence, f.reason) + (f.keepCopy.isEmpty ? "" : " · " + f.keepCopy))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(f.reason + (f.keepCopy.isEmpty ? "" : "\n" + f.keepCopy))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        TableColumn("Size") { f in
                            Text(Fmt.bytes(f.size)).monospacedDigit()
                                // keyset paging as you scroll: the next page loads when a row near the end appears
                                .onAppear { if !exhausted, files.suffix(40).contains(where: { $0.id == f.id }) { load(more: true) } }
                        }.width(72)
                    }
                    .alternatingRowBackgrounds(.disabled) // no empty striped rows under a short list
                }
                // also reload when an apply or a keep change lands: rows turn done or refused
                .task(id: "\(folder.id)|\(model.snapshot.actions["apply"]?.updatedAt ?? "")|\(folder.kept)|\(folder.deleted)") {
                    reset(); load(more: false)
                }
            } else {
                EmptyState(title: "Choose a folder", message: "Pick a folder on the left to see each file and the copy that makes it safe.", symbol: "folder")
            }
        }
    }

    /// v_reclaim's confidence (and reason, which tells a duplicate from a backup), in words.
    static func why(_ confidence: String, _ reason: String) -> String {
        if reason.hasPrefix("exact duplicate") { return "Duplicate" }
        switch confidence {
        case "verified": return "Proven copy"
        case "regenerable": return "Regenerable"
        case "orphaned": return "App leftover"
        case "platform-copy": return "On YouTube"
        default: return confidence.capitalized
        }
    }

    private func reset() {
        files = []
        overrides = [:]
        exhausted = false
    }

    private func load(more: Bool) {
        guard let folder, let db = model.database, !loading else { return }
        loading = true
        let after = more ? files.last : nil
        Task.detached(priority: .userInitiated) {
            let page = (try? db.planFiles(source: folder.source, folder: folder.folder, after: after)) ?? []
            await MainActor.run {
                files += page
                exhausted = page.count < 300
                loading = false
            }
        }
    }

    private func setKeep(_ f: PlanFile, _ keep: Bool) {
        overrides[f.id] = keep
        model.perform("keep") { try $0.setKeep(planID: f.planID, source: f.source, path: f.path, keep: keep) }
    }

    private func protectFolder(_ folder: PlanFolder, keep: Bool) {
        guard let plan = model.snapshot.gate?.planID else { return }
        for f in files where f.status == "pending" { overrides[f.id] = keep }
        model.perform("keep folder") { try $0.setKeep(planID: plan, source: folder.source, folder: folder.folder, keep: keep) }
    }
}

/// Typing the exact phrase is the confirmation the db's trigger and the worker both check.
private struct ConfirmDeleteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gate: ApplyGate
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete \(Fmt.count(gate.files)) files permanently?", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text("They are removed from this Mac (no Trash). Every one has a proven copy, is a duplicate, or is regenerable, and each is checked against the disk again right before it goes. Protected files are skipped.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("To confirm, type:").font(.callout)
            Text(gate.phrase).font(.system(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
            TextField("Type the phrase above", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(typed != gate.phrase)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func confirm() {
        guard typed == gate.phrase else { return }
        let phrase = typed
        model.perform("apply") { try $0.apply(confirm: phrase) }
        dismiss()
    }
}

/// Before a plan exists: what is ready per folder (live), and the button that freezes it into a plan.
private struct NoPlanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let ready = model.reclaim.folders.filter { $0.source == s.config.freeLocal }
        if ready.isEmpty {
            EmptyState(title: "Nothing to reclaim on \(s.config.freeLocal.isEmpty ? "this source" : s.config.freeLocal) yet",
                       message: "Files show up here once their copy in the backup is proven by checksum, or when they are exact duplicates or regenerable build output.",
                       symbol: "externaldrive.badge.checkmark")
        } else {
            let peak = Double(ready.map(\.bytes).max() ?? 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card("Ready now, by folder",
                         subtitle: "Find Files I Can Delete re-checks each one against the backup and saves a plan you can review file by file. Nothing is deleted until you confirm.") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                            ForEach(ready.prefix(30)) { f in
                                GridRow {
                                    Text(f.folder == "." ? "(top level)" : f.folder).lineLimit(1).truncationMode(.middle)
                                        .frame(minWidth: 140, maxWidth: 280, alignment: .leading)
                                    Meter(fraction: Double(f.bytes) / max(peak, 1), height: 6).frame(minWidth: 80)
                                    Text(Fmt.files(f.files)).monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 96, alignment: .trailing)
                                    Text(Fmt.bytes(f.bytes)).monospacedDigit()
                                        .frame(width: 88, alignment: .trailing)
                                }
                                .font(.callout)
                                .help(f.kinds)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// `.borderedProminent` when `on`, else the default bordered look.
struct ProminentIf: PrimitiveButtonStyle {
    let on: Bool
    init(_ on: Bool) { self.on = on }
    func makeBody(configuration: Configuration) -> some View {
        if on {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.bordered)
        }
    }
}
