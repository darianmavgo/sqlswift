import SwiftUI
import FileStudioKit

struct BackupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let run = s.run {
                    LiveRunCard(run: run, compact: false)
                    if !s.problems.isEmpty { ProblemsCard(problems: s.problems, runActive: run.isActive) }
                }
                FolderCoverageCard(limit: 12)
                if let run = s.run, run.isActive, !s.activeFiles.isEmpty { InFlightCard(files: s.activeFiles, total: max(Int(s.live?.active ?? 0), s.activeFiles.count)) }
                if s.runs.count > 1 { RunsCard(runs: Array(s.runs.dropFirst())) }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        let s = model.snapshot
        let busy = s.busyAction
        return Card {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if s.config.from.isEmpty || s.config.target.isEmpty {
                        Text("Nothing chosen to back up").font(.title3.weight(.semibold))
                        Text("Choose a local source and a backup in Settings.").foregroundStyle(.secondary)
                    } else {
                        Text(title).font(.title3.weight(.semibold))
                        RouteLine()
                        Text(headerLine).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if model.isBackupRunning {
                    Button(role: .destructive) { model.run("stop") } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stops after the files in flight; everything proven so far is kept.")
                } else {
                    if let failed = s.run?.filesFailed, failed > 0 {
                        Button { model.run("retry_failed") } label: { Label("Retry \(Fmt.count(failed)) Failed", systemImage: "arrow.clockwise") }
                            .disabled(busy != nil)
                    }
                    Button { model.run("backup") } label: { Label(resumeLabel, systemImage: "icloud.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("b", modifiers: [.command])
                        .disabled(busy != nil || s.config.from.isEmpty || s.config.target.isEmpty || !model.workerHealthy)
                }
            }
        }
    }

    private var title: String {
        if model.backupScanProgress != nil { return "Looking for new and changed files…" }
        if model.isBackupRunning, let c = model.coverage?.total {
            return "Backing up · \(Fmt.bytes(c.missingBytes)) to go"
        }
        if model.isBackupRunning { return "Backing up" }
        guard let c = model.coverage?.total else { return "Backup" }
        if c.complete { return "Everything is backed up" }
        return "\(Fmt.files(c.missingFiles)) to send · \(Fmt.bytes(c.missingBytes))"
    }

    private var headerLine: String {
        let s = model.snapshot
        if let scan = model.backupScanProgress { return "\(scan). Files start uploading when the folder has been read." }
        if model.isBackupRunning { return "Every copy is checked by checksum as it lands." }
        if let busy = s.busyAction { return "\(Humanize.action(busy.name)): \(busy.message)" }
        return "Files already proven are never sent again. An interrupted run continues where it stopped."
    }

    private var resumeLabel: String {
        switch model.snapshot.run?.state {
        case "stopped", "interrupted": "Continue Backup"
        default: "Back Up Now"
        }
    }
}

/// The run in numbers: proven so far, speed, time left. Shared with Overview.
struct LiveRunCard: View {
    @Environment(AppModel.self) private var model
    let run: RunProgress
    let compact: Bool

