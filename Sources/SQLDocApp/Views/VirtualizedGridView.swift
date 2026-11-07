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
    private var rowHeight: CGFloat { DesignToken.rowHeight * zoom * CGFloat(tableVM.rowHeightScale) }

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

    /// (column, its index in the full column list, width, x-offset, format kind).
    /// Hidden columns are dropped; `fullIndex` keeps find/highlight aligned.
    private var layout: [(col: Column, fullIndex: Int, width: CGFloat, x: CGFloat, fmt: CellFormat.Kind)] {
        var out: [(Column, Int, CGFloat, CGFloat, CellFormat.Kind)] = []
        var x: CGFloat = 0
        for col in tableVM.visibleColumns {
            guard let i = tableVM.columns.firstIndex(where: { $0.name == col.name }) else { continue }
            let w = (tableVM.columnWidths[col.name] ?? DesignToken.colDefaultWidth) * zoom
            let fmt = tableVM.smartFormat ? CellFormat.kind(forColumn: col.name, isNumeric: col.isNumeric) : .none
            out.append((col, i, w, x, fmt))
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
        .focusable(!appVM.isFindBarVisible && !appVM.isBanquetBarEditing)
        .focused($isGridFocused)
        .onKeyPress { press in
            // The find field or Banquet URL editor owns the keyboard while open.
            (appVM.isFindBarVisible || appVM.isBanquetBarEditing) ? .ignored : handleKeyPress(press)
        }
        .onAppear { isGridFocused = !appVM.isFindBarVisible && !appVM.isBanquetBarEditing }
        .onChange(of: appVM.isFindBarVisible) { _, visible in
            if visible { isGridFocused = false }
        }
        .onChange(of: appVM.isBanquetBarEditing) { _, editing in
            if editing { isGridFocused = false }
        }
        .onChange(of: tableVM.currentPage?.start) { _, _ in
            if let idx = tableVM.consumePendingSelection(),
               let page = tableVM.currentPage, idx < page.rows.count {
                selectRow(idx)
            }
        }
        .onChange(of: tableVM.selectRowRequest) { _, req in
            if let idx = req { selectRow(idx); tableVM.selectRowRequest = nil }
        }
    }

    private func selectRow(_ idx: Int) {
        appVM.selectedRowIndex = idx
        appVM.selectedCell = (row: idx, col: layout.first?.fullIndex ?? 0)
        isGridFocused = true
    }

    private var gridBody: some View {
        let chartHeight: CGFloat = tableVM.showQuickChart ? 148 : 0
        return VStack(spacing: 0) {
            if let err = tableVM.queryError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("SQL Error: \(err)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Edit in Banquet Bar (⌘L)") {
                        appVM.isBanquetBarEditing = true
                    }
                    .controlSize(.small)
                    Button("Reset to Table (*)") {
                        tableVM.showAllColumns()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
                .overlay(Divider(), alignment: .bottom)
            }

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
                                emptyState(icon: "tray", message: tableVM.tableCount.known && tableVM.tableCount.rows == 0 && tableVM.filters.isEmpty ? "This table is empty." : "No results found")
                                    .frame(width: contentWidth, height: 240)
                            }
                        }
                        .frame(height: max(0, geo.size.height - DesignToken.rowHeight * zoom))
                    }
                }
                .background(palette.page)
            }

            if tableVM.showQuickChart, let page = tableVM.currentPage, !page.rows.isEmpty {
                QuickChartStripView(tableVM: tableVM, page: page, palette: palette)
                    .frame(height: chartHeight)
            }
        }
    }

    // MARK: - Rows

    private func rows(for page: Page) -> some View {
        let rowCount = page.rows.count
        let cols = layout
        let width = gutterWidth + cols.reduce(0) { $0 + $1.width }
        let barBounds = computeBarBounds(page: page, cols: cols)
        return LazyVStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { index in
                rowView(page: page, index: index, cols: cols, barBounds: barBounds, width: width)
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

    private func computeBarBounds(
        page: Page,
        cols: [(col: Column, fullIndex: Int, width: CGFloat, x: CGFloat, fmt: CellFormat.Kind)]
    ) -> [Int: Double] {
        guard tableVM.smartFormat, page.rows.count >= 2 else { return [:] }
        var maxAbsByCol: [Int: Double] = [:]
        for entry in cols {
            switch entry.fmt {
            case .rate, .signedRate, .drawdown, .ratio, .signedPrice:
                var maxAbs: Double = 0
                for row in page.rows where entry.fullIndex < row.count {
                    if let d = row[entry.fullIndex].doubleValue, d.isFinite {
                        maxAbs = max(maxAbs, abs(d))
                    }
                }
                if maxAbs > 0 {
                    maxAbsByCol[entry.fullIndex] = maxAbs
                }
            default:
                break
            }
        }
        return maxAbsByCol
    }

    private func rowView(
        page: Page,
        index: Int,
        cols: [(col: Column, fullIndex: Int, width: CGFloat, x: CGFloat, fmt: CellFormat.Kind)],
        barBounds: [Int: Double],
        width: CGFloat
    ) -> some View {
        let rowOrdinal = page.start + Int64(index) + 1
        let rowID = index < page.rowIDs.count ? page.rowIDs[index] : nil
        let isRowMatched = rowID != nil && rowID == tableVM.activeMatchRowID
        let isRowSelected = appVM.selectedRowIndex == index

        return HStack(spacing: 0) {
            Text(SQLiteValueFormatBridge.ordinal(rowOrdinal))
                .font(.system(size: 11 * zoom, weight: .regular, design: .monospaced))
                .foregroundColor(palette.dim)
                .padding(.trailing, 8)
                .frame(width: gutterWidth, height: rowHeight, alignment: .top)
                .padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    appVM.selectedRowIndex = index
                    appVM.selectedCell = (row: index, col: cols.first?.fullIndex ?? 0)
                    isGridFocused = true
                }

            ForEach(cols, id: \.col.id) { entry in
                let c = entry.fullIndex
                let cellText = (index < page.text.count && c < page.text[index].count)
                    ? page.text[index][c] : CellText(text: "", truncated: false)
                let cellVal = c < page.rows[index].count ? page.rows[index][c] : SQLiteValue.null
                let isActiveMatchCell = isRowMatched && c == tableVM.activeMatchColumnIndex
                let isCellSelected = appVM.selectedCell?.row == index && appVM.selectedCell?.col == c
                let ratio: Double? = {
                    guard let maxAbs = barBounds[c], maxAbs > 0, let d = cellVal.doubleValue, d.isFinite else { return nil }
                    return min(1.0, max(0.0, abs(d) / maxAbs))
                }()

                CellView(
                    cell: cellText,
                    value: cellVal,
                    column: entry.col,
                    width: entry.width,
                    height: rowHeight,
                    zoom: zoom,
                    palette: palette,
                    wrap: tableVM.wrapCells,
                    smartText: tableVM.smartFormat ? CellFormat.pretty(value: cellVal, kind: entry.fmt) : nil,
                    tone: tableVM.smartFormat ? CellFormat.tone(value: cellVal, kind: entry.fmt) : .neutral,
                    barRatio: ratio,
                    showHighlight: tableVM.cellMatches(row: index, col: c),
                    highlightQuery: tableVM.searchQuery,
                    highlightCaseSensitive: tableVM.searchCaseSensitive,
                    isSelected: isCellSelected,
                    isActiveMatch: isActiveMatchCell
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { inspect(page: page, row: index, col: c) }
                .onTapGesture {
                    appVM.selectedRowIndex = index
                    appVM.selectedCell = (row: index, col: c)
                    isGridFocused = true
                    if NSEvent.modifierFlags.contains(.option), let valStr = cellVal.textValue, !cellVal.isNull {
                        let existing = tableVM.filters.first(where: { $0.column == entry.col.name && $0.op == .equals })?.value
                        if existing == valStr {
                            tableVM.setFilter(column: entry.col.name, op: .equals, value: "")
                        } else {
                            tableVM.setFilter(column: entry.col.name, op: .equals, value: valStr)
                        }
                    }
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
        var info = CellInspectInfo(
            tableName: tableVM.tableName,
            colName: column.name,
            colType: column.type,
            value: value,
            rowOrdinal: page.start + Int64(row) + 1
        )
        if case .blob = value, row < page.rowIDs.count, page.rowIDs[row] != 0 {
            let doc = tableVM.doc, table = tableVM.tableName, colName = column.name
            let rowID = page.rowIDs[row]
            info.loadBlob = { doc.blobData(table: table, column: colName, rowID: rowID) }
        }
        appVM.inspectingCell = info
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
        if let sel = appVM.selectedCell, sel.row == rowIdx,
           sel.col < tableVM.columns.count, rowIdx < page.rows.count, sel.col < page.rows[rowIdx].count {
            let colName = tableVM.columns[sel.col].name
            let val = page.rows[rowIdx][sel.col]
            if let valStr = val.textValue, !val.isNull, !val.isBlob {
                Button {
                    tableVM.setFilter(column: colName, op: .equals, value: valStr)
                } label: {
                    Label("Filter '\(colName) = \(valStr)'", systemImage: "line.3.horizontal.decrease.circle")
                }

                let related = tableVM.doc.relatedTables(forColumn: colName, excluding: tableVM.tableName)
                if !related.isEmpty {
                    Menu {
                        ForEach(related, id: \.self) { targetTable in
                            Button(targetTable) {
                                appVM.drillDown(
                                    toTable: targetTable,
                                    filters: [ColumnFilter(column: colName, op: .equals, value: valStr)]
                                )
                            }
                        }
                    } label: {
                        Label("Jump to '\(colName) = \(valStr)' in…", systemImage: "arrow.right.doc.on.clipboard")
                    }
                }
            }

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
        let visible = layout.map { $0.fullIndex }               // full-index of each shown column, in order
        let curRow = appVM.selectedCell?.row ?? 0
        let curCol = appVM.selectedCell?.col ?? (visible.first ?? 0)
        let curVisPos = visible.firstIndex(of: curCol) ?? 0

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
            appVM.selectedCell = (curRow, visible[max(0, curVisPos - 1)])
            return .handled
        case .rightArrow:
            appVM.selectedCell = (curRow, visible[min(visible.count - 1, curVisPos + 1)])
            return .handled
        case .pageUp:
            appVM.paginatePrevious(tableVM: tableVM); return .handled
        case .pageDown:
            appVM.paginateNext(tableVM: tableVM); return .handled
        case .home:
            appVM.paginateFirst(tableVM: tableVM)
            appVM.selectedCell = (0, curCol); appVM.selectedRowIndex = 0
            return .handled
        case .end:
            appVM.paginateLast(tableVM: tableVM); return .handled
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
            if press.characters == "v", press.modifiers.contains(.command) {
                appVM.pasteFromClipboard()
                return .handled
            }
            if (press.characters == "/" || press.characters == "?"), press.modifiers.isEmpty {
                appVM.isBanquetBarEditing = true
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
            ctx.stroke(v, with: .color(rule.opacity(0.95)), lineWidth: 1.0)
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
    var wrap: Bool = false
    var smartText: String? = nil
    var tone: CellFormat.Tone = .neutral
    var barRatio: Double? = nil
    let showHighlight: Bool
    let highlightQuery: String
    var highlightCaseSensitive: Bool = false
    let isSelected: Bool
    let isActiveMatch: Bool

    private var trailing: Bool {
        switch value {
        case .integer, .real: return true
        case .null, .blob: return column.isNumeric
        case .text: return false
        }
    }

    private var shownText: String { smartText ?? cell.text }

    public var body: some View {
        content
            .font(font)
            .lineLimit(wrap ? nil : 1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, wrap ? 3 : 0)
            .frame(width: width, height: height, alignment: alignment)
            .background(alignment: .trailing) {
                if let ratio = barRatio, ratio > 0.02 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barFillColor)
                        .frame(width: max(2, (width - 6) * CGFloat(ratio)), height: max(4, height - 6))
                        .padding(.trailing, 3)
                }
            }
            .background(
                isActiveMatch ? palette.activeMatchFill
                    : (isSelected ? palette.selectionFill : Color.clear)
            )
            .overlay(alignment: .trailing) {
                Rectangle().fill(palette.rule.opacity(0.65)).frame(width: 1)
            }
            .overlay(
                isActiveMatch
                    ? RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5)
                    : nil
            )
            .help(helpText)
    }

    private var barFillColor: Color {
        switch tone {
        case .positive:
            return Color(red: 0.06, green: 0.62, blue: 0.38).opacity(0.13)
        case .negative:
            return Color(red: 0.86, green: 0.24, blue: 0.24).opacity(0.13)
        case .neutral:
            return Color.accentColor.opacity(0.11)
        }
    }

    private var alignment: Alignment {
        let h: HorizontalAlignment = trailing ? .trailing : .leading
        return wrap ? Alignment(horizontal: h, vertical: .top) : Alignment(horizontal: h, vertical: .center)
    }

    private var helpText: String {
        let raw = value.rawText
        if smartText != nil || raw != shownText {
            return "raw: \(raw)"
        }
        return cell.truncated ? "\(raw.count) characters — double-click to inspect" : ""
    }

    private var inkColor: Color {
        switch tone {
        case .positive:
            return Color(red: 0.06, green: 0.62, blue: 0.38)
        case .negative:
            return Color(red: 0.86, green: 0.24, blue: 0.24)
        case .neutral:
            return palette.ink
        }
    }

    @ViewBuilder
    private var content: some View {
        if value.isNull {
            Text("NULL").foregroundColor(palette.dim.opacity(0.7))
        } else if smartText != nil {
            Text(shownText).foregroundColor(inkColor)
        } else if showHighlight && !highlightQuery.isEmpty {
            Text(highlighted(cell.text, query: highlightQuery))
        } else if case .blob = value {
            Text(cell.text)
                .foregroundColor(.accentColor)
        } else {
            Text(cell.text).foregroundColor(inkColor)
        }
    }

    private var font: Font {
        switch value {
        case .integer, .real:
            return .system(size: 12 * zoom, design: .monospaced).monospacedDigit()
        default:
            return .system(size: 12 * zoom)
        }
    }

    private func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        var searchRange = text.startIndex..<text.endIndex
        let opts: String.CompareOptions = highlightCaseSensitive ? [] : .caseInsensitive
        while let range = text.range(of: query, options: opts, range: searchRange) {
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

// MARK: - Quick Chart Strip (Inline Sparkline / Equity & Metric Plot)

private struct QuickChartStripView: View {
    @ObservedObject var tableVM: TableViewModel
    let page: Page
    let palette: GridPalette

    private var numericColumns: [Column] {
        tableVM.columns.filter { $0.isNumeric && !$0.pk }
    }

    private var activeColumnName: String {
        if let chosen = tableVM.chartColumn, numericColumns.contains(where: { $0.name == chosen }) {
            return chosen
        }
        return tableVM.defaultChartColumn() ?? numericColumns.first?.name ?? ""
    }

    private var seriesPoints: [Double] {
        guard let colIdx = tableVM.columns.firstIndex(where: { $0.name == activeColumnName }) else { return [] }
        return page.rows.compactMap { row in
            guard colIdx < row.count else { return nil }
            return row[colIdx].doubleValue
        }
    }

    var body: some View {
        let pts = seriesPoints
        let minVal = pts.min() ?? 0
        let maxVal = pts.max() ?? 0
        let lastVal = pts.last ?? 0
        let firstVal = pts.first ?? 0
        let isUp = lastVal >= firstVal

        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)

                    Picker("", selection: Binding(
                        get: { activeColumnName },
                        set: { tableVM.chartColumn = $0 }
                    )) {
                        ForEach(numericColumns) { col in
                            Text(col.name).tag(col.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .controlSize(.small)
                }

                if !pts.isEmpty {
                    HStack(spacing: 14) {
                        statPill(label: "Points", value: "\(pts.count)")
                        statPill(label: "Min", value: SQLiteValueFormat.realString(minVal))
                        statPill(label: "Max", value: SQLiteValueFormat.realString(maxVal))
                        statPill(label: "Last", value: SQLiteValueFormat.realString(lastVal))
                    }
                }

                Spacer()

                Button(action: { tableVM.showQuickChart = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide chart")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if pts.count >= 2 {
                Canvas { ctx, size in
                    let span = max(1e-9, maxVal - minVal)
                    let stepX = size.width / CGFloat(max(1, pts.count - 1))
                    let padY: CGFloat = 8
                    let plotH = max(1, size.height - padY * 2)

                    func pt(_ i: Int, _ v: Double) -> CGPoint {
                        let x = CGFloat(i) * stepX
                        let norm = CGFloat((v - minVal) / span)
                        let y = padY + plotH * (1.0 - norm)
                        return CGPoint(x: x, y: y)
                    }

                    // Zero baseline if min < 0 < max
                    if minVal < 0 && maxVal > 0 {
                        let zeroY = pt(0, 0).y
                        var zeroLine = Path()
                        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
                        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
                        ctx.stroke(zeroLine, with: .color(palette.ruleStrong), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
                    }

                    var line = Path()
                    var area = Path()
                    let firstPt = pt(0, pts[0])
                    line.move(to: firstPt)
                    area.move(to: CGPoint(x: firstPt.x, y: size.height))
                    area.addLine(to: firstPt)

                    for (i, v) in pts.enumerated().dropFirst() {
                        let p = pt(i, v)
                        line.addLine(to: p)
                        area.addLine(to: p)
                    }
                    area.addLine(to: CGPoint(x: CGFloat(pts.count - 1) * stepX, y: size.height))
                    area.closeSubpath()

                    let strokeColor = isUp ? Color(red: 0.06, green: 0.62, blue: 0.38) : Color(red: 0.86, green: 0.24, blue: 0.24)
                    ctx.fill(area, with: .color(strokeColor.opacity(0.14)))
                    ctx.stroke(line, with: .color(strokeColor), lineWidth: 1.75)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            } else {
                Text("Need at least 2 numeric rows on the current page to plot.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.head)
    }

    private func statPill(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.ink)
        }
    }
}
