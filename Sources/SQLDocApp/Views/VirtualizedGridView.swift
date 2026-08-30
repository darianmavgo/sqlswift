import SwiftUI
import AppKit
import SQLDocCore

public struct VirtualizedGridView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isGridFocused: Bool

    public init(appVM: AppViewModel, tableVM: TableViewModel) {
        self.appVM = appVM
        self.tableVM = tableVM
    }

    private var zoom: CGFloat { CGFloat(appVM.zoomScale) }
    private var rowHeight: CGFloat { DesignToken.rowHeight * zoom }

    private var palette: GridPalette {
        let accent = appVM.activeDocEntry.map { AppTheme.color(from: $0.doc.style.accent) } ?? .accentColor
        return GridPalette.resolve(dark: colorScheme == .dark, accent: accent)
    }

    /// Row-number gutter, sized to the digits it must show.
    private var gutterWidth: CGFloat {
        let lastOrdinal = (tableVM.currentPage?.start ?? 0) + Int64(tableVM.currentPage?.rows.count ?? 0)
        let digits = max(3, String(max(1, lastOrdinal)).count)
        return max(DesignToken.gutterMinWidth, CGFloat(digits) * 8 * zoom + 20)
    }

    /// (column, width, x-offset) for the current widths — computed once per body.
    private var layout: [(col: Column, width: CGFloat, x: CGFloat)] {
        var out: [(Column, CGFloat, CGFloat)] = []
        var x: CGFloat = 0
        for col in tableVM.columns {
            let w = (tableVM.columnWidths[col.name] ?? DesignToken.colDefaultWidth) * zoom
            out.append((col, w, x))
            x += w
        }
        return out
    }

    private var contentWidth: CGFloat {
        gutterWidth + layout.reduce(0) { $0 + $1.width }
    }

    public var body: some View {
        Group {
            if tableVM.columns.isEmpty && !tableVM.isLoading {
                emptyState(icon: "tablecells.badge.ellipsis",
                           message: "This table has no columns or cannot be read.")
            } else {
                gridBody
            }
        }
        .focusable(!appVM.isFindBarVisible)
        .focused($isGridFocused)
        .onKeyPress { press in
            // The find field owns the keyboard while it's open.
            appVM.isFindBarVisible ? .ignored : handleKeyPress(press)
        }
        .onAppear { isGridFocused = !appVM.isFindBarVisible }
        .onChange(of: appVM.isFindBarVisible) { _, visible in
            isGridFocused = !visible
        }
    }

    private var gridBody: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header: scrolls horizontally with the columns, pinned above
                    // the vertical scroll.
                    GridHeaderView(tableVM: tableVM,
                                   zoomScale: appVM.zoomScale,
                                   gutterWidth: gutterWidth,
                                   palette: palette)

                    ScrollView(.vertical, showsIndicators: true) {
                        if tableVM.isLoading && tableVM.currentPage == nil {
                            skeletonRows
                        } else if let page = tableVM.currentPage, !page.rows.isEmpty {
                            rows(for: page)
                        } else {
                            emptyState(icon: "tray", message: "This table is empty.")
                                .frame(width: contentWidth, height: 240)
                        }
                    }
                    .frame(height: max(0, geo.size.height - DesignToken.rowHeight * zoom))
                }
            }
            .background(palette.page)
        }
    }

    // MARK: - Rows

    private func rows(for page: Page) -> some View {
        let rowCount = page.rows.count
        let cols = layout
        let width = gutterWidth + cols.reduce(0) { $0 + $1.width }
        return LazyVStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { index in
                rowView(page: page, index: index, cols: cols, width: width)
            }
        }
        .frame(width: width, alignment: .leading)
        .background(
            GridBackdrop(rowCount: rowCount,
                         rowHeight: rowHeight,
                         gutterWidth: gutterWidth,
                         columnXs: cols.map { $0.x },
                         totalWidth: width,
                         rule: palette.rule,
                         stripe: palette.stripe)
        )
    }

    private func rowView(page: Page, index: Int, cols: [(col: Column, width: CGFloat, x: CGFloat)], width: CGFloat) -> some View {
        let rowOrdinal = page.start + Int64(index) + 1
        let rowID = index < page.rowIDs.count ? page.rowIDs[index] : nil
        let isRowMatched = rowID != nil && rowID == tableVM.activeMatchRowID
        let isRowSelected = appVM.selectedRowIndex == index

        return HStack(spacing: 0) {
            Text(SQLiteValueFormatBridge.ordinal(rowOrdinal))
                .font(.system(size: 11 * zoom, weight: .regular, design: .monospaced))
                .foregroundColor(palette.dim)
                .padding(.trailing, 8)
                .frame(width: gutterWidth, height: rowHeight, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture {
                    appVM.selectedRowIndex = index
                    appVM.selectedCell = (row: index, col: 0)
                    isGridFocused = true
                }

            ForEach(Array(cols.enumerated()), id: \.element.col.id) { colIdx, entry in
                let cellText = (index < page.text.count && colIdx < page.text[index].count)
                    ? page.text[index][colIdx] : CellText(text: "", truncated: false)
                let cellVal = colIdx < page.rows[index].count ? page.rows[index][colIdx] : SQLiteValue.null
                let isActiveMatchCell = isRowMatched && colIdx == tableVM.activeMatchColumnIndex
                let isCellSelected = appVM.selectedCell?.row == index && appVM.selectedCell?.col == colIdx

                CellView(
                    cell: cellText,
                    value: cellVal,
                    column: entry.col,
                    width: entry.width,
                    height: rowHeight,
                    zoom: zoom,
                    palette: palette,
                    showHighlight: tableVM.cellMatches(row: index, col: colIdx),
                    highlightQuery: tableVM.searchQuery,
                    isSelected: isCellSelected,
                    isActiveMatch: isActiveMatchCell
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { inspect(page: page, row: index, col: colIdx) }
                .onTapGesture {
                    appVM.selectedRowIndex = index
                    appVM.selectedCell = (row: index, col: colIdx)
                    isGridFocused = true
                }
            }
        }
        .frame(height: rowHeight)
        .background(
            isRowMatched ? palette.matchFill
                : (isRowSelected ? palette.selectionFill : Color.clear)
        )
        .contextMenu { rowContextMenu(rowIdx: index, page: page) }
    }

    // MARK: - Skeleton

    private var skeletonRows: some View {
        SkeletonBlock(count: 24,
                      rowHeight: rowHeight,
                      gutterWidth: gutterWidth,
                      widths: layout.map { $0.width },
                      totalWidth: contentWidth,
                      palette: palette)
    }

    // MARK: - Helpers

    private func inspect(page: Page, row: Int, col: Int) {
        guard col < tableVM.columns.count else { return }
        let column = tableVM.columns[col]
        let value = col < page.rows[row].count ? page.rows[row][col] : SQLiteValue.null
        appVM.selectedRowIndex = row
        appVM.selectedCell = (row: row, col: col)
        appVM.inspectingCell = CellInspectInfo(
            tableName: tableVM.tableName,
            colName: column.name,
            colType: column.type,
            value: value,
            rowOrdinal: page.start + Int64(row) + 1
        )
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundColor(.secondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowContextMenu(rowIdx: Int, page: Page) -> some View {
        if let sel = appVM.selectedCell, sel.row == rowIdx {
            Button {
                tableVM.copyCellValue(rowIdx: rowIdx, colIdx: sel.col)
            } label: { Label("Copy Cell Value", systemImage: "doc.on.doc") }

            Button {
                inspect(page: page, row: rowIdx, col: sel.col)
            } label: { Label("Inspect Cell Value…", systemImage: "info.circle") }

            Divider()
        }

        Button { tableVM.copyRowAsJSON(rowIdx: rowIdx) } label: {
            Label("Copy Row as JSON", systemImage: "curlybraces")
        }
        Button { tableVM.copyRowAsTSV(rowIdx: rowIdx) } label: {
            Label("Copy Row as TSV", systemImage: "tablecells")
        }
        Button { tableVM.copyRowAsCSV(rowIdx: rowIdx) } label: {
            Label("Copy Row as CSV", systemImage: "list.bullet.rectangle")
        }

        Divider()

        Button { appVM.exportCurrentTable() } label: {
            Label("Export Table as CSV…", systemImage: "arrow.down.to.line")
        }
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard let page = tableVM.currentPage, !page.rows.isEmpty else { return .ignored }
        let maxRow = page.rows.count - 1
        let maxCol = max(0, tableVM.columns.count - 1)
        let curRow = appVM.selectedCell?.row ?? 0
        let curCol = appVM.selectedCell?.col ?? 0

        switch press.key {
        case .upArrow:
            let r = max(0, curRow - 1)
            appVM.selectedCell = (r, curCol); appVM.selectedRowIndex = r
            return .handled
        case .downArrow:
            let r = min(maxRow, curRow + 1)
            appVM.selectedCell = (r, curCol); appVM.selectedRowIndex = r
            return .handled
        case .leftArrow:
            appVM.selectedCell = (curRow, max(0, curCol - 1))
            return .handled
        case .rightArrow:
            appVM.selectedCell = (curRow, min(maxCol, curCol + 1))
            return .handled
        case .pageUp:
            tableVM.previousPage(); return .handled
        case .pageDown:
            tableVM.nextPage(); return .handled
        case .home:
            tableVM.loadPage(offset: 0)
            appVM.selectedCell = (0, curCol); appVM.selectedRowIndex = 0
            return .handled
        case .end:
            tableVM.loadLastPage(); return .handled
        case .space, .return:
            if curRow < page.rows.count, curCol < tableVM.columns.count {
                inspect(page: page, row: curRow, col: curCol)
            }
            return .handled
        case .escape:
            if appVM.inspectingCell != nil { appVM.inspectingCell = nil; return .handled }
            if appVM.isFindBarVisible {
                appVM.isFindBarVisible = false
                tableVM.cancelFind()
                return .handled
            }
            return .ignored
        default:
            if press.characters == "c", press.modifiers.contains(.command),
               let sel = appVM.selectedCell {
                tableVM.copyCellValue(rowIdx: sel.row, colIdx: sel.col)
                return .handled
            }
            return .ignored
        }
    }
}

/// Bridges the core integer grouping formatter for gutter ordinals.
enum SQLiteValueFormatBridge {
    static func ordinal(_ n: Int64) -> String { SQLiteValue.integer(n).displayText }
}

// MARK: - Grid backdrop (zebra + gridlines in one layer)

private struct GridBackdrop: View {
    let rowCount: Int
    let rowHeight: CGFloat
    let gutterWidth: CGFloat
    let columnXs: [CGFloat]
    let totalWidth: CGFloat
    let rule: Color
    let stripe: Color

    var body: some View {
        Canvas { ctx, size in
            // Zebra: tint odd rows.
            for i in stride(from: 1, to: rowCount, by: 2) {
                let rect = CGRect(x: 0, y: CGFloat(i) * rowHeight, width: size.width, height: rowHeight)
                ctx.fill(Path(rect), with: .color(stripe))
            }
            // Horizontal hairlines.
            var h = Path()
            for i in 0...rowCount {
                let y = CGFloat(i) * rowHeight
                h.move(to: CGPoint(x: 0, y: y))
                h.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(h, with: .color(rule), lineWidth: 0.5)
            // Vertical column separators.
            var v = Path()
            v.move(to: CGPoint(x: gutterWidth, y: 0))
            v.addLine(to: CGPoint(x: gutterWidth, y: size.height))
            for x in columnXs.dropFirst() {
                v.move(to: CGPoint(x: gutterWidth + x, y: 0))
                v.addLine(to: CGPoint(x: gutterWidth + x, y: size.height))
            }
            ctx.stroke(v, with: .color(rule), lineWidth: 0.5)
        }
        .frame(width: totalWidth, height: CGFloat(rowCount) * rowHeight)
        .allowsHitTesting(false)
    }
}

// MARK: - Skeleton

private struct SkeletonBlock: View {
    let count: Int
    let rowHeight: CGFloat
    let gutterWidth: CGFloat
    let widths: [CGFloat]
    let totalWidth: CGFloat
    let palette: GridPalette
    @State private var shimmer = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutterWidth, height: rowHeight)
                    ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                        HStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(palette.rule.opacity(shimmer ? 0.9 : 0.4))
                                .frame(width: max(18, w * 0.6), height: 8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(width: w, height: rowHeight)
                    }
                }
                .frame(height: rowHeight)
                .overlay(Rectangle().frame(height: 0.5).foregroundColor(palette.rule), alignment: .bottom)
            }
        }
        .frame(width: totalWidth, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { shimmer = true }
        }
    }
}

