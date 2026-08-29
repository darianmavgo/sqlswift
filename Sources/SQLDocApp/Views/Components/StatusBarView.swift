import SwiftUI
import SQLDocCore

public struct StatusBarView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel

    public var body: some View {
        HStack(spacing: 12) {
            // Timing badge
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)

                Text("\(formatMicros(tableVM.lastTimingMicros)) · \(tableVM.lastQueryPath)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

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
