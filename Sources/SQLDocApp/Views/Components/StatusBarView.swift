import SwiftUI
import SQLDocCore

public struct StatusBarView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel

    public var body: some View {
        HStack(spacing: 10) {
            timingBadge

            Divider().frame(height: 12)

            pager

            if let job = tableVM.backgroundJob {
                Label(job, systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            if tableVM.powerSampleMode {
                Label("power-2 sample", systemImage: "chart.bar.doc.horizontal")
                    .font(.system(size: 11)).foregroundColor(.accentColor)
            } else if !tableVM.filters.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.system(size: 9))
                    Text(tableVM.filteredCount.map { "\($0) filtered" } ?? "filtered")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.accentColor)
            }

            if tableVM.isSorting {
                Label("sorting…", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if let sortCol = tableVM.sortColumn {
                HStack(spacing: 3) {
                    Image(systemName: tableVM.isSortDesc ? "arrow.down" : "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                    Text(sortCol + (tableVM.sortNumeric ? " (#)" : ""))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.accentColor)
            }

            if let sel = appVM.selectedCell, let page = tableVM.currentPage, sel.row < page.rows.count {
                Divider().frame(height: 12)
                let colName = sel.col < tableVM.columns.count ? tableVM.columns[sel.col].name : ""
                let rowNum = page.start + Int64(sel.row) + 1
                Text("R\(rowNum) · \(colName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
            }

            Spacer()

            // Display options
            Menu {
                Picker("Row height", selection: Binding(
                    get: { tableVM.rowHeightScale },
                    set: { tableVM.rowHeightScale = $0 }
                )) {
                    Text("Compact").tag(1.0)
                    Text("Regular").tag(2.0)
                    Text("Tall").tag(3.0)
                }
                Toggle("Wrap cell text", isOn: Binding(
                    get: { tableVM.wrapCells }, set: { tableVM.wrapCells = $0 }))
                Toggle("Smart formatting", isOn: Binding(
                    get: { tableVM.smartFormat }, set: { tableVM.smartFormat = $0 }))
            } label: {
                Image(systemName: "textformat.size").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Display options")

            Divider().frame(height: 12)

            if let doc = appVM.activeDocEntry {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(doc.path)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(-1)
            }

            Divider().frame(height: 12)

            Text("\(AppIdentity.version)·\(BuildInfo.commit)\(BuildInfo.dirty ? "+" : "")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.75))
                .help("Build: \(BuildInfo.detail)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Pager

    private var pager: some View {
        HStack(spacing: 6) {
            pagerButton("backward.end.fill", help: "First page (Home)",
                        disabled: tableVM.currentOffset <= 0) { tableVM.loadPage(offset: 0) }
            pagerButton("chevron.left", help: "Previous 100 (Page Up)",
                        disabled: tableVM.currentOffset <= 0) { tableVM.previousPage() }

            if let page = tableVM.currentPage {
                let startRow = page.start + 1
                let endRow = page.start + Int64(page.rows.count)
                let approx = page.approx ? "~" : ""
                let total: String = tableVM.powerSampleMode ? "\(page.rows.count)"
                    : (!tableVM.filters.isEmpty ? (tableVM.filteredCount.map(String.init) ?? "…")
                       : tableVM.tableCount.displayString)
                Text("\(startRow)–\(endRow) / \(total)\(approx)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 90)
            }

            pagerButton("chevron.right", help: "Next 100 (Page Down)",
                        disabled: tableVM.currentPage?.rows.isEmpty ?? true) { tableVM.nextPage() }
            pagerButton("forward.end.fill", help: "Last page (End)",
                        disabled: false) { tableVM.loadLastPage() }
        }
    }

    private func pagerButton(_ icon: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundColor(disabled ? .secondary.opacity(0.4) : .secondary)
        .help(help)
    }

    // MARK: - Timing

    private var timingBadge: some View {
        let isSlow = tableVM.lastTimingMicros >= Int64(BehaviorConfig.timingSlowThresholdUs)
        let color = isSlow ? AppTheme.color(from: DesignToken.statusWarn.light)
                           : AppTheme.color(from: DesignToken.statusOk.light)
        let text = formatMicros(tableVM.lastTimingMicros)
        return HStack(spacing: 4) {
            Image(systemName: isSlow ? "bolt.trianglebadge.exclamationmark.fill" : "bolt.fill")
                .font(.system(size: 10))
                .foregroundColor(color)
            Text("\(text) · \(tableVM.lastQueryPath)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12))
        .cornerRadius(4)
        .help(isSlow ? "Query took \(text) (slow ≥ 15 ms) via '\(tableVM.lastQueryPath)'"
                     : "Query took \(text) via '\(tableVM.lastQueryPath)'")
    }

    private func formatMicros(_ micros: Int64) -> String {
        if micros < 1000 { return "\(micros) µs" }
        if micros < 1_000_000 { return String(format: "%.2f ms", Double(micros) / 1000.0) }
        return String(format: "%.2f s", Double(micros) / 1_000_000.0)
    }
}
