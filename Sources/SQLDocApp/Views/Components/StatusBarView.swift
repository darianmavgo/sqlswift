import SwiftUI
import SQLDocCore

public struct StatusBarView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel

    public var body: some View {
        HStack(spacing: 12) {
            // Timing badge with fast / slow color threshold
            timingBadge

            Divider()
                .frame(height: 12)

            // Row position
            if let page = tableVM.currentPage {
                let startRow = page.start + 1
                let endRow = page.start + Int64(page.rows.count)
                let totalStr = tableVM.tableCount.displayString
                let approxMarker = page.approx ? "~" : ""

                Text("Rows \(startRow)–\(endRow) of \(totalStr)\(approxMarker)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
            }

            // Selected cell coordinate indicator
            if let sel = appVM.selectedCell, let page = tableVM.currentPage, sel.row < page.rows.count {
                Divider()
                    .frame(height: 12)

                let colName = sel.col < tableVM.columns.count ? tableVM.columns[sel.col].name : ""
                let rowNum = page.start + Int64(sel.row) + 1

                HStack(spacing: 4) {
                    Text("Selected: Row \(rowNum), Col '\(colName)'")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)

                    Button(action: {
                        if sel.col < tableVM.columns.count {
                            let col = tableVM.columns[sel.col]
                            let val = sel.col < page.rows[sel.row].count ? page.rows[sel.row][sel.col] : SQLiteValue.null
                            appVM.inspectingCell = CellInspectInfo(
                                tableName: tableVM.tableName,
                                colName: col.name,
                                colType: col.type,
                                value: val,
                                rowOrdinal: rowNum
                            )
                        }
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Inspect selected cell (Space or ⌘I)")
                }
            }

            Spacer()

            // File path
            if let doc = appVM.activeDocEntry {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(doc.path)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        .overlay(
            Divider(), alignment: .top
        )
    }

    private var timingBadge: some View {
        let isSlow = tableVM.lastTimingMicros >= Int64(BehaviorConfig.timingSlowThresholdUs)
        let timingColor = isSlow ? AppTheme.color(from: DesignToken.statusWarn.light) : AppTheme.color(from: DesignToken.statusOk.light)
        let iconName = isSlow ? "bolt.trianglebadge.exclamationmark.fill" : "bolt.fill"
        let timingText = formatMicros(tableVM.lastTimingMicros)
        let explanation = isSlow ? "Query took \(timingText) (slow threshold: 15ms) via '\(tableVM.lastQueryPath)'" : "Query took \(timingText) via '\(tableVM.lastQueryPath)'"

        return HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(timingColor)

            Text("\(timingText) · \(tableVM.lastQueryPath)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(timingColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(timingColor.opacity(0.12))
        .cornerRadius(4)
        .help(explanation)
    }

    private func formatMicros(_ micros: Int64) -> String {
        if micros < 1000 {
            return "\(micros) µs"
        } else if micros < 1_000_000 {
            return String(format: "%.2f ms", Double(micros) / 1000.0)
        } else {
            return String(format: "%.2f s", Double(micros) / 1_000_000.0)
        }
    }
}
