import SwiftUI
import SQLDocCore

/// banquet-table-list-style.md: a stacked sequence of independent grids, one per table,
/// each under a `=== Table: name (N rows, M columns) ===` header.
struct TableListView: View {
    let doc: Doc
    @State private var sections: [TableListSection]?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            if let sections {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.header)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            grid(section)
                        }
                    }
                }
                .padding(14)
            } else {
                ProgressView("Reading tables…").padding(40)
            }
        }
        .task(id: doc.path) {
            let doc = self.doc
            sections = await Task.detached { TableListBuilder.sections(for: doc) }.value
            UILog.event("grid", "table list", ["tables": sections?.map(\.name) ?? []])
        }
    }

    private func grid(_ s: TableListSection) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            GridRow {
                ForEach(Array(s.columns.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            ForEach(Array(s.cells.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    }
                }
            }
        }
    }
}
