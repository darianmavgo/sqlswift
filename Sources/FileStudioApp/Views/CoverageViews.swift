import SwiftUI
import FileStudioKit

/// A donut showing the proven share of the backup, with the percent in the middle.
struct CoverageRing: View {
    let fraction: Double
    var tint: Color = .green
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(fraction > 0 ? 1 : 0)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            Text(Fmt.percent(fraction))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.percent(fraction)) backed up and proven")
    }
}

/// The backup at a glance: how much has a proven copy, where it goes, and the one button to press.
struct BackupHeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let c = model.coverage?.total
        Card {
            HStack(alignment: .center, spacing: 20) {
                CoverageRing(fraction: c?.fraction ?? 0, tint: ringTint)
                    .frame(width: 92, height: 92)
                    .redacted(reason: c == nil ? .placeholder : [])
                VStack(alignment: .leading, spacing: 5) {
                    Text(headline).font(.title2.weight(.semibold))
                    if let c {
                        Text(c.complete
                             ? "All \(Fmt.files(c.files)) (\(Fmt.bytes(c.bytes))) have a checksum-proven copy."
                             : "\(Fmt.count(c.provenFiles)) of \(Fmt.files(c.files)) proven · \(Fmt.bytes(c.missingBytes)) still to send")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let scan = model.backupScanProgress {
                        Label(scan, systemImage: "magnifyingglass")
                            .font(.callout.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.tint)
                            .contentTransition(.numericText())
                    } else if model.isBackupRunning, let live = s.live {
                        HStack(spacing: 14) {
                            Label(Fmt.rate(live.speed), systemImage: "speedometer")
                            Label("\(Fmt.duration(live.eta)) left", systemImage: "clock")
                            Label("\(live.active) in flight", systemImage: "arrow.up.circle")
                        }
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.tint)
                        .contentTransition(.numericText())
                    }
                    if !s.config.from.isEmpty {
                        RouteLine()
                    }
                    if let run = s.run, !run.isActive {
                        Text("Last backup \(Fmt.ago(run.finishedAt.isEmpty ? run.startedAt : run.finishedAt))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 12)
                action
            }
        }
    }

    private var ringTint: Color {
        guard let c = model.coverage?.total else { return .secondary }
        return c.complete ? .green : (model.isBackupRunning ? .accentColor : .orange)
    }

    private var headline: String {
        let s = model.snapshot
        if s.config.from.isEmpty || s.config.target.isEmpty { return "Choose what to back up" }
        if model.backupScanProgress != nil { return "Looking for new and changed files…" }
        if model.isBackupRunning { return "Backing up…" }
        guard let c = model.coverage?.total else { return "Checking your backup…" }
        if c.files == 0 { return "Nothing indexed yet" }
        if c.complete { return "Everything is backed up" }
        if c.provenFiles == 0 { return "Not backed up yet" }
        return "\(Fmt.files(c.missingFiles)) still need a copy"
    }

    @ViewBuilder private var action: some View {
        let s = model.snapshot
        if s.config.from.isEmpty || s.config.target.isEmpty {
            Button("Open Settings") { model.section = .settings }
        } else if model.isBackupRunning {
            Button("Show Progress") { model.section = .backup }
        } else if let c = model.coverage?.total, !c.complete {
            Button { model.run("backup") } label: {
                Label(s.run.map { ["stopped", "interrupted"].contains($0.state) } == true ? "Continue Backup" : "Back Up Now",
                      systemImage: "icloud.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(s.busyAction != nil || !model.workerHealthy)
        }
    }
}

/// "~/Documents → r2:bucket/Documents", the real places rather than source names.
struct RouteLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let from = s.sources.first { $0.name == s.config.from }
        let to = s.sources.first { $0.name == s.config.target }
        let dest = (to?.remote ?? s.config.target) + (s.config.prefix.isEmpty ? "" : "/" + s.config.prefix)
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(Self.tilde(from?.remote ?? s.config.from)).help(s.config.from)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Image(systemName: "cloud").foregroundStyle(.secondary)
            Text(dest).help(s.config.target)
        }
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// "~/Documents/filestudio.db" when that is short, else "…/parent/name.db".
    static func short(_ path: String) -> String {
        let t = tilde(path)
        guard t.count > 40 else { return t }
        let parts = t.split(separator: "/")
        return parts.count >= 2 ? "…/" + parts.suffix(2).joined(separator: "/") : t
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Which top-level folders are covered: one row per folder, biggest first.
struct FolderCoverageCard: View {
    @Environment(AppModel.self) private var model
    var limit: Int? = 8
    @State private var showAll = false

    var body: some View {
        let report = model.coverage
        let folders = report?.folders ?? []
        let shown = (showAll || limit == nil) ? folders : Array(folders.prefix(limit!))
        Card("Folders", subtitle: report.map { "\(Fmt.files(Int64($0.folders.count), "folder")) in \($0.source) · biggest first" },
             accessory: {
                 if let limit, folders.count > limit {
                     Button(showAll ? "Show Fewer" : "Show All \(folders.count)") { withAnimation(.snappy) { showAll.toggle() } }
                         .buttonStyle(.link)
                 }
             }) {
            if report == nil {
                HStack { ProgressView().controlSize(.small); Text("Reading the index…").foregroundStyle(.secondary) }
            } else if folders.isEmpty {
                Text("No files indexed for this source yet.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                    ForEach(shown) { f in
                        GridRow {
                            Image(systemName: f.coverage.complete ? "checkmark.circle.fill" : (f.coverage.provenFiles > 0 ? "circle.lefthalf.filled" : "circle"))
                                .foregroundStyle(f.coverage.complete ? .green : (f.coverage.provenFiles > 0 ? Color.accentColor : .secondary))
                            Text(f.folder == "." ? "(top level)" : f.folder)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
                            Meter(fraction: f.coverage.fraction, tint: f.coverage.complete ? .green : .accentColor, height: 6)
                                .frame(minWidth: 80)
                                .gridColumnAlignment(.leading)
                            Text(Fmt.percent(f.coverage.fraction))
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                            Text(f.coverage.complete ? Fmt.bytes(f.coverage.bytes) : "\(Fmt.bytes(f.coverage.missingBytes)) to go")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 104, alignment: .trailing)
                        }
                        .font(.callout)
                        .help("\(Fmt.count(f.coverage.provenFiles)) of \(Fmt.files(f.coverage.files)) proven · \(Fmt.bytes(f.coverage.provenBytes)) of \(Fmt.bytes(f.coverage.bytes))")
                    }
                }
            }
        }
    }
}

/// job_log messages are written for someone reading the db in a SQLite viewer; say it for people.
enum Humanize {
    static func message(_ m: String) -> String {
        var s = m
        for (from, to) in [
            (" (see deleted_log)", ""),
            (" Review them in plan_items, then see v_apply_gate.", ""),
            ("; 0 problems, usually files already gone", ""),
            (" in the backup", ""),
            (" (" + driftReason + ")", " (" + reason(driftReason) + ")"),
        ] { s = s.replacingOccurrences(of: from, with: to) }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// The worker's text for a file changed after it was proven (pkg/studio driftReason).
    static let driftReason = "changed since it was indexed/verified; re-index with -force and verify again"

    /// A refusal reason from apply, for people.
    static func reason(_ r: String) -> String {
        if r == driftReason { return "changed after its backup; back it up again first" }
        return r.isEmpty ? "not safe to delete" : r
    }

    static func action(_ a: String) -> String {
        switch a {
        case "free": "Find files to delete"
        case "apply": "Delete"
        case "backup": "Backup"
        case "retry_failed": "Retry failed"
        case "stop": "Stop"
        default: a.capitalized
        }
    }
}