// MARK: - Cell

public struct CellView: View {
    let cell: CellText
    let value: SQLiteValue
    let column: Column
    let width: CGFloat
    let height: CGFloat
    let zoom: CGFloat
    let palette: GridPalette
    let showHighlight: Bool
    let highlightQuery: String
    let isSelected: Bool
    let isActiveMatch: Bool

    private var trailing: Bool {
        switch value {
        case .integer, .real: return true
        case .null, .blob: return column.isNumeric
        case .text: return false
        }
    }

    public var body: some View {
        content
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(width: width, height: height, alignment: trailing ? .trailing : .leading)
            .background(
                isActiveMatch ? palette.activeMatchFill
                    : (isSelected ? palette.selectionFill : Color.clear)
            )
            .overlay(
                isActiveMatch
                    ? RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5)
                    : nil
            )
            .help(cell.truncated ? "\(value.displayText.count) characters — double-click to inspect" : "")
    }

    @ViewBuilder
    private var content: some View {
        if value.isNull {
            Text("NULL").foregroundColor(palette.dim.opacity(0.7))
        } else if showHighlight && !highlightQuery.isEmpty {
            Text(highlighted(cell.text, query: highlightQuery))
        } else if case .blob = value {
            Text(cell.text)
                .foregroundColor(.accentColor)
        } else {
            Text(cell.text).foregroundColor(palette.ink)
        }
    }

    private var font: Font {
        switch value {
        case .integer, .real:
            return .system(size: 12 * zoom, design: .default).monospacedDigit()
        default:
            return .system(size: 12 * zoom)
        }
    }

    private func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].backgroundColor = isActiveMatch
                    ? Color(red: 1.0, green: 0.72, blue: 0.15)
                    : palette.markBg
                attributed[attrRange].foregroundColor = palette.markFg
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return attributed
    }
}
