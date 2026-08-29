import SwiftUI
import SQLDocCore

public struct VirtualizedGridView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel
    let gutterWidth: CGFloat = 60

    public var body: some View {
        VStack(spacing: 0) {
            if tableVM.columns.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tablecells.badge.ellipsis")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("This table has no columns or cannot be read.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Table header
                ScrollView(.horizontal, showsIndicators: false) {
                    GridHeaderView(tableVM: tableVM)
                }
                .background(Color(NSColor.controlBackgroundColor))

                // Table rows
                if let page = tableVM.currentPage, !page.rows.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(page.rows.enumerated()), id: \.offset) { index, row in
                                let rowOrdinal = page.start + Int64(index) + 1
                                let isEven = index % 2 == 0

                                HStack(spacing: 0) {
                                    // Row gutter index
                                    Text("\(rowOrdinal)")
                                        .font(.system(size: 11 * appVM.zoomScale, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: gutterWidth, height: 26 * appVM.zoomScale)
                                        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                                        .overlay(Rectangle().frame(width: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .trailing)

                                    // Columns
                                    ForEach(Array(tableVM.columns.enumerated()), id: \.element.id) { colIdx, col in
                                        let colWidth = (tableVM.columnWidths[col.name] ?? 120) * appVM.zoomScale
                                        let cellVal = colIdx < row.count ? row[colIdx] : SQLiteValue.null

                                        CellView(
                                            value: cellVal,
                                            isNumeric: col.isNumeric,
                                            width: colWidth,
                                            height: 26 * appVM.zoomScale,
                                            zoomScale: appVM.zoomScale,
                                            searchQuery: tableVM.searchQuery
                                        )
                                        .overlay(Rectangle().frame(width: 1).foregroundColor(Color(NSColor.separatorColor).opacity(0.3)), alignment: .trailing)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 26 * appVM.zoomScale)
                                .background(isEven ? Color(NSColor.controlBackgroundColor).opacity(0.15) : Color.clear)
                                .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor).opacity(0.2)), alignment: .bottom)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("This table is empty.")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Pagination bar
                HStack(spacing: 16) {
                    Button(action: { tableVM.loadPage(offset: 0) }) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(tableVM.currentOffset <= 0)
                    .help("Jump to beginning (Home)")

                    Button(action: { tableVM.previousPage() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text("Previous 100")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(tableVM.currentOffset <= 0)

                    Spacer()

                    Button(action: { tableVM.nextPage() }) {
                        HStack(spacing: 4) {
                            Text("Next 100")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(tableVM.currentPage?.rows.isEmpty ?? true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .overlay(Divider(), alignment: .top)
            }
        }
    }
}

public struct CellView: View {
    let value: SQLiteValue
    let isNumeric: Bool
    let width: CGFloat
    let height: CGFloat
    let zoomScale: Double
    let searchQuery: String

    public var body: some View {
        HStack(spacing: 0) {
            switch value {
            case .null:
                Text("NULL")
                    .font(.system(size: 11 * zoomScale, weight: .regular, design: .monospaced).italic())
                    .foregroundColor(Color.secondary.opacity(0.5))

            case .blob:
                Text(value.displayText)
                    .font(.system(size: 10 * zoomScale, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(3)

            case .integer, .real:
                Text(value.displayText)
                    .font(.system(size: 12 * zoomScale, weight: .regular, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)

            case .text(let s):
                Text(s)
                    .font(.system(size: 12 * zoomScale, weight: .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .background(
                        isHighlighted(s) ? Color.yellow.opacity(0.4) : Color.clear
                    )
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height, alignment: isNumeric ? .trailing : .leading)
    }

    private func isHighlighted(_ text: String) -> Bool {
        guard !searchQuery.isEmpty else { return false }
        return text.localizedCaseInsensitiveContains(searchQuery)
    }
}
