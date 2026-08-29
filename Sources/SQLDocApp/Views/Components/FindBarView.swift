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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("Find in table…", text: $tableVM.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 180)
                    .focused($isFieldFocused)
                    .onChange(of: tableVM.searchQuery) { _, newValue in
                        tableVM.startFind(query: newValue)
                    }
                    .onSubmit {
                        tableVM.nextMatch()
                    }

                // Match count indicator matching sqldoc: e.g. "1/14", "1/14+", "searching…", "no results"
                Text(countText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)

                // Previous match button (⇧⏎)
                Button(action: { tableVM.previousMatch() }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(tableVM.matches.isEmpty)
                .help("Previous match (⇧⏎)")

                // Next match button (⏎)
                Button(action: { tableVM.nextMatch() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(tableVM.matches.isEmpty)
                .help("Next match (⏎)")

                // Close button (Esc)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close find (Esc)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            // Incremental search progress bar at the bottom
            if tableVM.isSearching && tableVM.searchProgress < 1.0 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * CGFloat(tableVM.searchProgress)), height: 2)
                        .animation(.linear(duration: 0.12), value: tableVM.searchProgress)
                }
                .frame(height: 2)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 6)
        .onAppear {
            isFieldFocused = true
        }
    }

    private var countText: String {
        if tableVM.searchQuery.isEmpty {
            return ""
        }
        if !tableVM.matches.isEmpty {
            let cur = max(1, tableVM.activeMatchIndex + 1)
            let total = tableVM.matches.count
            let plus = tableVM.isSearching ? "+" : ""
            return "\(cur)/\(total)\(plus)"
        }
        return tableVM.isSearching ? "searching…" : "no results"
    }
}
