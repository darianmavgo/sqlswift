import SwiftUI
import SQLDocCore

/// Right-hand detail panel for the selected row. Only offered on thin tables,
/// where the grid has horizontal room to spare; wide tables use the cell inspector.
struct RowDetailPanel: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel
    @ObservedObject private var edit: EditViewModel

    init(appVM: AppViewModel, tableVM: TableViewModel) {
        self.appVM = appVM; self.tableVM = tableVM
        self.edit = appVM.edit
    }

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
                                if edit.canEditActiveTable, idx < page.rowIDs.count {
                                    formField(page: page, row: idx, col: c)
                                } else {
                                    field(col.name, page.rows[idx][c])
                                }
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

    /// Form view (edit mode): every column of the selected row, staged through the same
    /// buffer as the grid so undo, the SQL preview and Apply all see these edits.
    @ViewBuilder
    private func formField(page: Page, row: Int, col: Int) -> some View {
        let column = page.columns[col]
        let rowID = page.rowIDs[row]
        let original = page.rows[row][col]
        let deleted = edit.isDeleted(table: page.table, rowID: rowID)
        let shown = edit.pending(table: page.table, rowID: rowID, column: column.name) ?? original
        if deleted || original.isPartial || !EditViewModel.isCellEditable(column: column, value: original) {
            field(column.name, shown)
                .opacity(deleted ? 0.5 : 1)
        } else {
            FormFieldEditor(name: column.name, value: shown, isPending: edit.pending(table: page.table, rowID: rowID, column: column.name) != nil,
                            onSubmit: { edit.stage(table: page.table, rowID: rowID, column: column, original: original, text: $0) },
                            onNull: { _ = edit.stageNull(table: page.table, rowID: rowID, column: column, original: original) })
                .id("\(page.table)#\(rowID)#\(column.name)#\(edit.revision)")
        }
    }
}

private struct FormFieldEditor: View {
    let name: String
    let value: SQLiteValue
    let isPending: Bool
    let onSubmit: (String) -> String?
    let onNull: () -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                if isPending { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
                Spacer()
                Button("NULL", action: onNull).buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                    .help("Set to NULL")
            }
            TextField(value.isNull ? "NULL" : "", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: error == nil ? 0 : 1.5))
                .onSubmit { error = onSubmit(text) }
                .onChange(of: text) { _, _ in error = nil }
            if let error { Text(error).font(.system(size: 10)).foregroundColor(.red) }
        }
        .onAppear { text = value.isNull ? "" : value.rawText }
    }
}
