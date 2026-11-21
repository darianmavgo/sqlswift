import SwiftUI
import FileStudioKit

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackupHeroCard()

                HStack(alignment: .top, spacing: 16) {
                    ReclaimTile()
                    AttentionTile()
                }
                .fixedSize(horizontal: false, vertical: true)

                FolderCoverageCard(limit: 6)

                Card("Recent activity", accessory: {
                    if !s.jobLog.isEmpty { Button("Show All") { model.section = .activity }.buttonStyle(.link) }
                }) {
                    if s.jobLog.isEmpty {
                        Text("Nothing has run yet.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(s.jobLog.prefix(5)) { e in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    StateChip(state: e.state).frame(width: 64, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Humanize.message(e.message)).lineLimit(2).help(e.message)
                                        Text("\(Humanize.action(e.action)) · \(Fmt.ago(e.at))").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
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

/// Space that can go now, per local source; each source opens Reclaim on it.
private struct ReclaimTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let by = model.reclaimBySource
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Ready to reclaim", systemImage: "externaldrive.badge.checkmark")
                    .font(.callout.weight(.medium)).foregroundStyle(.tint)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.bytes(model.reclaim.totalBytes))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    if model.reclaimLoading { ProgressView().controlSize(.small) }
                }
                if by.isEmpty {
                    Text("Files show up here once their copy is proven.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(by.prefix(3), id: \.source) { r in
                            Button {
                                if r.source != model.snapshot.config.freeLocal { model.setFreeLocal(r.source) }
                                model.section = .reclaim
                            } label: {
                                HStack {
                                    Text(r.source)
                                    Spacer()
                                    Text("\(Fmt.bytes(r.bytes)) · \(Fmt.files(r.files))").monospacedDigit().foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

private struct AttentionTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let n = Int64(s.problems.count)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Needs attention", systemImage: n == 0 ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.callout.weight(.medium)).foregroundStyle(n == 0 ? Color.secondary : .orange)
                Text(Fmt.count(n))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(n == 0 ? Color.primary : .orange)
                Text(n == 0 ? (s.run == nil ? "No backup has run yet." : "Nothing failed in the latest backup.")
                     : "\(Fmt.files(n)) the latest backup could not prove.")
                    .font(.callout).foregroundStyle(.secondary)
                if n > 0 {
                    Button("Review") { model.section = .backup }.buttonStyle(.link)
                }
            }
        }
    }
}
