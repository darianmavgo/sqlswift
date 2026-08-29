import SwiftUI
import SQLDocCore

public struct FindBarView: View {
    @ObservedObject var tableVM: TableViewModel
    var onClose: () -> Void
    @FocusState private var isFieldFocused: Bool

    public init(tableVM: TableViewModel, onClose: @escaping () -> Void = {}) {
        self.tableVM = tableVM
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("Find in table…", text: $tableVM.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: DesignToken.findInputWidth)
                    .focused($isFieldFocused)
                    .onChange(of: tableVM.searchQuery) { _, newValue in
                        tableVM.startFind(query: newValue)
                    }
                    .onSubmit { tableVM.nextMatch() }

                // Column scope
                Menu {
                    Button {
                        tableVM.searchColumn = nil
                        tableVM.startFind(query: tableVM.searchQuery)
                    } label: {
                        Label("All columns", systemImage: tableVM.searchColumn == nil ? "checkmark" : "")
                    }
                    Divider()
                    ForEach(tableVM.columns) { col in
                        Button {
                            tableVM.searchColumn = col.name
                            tableVM.startFind(query: tableVM.searchQuery)
                        } label: {
                            Label(col.name, systemImage: tableVM.searchColumn == col.name ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11))
                        Text(tableVM.searchColumn ?? "All")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Limit the search to one column")

                Text(countText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 84, alignment: .trailing)

                Button { tableVM.previousMatch() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(tableVM.matches.isEmpty)
                .help("Previous match (⇧⏎)")

                Button { tableVM.nextMatch() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(tableVM.matches.isEmpty)
                .help("Next match (⏎)")

                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close find (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            // Incremental scan progress.
            if tableVM.isSearching && tableVM.searchProgress < 1.0 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * CGFloat(tableVM.searchProgress)), height: 2)
                        .animation(.linear(duration: 0.12), value: tableVM.searchProgress)
                }
                .frame(height: 2)
            } else {
                Divider()
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { isFieldFocused = true }
    }

    private var countText: String {
        if tableVM.searchQuery.isEmpty { return "" }
        if !tableVM.matches.isEmpty {
            let cur = max(1, tableVM.activeMatchIndex + 1)
            let total = tableVM.matches.count
            let more = tableVM.matchCapReached ? "+" : (tableVM.isSearching ? "…" : "")
            return "\(cur)/\(total)\(more)"
        }
        if tableVM.isSearching {
            return tableVM.searchScanned > 0 ? "scanning \(SQLiteValue.integer(tableVM.searchScanned).displayText)…" : "searching…"
        }
        return "no results"
    }
}
