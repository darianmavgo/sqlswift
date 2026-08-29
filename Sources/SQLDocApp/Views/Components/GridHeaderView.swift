import SwiftUI
import SQLDocCore

public struct GridHeaderView: View {
    @ObservedObject var tableVM: TableViewModel
    var zoomScale: Double = 1.0
    let gutterWidth: CGFloat = 60
    @State private var draggingCol: String?
    @State private var dragStartWidth: CGFloat = 0

    public init(tableVM: TableViewModel, zoomScale: Double = 1.0) {
        self.tableVM = tableVM
        self.zoomScale = zoomScale
    }

    private var headerHeight: CGFloat {
        DesignToken.rowHeight * zoomScale
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Gutter corner
            Text("#")
                .font(.system(size: 11 * zoomScale, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: gutterWidth, height: headerHeight)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(Rectangle().frame(width: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .trailing)

            // Columns
            ForEach(tableVM.columns) { col in
                let width = (tableVM.columnWidths[col.name] ?? 120) * zoomScale
                HStack(spacing: 6) {
                    Text(col.name)
                        .font(.system(size: 12 * zoomScale, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if col.pk {
                        Text("PK")
                            .font(.system(size: 9 * zoomScale, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.25))
                            .foregroundColor(.orange)
                            .cornerRadius(3)
                    }

                    Spacer(minLength: 0)

                    if tableVM.sortColumn == col.name {
                        Image(systemName: tableVM.isSortDesc ? "arrow.down" : "arrow.up")
                            .font(.system(size: 10 * zoomScale, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: width, height: headerHeight, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture {
                    tableVM.sortBy(column: col.name)
                }
                .contextMenu {
                    Button(action: {
                        if tableVM.sortColumn != col.name || tableVM.isSortDesc {
                            tableVM.sortColumn = col.name
                            tableVM.isSortDesc = false
                            tableVM.loadPage(offset: 0)
                        }
                    }) {
                        Label("Sort Ascending (A → Z)", systemImage: "arrow.up")
                    }

                    Button(action: {
                        if tableVM.sortColumn != col.name || !tableVM.isSortDesc {
                            tableVM.sortColumn = col.name
                            tableVM.isSortDesc = true
                            tableVM.loadPage(offset: 0)
                        }
                    }) {
                        Label("Sort Descending (Z → A)", systemImage: "arrow.down")
                    }

                    if tableVM.sortColumn == col.name {
                        Button(action: {
                            tableVM.sortColumn = nil
                            tableVM.isSortDesc = false
                            tableVM.loadPage(offset: 0)
                        }) {
                            Label("Clear Sort", systemImage: "xmark")
                        }
                    }

                    Divider()

                    Button("Auto-Fit '\(col.name)'") {
                        tableVM.autoFitWidth(column: col.name)
                    }

                    Button("Reset All Column Widths") {
                        tableVM.resetColumnWidths()
                    }

                    Divider()

                    Button("Copy Column Name") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(col.name, forType: .string)
                    }
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
                                                    dragStartWidth = tableVM.columnWidths[col.name] ?? 120
                                                }
                                                let newWidth = max(48, dragStartWidth + (value.translation.width / zoomScale))
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
        }
        .frame(height: headerHeight)
        .overlay(Divider(), alignment: .bottom)
    }
}