    var body: some View {
        let live = model.snapshot.live
        Card(run.isActive ? "Run \(run.id)" : "Latest backup",
             subtitle: run.isActive ? "Started \(Fmt.ago(run.startedAt))" : "\(run.message.isEmpty ? run.state : run.message) · \(Fmt.ago(run.finishedAt.isEmpty ? run.startedAt : run.finishedAt))",
             accessory: { StateChip(state: run.state) }) {
            VStack(alignment: .leading, spacing: 12) {
                // Proven is solid; bytes on their way are a lighter layer, so one big file in flight
                // moves the bar instead of leaving it at 0% until it lands. rclone counts bytes as it
                // reads them, a little ahead of R2, so they are never shown as proven.
                let moving = run.isActive ? sendingFraction(live) : 0
                Meter(fraction: run.fraction, tint: run.filesFailed > 0 && !run.isActive ? .orange : .accentColor, height: 10,
                      under: moving)
                    .animation(.easeOut(duration: 0.25), value: run.fraction)
                    .animation(.easeOut(duration: 0.25), value: moving)
                HStack(spacing: 28) {
                    metric("Proven", "\(Fmt.count(run.filesDone)) of \(Fmt.count(run.filesTotal))", "\(Fmt.bytes(run.bytesDone)) of \(Fmt.bytes(run.bytesTotal))")
                    if run.isActive {
                        metric("Sent", Fmt.bytes(Int64(moving * Double(run.bytesTotal))), "\(Fmt.files(run.filesUploaded)) finished")
                        metric("Speed", Fmt.rate(live?.speed ?? 0), "\(live?.active ?? 0) in flight")
                        metric("Time left", Fmt.duration(live?.eta), Fmt.percent(moving))
                    } else {
                        metric("Sent", Fmt.count(run.filesUploaded), Fmt.bytes(run.bytesUploaded))
                    }
                    if run.filesFailed > 0 { metric("Need attention", Fmt.count(run.filesFailed), "see below", tint: .orange) }
                    Spacer(minLength: 0)
                }
                if run.isActive && !compact {
                    VStack(alignment: .leading, spacing: 4) {
                        Sparkline(values: model.speedHistory).frame(height: 56)
                        if let peak = model.speedHistory.max(), peak > 0 {
                            let avg = model.speedHistory.reduce(0, +) / Double(model.speedHistory.count)
                            Text("Peak \(Fmt.rate(peak)) · average \(Fmt.rate(avg))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    /// Share of this run's bytes proven or on their way (never less than proven, never over 100%).
    private func sendingFraction(_ live: LiveTransfer?) -> Double {
        guard run.bytesTotal > 0 else { return run.fraction }
        let bytes = max(run.bytesDone, min(run.bytesTotal, live?.bytes ?? 0))
        return Double(bytes) / Double(run.bytesTotal)
    }

    private func metric(_ title: String, _ value: String, _ detail: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct InFlightCard: View {
    let files: [ActiveFile]
    let total: Int
    static let shown = 8

    var body: some View {
        // No per-file bars: rclone counts bytes when they are read into upload buffers, so a bar
        // would say "done" while the upload is still going. Size and speed are honest.
        Card("In flight", subtitle: total > Self.shown ? "Biggest \(Self.shown) of \(total)" : "Biggest first") {
            VStack(spacing: 8) {
                ForEach(files.prefix(Self.shown)) { f in
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.circle").foregroundStyle(.tint)
                        Text(f.path).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Text(f.speed > 0 ? Fmt.rate(f.speed) : "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .trailing)
                        Text(Fmt.bytes(f.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct ProblemsCard: View {
    @Environment(AppModel.self) private var model
    let problems: [ItemProblem]
    let runActive: Bool

    var body: some View {
        Card("Needs attention", subtitle: "These files have no proven copy from this run",
             accessory: {
                 if !runActive {
                     Button("Retry Failed") { model.run("retry_failed") }.disabled(model.snapshot.busyAction != nil)
                 }
             }) {
            Table(problems) {
                TableColumn("File") { p in Text(p.path).lineLimit(1).truncationMode(.middle).help(p.path) }
                TableColumn("State") { p in StateChip(state: p.state) }.width(110)
                TableColumn("Size") { p in Text(Fmt.bytes(p.size)).monospacedDigit() }.width(80)
                TableColumn("Why") { p in Text(p.error).lineLimit(2).foregroundStyle(.secondary).help(p.error) }
            }
            .alternatingRowBackgrounds(.disabled) // no empty striped rows under a short list
            .frame(minHeight: 160, idealHeight: min(CGFloat(problems.count) * 28 + 30, 360))
        }
    }
}

private struct RunsCard: View {
    let runs: [RunProgress]

    var body: some View {
        Card("Earlier runs") {
            VStack(spacing: 8) {
                ForEach(runs) { r in
                    HStack(spacing: 12) {
                        StateChip(state: r.state).frame(width: 96, alignment: .leading)
                        Text("Run \(r.id)").monospacedDigit()
                        Text("\(Fmt.count(r.filesDone))/\(Fmt.count(r.filesTotal)) proven · \(Fmt.bytes(r.bytesUploaded)) sent")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.ago(r.startedAt)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
