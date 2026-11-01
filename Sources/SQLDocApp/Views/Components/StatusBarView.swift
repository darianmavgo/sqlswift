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

            if tableVM.fileChangedOnDisk {
                Button(action: { tableVM.reloadFromDisk() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 10))
                        Text("Updated on disk · Reload")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("The SQLite file or its WAL changed on disk — click to reload")
            }

            if tableVM.displayKind == .trim {
                let shown = tableVM.visibleColumns.count
                let total = tableVM.rawColumns.count
                Text("trim · \(shown)/\(total) cols")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
                    .help("Trim mode active — click Raw in the toolbar to show all \(total) columns")
            } else if tableVM.displayKind == .summary {
                Text("summary · \(tableVM.currentPage?.rows.count ?? 0) groups")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
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
                Picker("View mode", selection: Binding(
                    get: { tableVM.displayKind },
                    set: { tableVM.setDisplayKind($0) }
                )) {
                    ForEach(DisplayKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Divider()
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
                Toggle("Quick chart strip", isOn: Binding(
                    get: { tableVM.showQuickChart }, set: { tableVM.showQuickChart = $0 }))
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
            pagerButton("backward.end.fill", help: "First page [0:\(tableVM.pageLimit)] (Home)",
                        disabled: tableVM.currentOffset <= 0) { appVM.paginateFirst(tableVM: tableVM) }
            pagerButton("chevron.left", help: "Previous \(tableVM.pageLimit) (Page Up)",
                        disabled: tableVM.currentOffset <= 0) { appVM.paginatePrevious(tableVM: tableVM) }

            if let page = tableVM.currentPage {
                let startRow = page.start + 1
                let endRow = page.start + Int64(page.rows.count)
                let approx = page.approx ? "~" : ""
                let total: String = {
                    if tableVM.powerSampleMode {
                        return "\(page.rows.count)"
                    } else if tableVM.isCustomBanquetQuery {
                        return tableVM.customQueryRowCount.map(String.init) ?? "\(page.rows.count)"
                    } else if !tableVM.filters.isEmpty {
                        return tableVM.filteredCount.map(String.init) ?? "…"
                    } else {
                        return tableVM.tableCount.displayString
                    }
                }()
                Text("\(startRow)–\(endRow) / \(total)\(approx)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 90)
            }

            let atEnd: Bool = {
                guard let page = tableVM.currentPage else { return true }
                if page.rows.isEmpty { return true }
                if tableVM.isCustomBanquetQuery, let count = tableVM.customQueryRowCount {
                    return page.start + Int64(page.rows.count) >= Int64(count)
                }
                if let total = !tableVM.filters.isEmpty ? tableVM.filteredCount : (tableVM.tableCount.known ? tableVM.tableCount.rows : nil) {
                    return page.start + Int64(page.rows.count) >= total
                }
                return page.rows.count < tableVM.pageLimit
            }()

            pagerButton("chevron.right", help: "Next \(tableVM.pageLimit) (Page Down)",
                        disabled: atEnd) { appVM.paginateNext(tableVM: tableVM) }
            pagerButton("forward.end.fill", help: "Last page (End)",
                        disabled: atEnd) { appVM.paginateLast(tableVM: tableVM) }
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
