import SwiftUI
import SQLDocCore

public struct GridHeaderView: View {
    @ObservedObject var tableVM: TableViewModel
    let gutterWidth: CGFloat = 60
    @State private var draggingCol: String?
    @State private var dragStartWidth: CGFloat = 0

    public var body: some View {
        HStack(spacing: 0) {
            // Gutter corner
            Text("#")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: gutterWidth, height: 28)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(Rectangle().frame(width: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .trailing)

            // Columns
            ForEach(tableVM.columns) { col in
                let width = tableVM.columnWidths[col.name] ?? 120
                HStack(spacing: 6) {
                    Text(col.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if col.pk {
                        Text("PK")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.25))
                            .foregroundColor(.orange)
                            .cornerRadius(3)
                    }

                    Text(col.type.isEmpty ? "ANY" : col.type)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color(NSColor.quaternaryLabelColor).opacity(0.15))
                        .cornerRadius(3)

                    Spacer(minLength: 0)

                    if tableVM.sortColumn == col.name {
                        Image(systemName: tableVM.isSortDesc ? "arrow.down" : "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: width, height: 28, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture {
                    tableVM.sortBy(column: col.name)
                }
                .overlay(
                    // Column resize handle
                    HStack {
                        Spacer()
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(width: 1)
                            .overlay(
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: 8)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 1)
                                            .onChanged { value in
                                                if draggingCol == nil {
                                                    draggingCol = col.name
                                                    dragStartWidth = width
                                                }
                                                let newWidth = max(60, dragStartWidth + value.translation.width)
                                                tableVM.updateWidth(column: col.name, width: newWidth)
                                            }
                                            .onEnded { _ in
                                                draggingCol = nil
                                            }
                                    )
                                    .onTapGesture(count: 2) {
                                        tableVM.autoFitWidth(column: col.name)
                                    }
                            )
                    }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .overlay(Divider(), alignment: .bottom)
    }
}
