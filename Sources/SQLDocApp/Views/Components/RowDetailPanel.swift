import SwiftUI
import SQLDocCore

/// Right-hand detail panel for the selected row. Only offered on thin tables,
/// where the grid has horizontal room to spare; wide tables use the cell inspector.
struct RowDetailPanel: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel

    private var rowIndex: Int? {
        guard let sel = appVM.selectedCell, let page = tableVM.currentPage,
              sel.row >= 0, sel.row < page.rows.count else { return nil }
        return sel.row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headerText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button { appVM.showRowDetail = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide detail panel")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if let idx = rowIndex, let page = tableVM.currentPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(page.columns.enumerated()), id: \.offset) { c, col in
                            if c < page.rows[idx].count {
                                field(col.name, page.rows[idx][c])
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a row to see its fields")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .leading)
    }

    private var headerText: String {
        guard let idx = rowIndex, let page = tableVM.currentPage else { return "Row detail" }
        return "Row \(page.start + Int64(idx) + 1)"
    }

    private func field(_ name: String, _ value: SQLiteValue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value.rawText)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
