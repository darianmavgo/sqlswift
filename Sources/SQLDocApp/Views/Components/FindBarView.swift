import SwiftUI
import SQLDocCore

public struct FindBarView: View {
    @ObservedObject var tableVM: TableViewModel
    @FocusState private var isFieldFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))

                TextField("Find in table (⌘F)...", text: $tableVM.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFieldFocused)
                    .onChange(of: tableVM.searchQuery) { _, newValue in
                        tableVM.startFind(query: newValue)
                    }
                    .onSubmit {
                        tableVM.nextMatch()
                    }

                if !tableVM.searchQuery.isEmpty {
                    if tableVM.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }

                    if !tableVM.matches.isEmpty {
                        Text("\(tableVM.activeMatchIndex + 1) of \(tableVM.matches.count)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else if !tableVM.isSearching {
                        Text("No matches")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    Button(action: { tableVM.previousMatch() }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(tableVM.matches.isEmpty)
                    .help("Previous match (⇧⏎)")

                    Button(action: { tableVM.nextMatch() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(tableVM.matches.isEmpty)
                    .help("Next match (⏎)")
                }

                Button(action: {
                    tableVM.cancelFind()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Close find bar (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            // Progress bar
            if tableVM.isSearching && tableVM.searchProgress < 1.0 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * CGFloat(tableVM.searchProgress)), height: 2)
                }
                .frame(height: 2)
            } else {
                Divider()
            }
        }
        .onAppear {
            isFieldFocused = true
        }
    }
}
