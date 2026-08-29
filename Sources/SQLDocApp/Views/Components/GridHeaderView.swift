import SwiftUI
import SQLDocCore

public struct GridHeaderView: View {
    @ObservedObject var tableVM: TableViewModel
    var zoomScale: Double
    var gutterWidth: CGFloat
    var palette: GridPalette

    @State private var draggingCol: String?
    @State private var dragStartWidth: CGFloat = 0
    @State private var hoverCol: String?

    public init(tableVM: TableViewModel, zoomScale: Double = 1.0,
                gutterWidth: CGFloat = 60,
                palette: GridPalette = GridPalette.resolve(dark: false, accent: .accentColor)) {
        self.tableVM = tableVM
        self.zoomScale = zoomScale
        self.gutterWidth = gutterWidth
        self.palette = palette
    }

    private var zoom: CGFloat { CGFloat(zoomScale) }
    private var headerHeight: CGFloat { DesignToken.rowHeight * zoom }

    public var body: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: 11 * zoom, weight: .bold, design: .monospaced))
                .foregroundColor(palette.dim)
                .padding(.trailing, 8)
                .frame(width: gutterWidth, height: headerHeight, alignment: .trailing)

            ForEach(tableVM.columns) { col in
                headerCell(col)
            }
        }
        .frame(height: headerHeight)
        .background(palette.head)
        .overlay(Rectangle().frame(height: 1).foregroundColor(palette.ruleStrong), alignment: .bottom)
    }

    private func headerCell(_ col: Column) -> some View {
        let width = (tableVM.columnWidths[col.name] ?? DesignToken.colDefaultWidth) * zoom
        let isSorted = tableVM.sortColumn == col.name
        return HStack(spacing: 6) {
            Text(col.name)
                .font(.system(size: 12 * zoom, weight: .semibold))
                .foregroundColor(palette.ink)
                .lineLimit(1)

            if col.pk {
                Text("PK")
                    .font(.system(size: 9 * zoom, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.yellow.opacity(0.25))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
            }

            Spacer(minLength: 0)

            sortGlyph(isSorted: isSorted, hovering: hoverCol == col.name)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: headerHeight, alignment: .leading)
        .background(palette.head)
        .contentShape(Rectangle())
        .onHover { hoverCol = $0 ? col.name : (hoverCol == col.name ? nil : hoverCol) }
        .onTapGesture { tableVM.sortBy(column: col.name) }
        .contextMenu { sortMenu(col) }
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.rule).frame(width: 1)
        }
        .overlay(alignment: .trailing) { resizeGrip(col) }
    }

    @ViewBuilder
    private func sortGlyph(isSorted: Bool, hovering: Bool) -> some View {
        if isSorted {
            HStack(spacing: 2) {
                if tableVM.sortNumeric {
                    Image(systemName: "number").font(.system(size: 8 * zoom, weight: .bold))
                }
                Image(systemName: tableVM.isSortDesc ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10 * zoom, weight: .bold))
            }
            .foregroundColor(.accentColor)
        } else if hovering {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 9 * zoom, weight: .semibold))
                .foregroundColor(palette.dim.opacity(0.6))
        }
    }

    @ViewBuilder
    private func sortMenu(_ col: Column) -> some View {
        Button { tableVM.setSort(column: col.name, desc: false) } label: {
            Label("Sort Ascending (A → Z)", systemImage: "arrow.up")
        }
        Button { tableVM.setSort(column: col.name, desc: true) } label: {
            Label("Sort Descending (Z → A)", systemImage: "arrow.down")
        }
        if tableVM.sortColumn == col.name {
            Button { tableVM.setSort(column: nil, desc: false) } label: {
                Label("Clear Sort", systemImage: "xmark")
            }
            Divider()
            Toggle(isOn: Binding(
                get: { tableVM.sortNumeric },
                set: { _ in tableVM.toggleSortNumeric() }
            )) { Text("Sort as number") }
        }

        Divider()

        Button("Auto-Fit '\(col.name)'") { tableVM.autoFitWidth(column: col.name) }
        Button("Reset All Column Widths") { tableVM.resetColumnWidths() }

        Divider()

        Button("Copy Column Name") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(col.name, forType: .string)
        }
    }

    private func resizeGrip(_ col: Column) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if draggingCol == nil {
                            draggingCol = col.name
                            dragStartWidth = tableVM.columnWidths[col.name] ?? DesignToken.colDefaultWidth
                        }
                        let newWidth = max(48, dragStartWidth + (value.translation.width / zoom))
                        tableVM.updateWidth(column: col.name, width: newWidth)
                    }
                    .onEnded { _ in draggingCol = nil }
            )
            .onTapGesture(count: 2) { tableVM.autoFitWidth(column: col.name) }
    }
}
