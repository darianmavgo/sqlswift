import SwiftUI
import SQLDocCore

/// A row of per-column filter inputs, shown under the toolbar when the filter bar
/// is toggled on. Each field issues a `WHERE` query; distinct from find (which
/// only locates).
public struct FilterBarView: View {
    @ObservedObject var tableVM: TableViewModel
    var palette: GridPalette

    public init(tableVM: TableViewModel, palette: GridPalette) {
        self.tableVM = tableVM
        self.palette = palette
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11)).foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tableVM.visibleColumns) { col in
                        FilterField(tableVM: tableVM, column: col.name)
                    }
                }
                .padding(.vertical, 2)
            }

            if !tableVM.filters.isEmpty {
                Button {
                    tableVM.clearFilters()
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(palette.head)
        .overlay(Rectangle().frame(height: 1).foregroundColor(palette.rule), alignment: .bottom)
    }
}

private struct FilterField: View {
    @ObservedObject var tableVM: TableViewModel
    let column: String

    @State private var op: ColumnFilter.Op = .contains
    @State private var text: String = ""

    private var active: Bool { tableVM.filters.contains { $0.column == column } }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(ColumnFilter.Op.allCases, id: \.self) { o in
                    Button(o.label) { op = o; apply() }
                }
            } label: {
                Text(op.label).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                    .frame(minWidth: 14)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if op.needsValue {
                TextField(column, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 96)
                    .onChange(of: text) { _, _ in apply() }
            } else {
                Text(column).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 96, alignment: .leading)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor), lineWidth: 1))
        .onAppear {
            if let f = tableVM.filters.first(where: { $0.column == column }) { op = f.op; text = f.value }
        }
    }

    private func apply() {
        tableVM.setFilter(column: column, op: op, value: text)
    }
}
