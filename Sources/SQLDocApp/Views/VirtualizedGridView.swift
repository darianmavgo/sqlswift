import SwiftUI
import AppKit
import SQLDocCore

public struct VirtualizedGridView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isGridFocused: Bool

    // Where the grid is scrolled to, quantised to blocks so a scroll re-renders
    // the window of rows and columns once per block rather than once per frame.
    @State private var firstRowBlock = 0
    @State private var xBlock: CGFloat = 0
    /// Row the dev `scroll` command wants at the top (see `scrollAnchor`).
    @State private var scrollAnchorRow = 0

    fileprivate typealias GridCol = (col: Column, fullIndex: Int, width: CGFloat, x: CGFloat, fmt: CellFormat.Kind)

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
        if tableVM.hidesRowNumbers { return 10 * zoom }
        let lastOrdinal = (tableVM.currentPage?.start ?? 0) + Int64(tableVM.currentPage?.rows.count ?? 0)
        let digits = max(3, String(max(1, lastOrdinal)).count)
        return max(DesignToken.gutterMinWidth, CGFloat(digits) * 8 * zoom + 20)
    }

    /// (column, its index in the full column list, width, x-offset, format kind).
    /// Hidden columns are dropped; `fullIndex` keeps find/highlight aligned.
    private var layout: [(col: Column, fullIndex: Int, width: CGFloat, x: CGFloat, fmt: CellFormat.Kind)] {
        var out: [(Column, Int, CGFloat, CGFloat, CellFormat.Kind)] = []
        var x: CGFloat = 0
        // One pass to index the columns; a per-column search is quadratic on wide tables.
        var indexByName: [String: Int] = [:]
        for (i, c) in tableVM.columns.enumerated() where indexByName[c.name] == nil { indexByName[c.name] = i }
        for col in tableVM.visibleColumns {
            guard let i = indexByName[col.name] else { continue }
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
            (appVM.isFindBarVisible || appVM.isBanquetBarEditing || appVM.edit.editingCell != nil) ? .ignored : handleKeyPress(press)
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
        .onChange(of: tableVM.inspectRequest?.row) { _, _ in
            guard let req = tableVM.inspectRequest, let page = tableVM.currentPage,
                  req.row >= 0, req.row < page.rows.count,
                  let col = tableVM.columns.firstIndex(where: { $0.name == req.column }) else { return }
            tableVM.inspectRequest = nil
            inspect(page: page, row: req.row, col: col)
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
                let cols = layout
                let width = gutterWidth + cols.reduce(0) { $0 + $1.width }
                let visCols = columnWindow(cols, viewportWidth: geo.size.width)
                let bodyHeight = max(0, geo.size.height - DesignToken.rowHeight * zoom)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header: scrolls horizontally with the columns, pinned above
                        // the vertical scroll.
                        GridHeaderView(tableVM: tableVM,
                                       zoomScale: appVM.zoomScale,
                                       gutterWidth: gutterWidth,
                                       palette: palette,
                                       columns: visCols.map { $0.col },
                                       leadingPad: visCols.first?.x ?? 0,
                                       totalWidth: width)

                        ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 0) {
                            Group {
                                if tableVM.isLoading && tableVM.currentPage == nil {
                                    skeletonRows(visCols)
                                } else if let page = tableVM.currentPage, !page.rows.isEmpty {
                                    rows(for: page, cols: cols, visCols: visCols, width: width, viewportHeight: bodyHeight)
                                } else {
                                    emptyState(icon: "tray", message: tableVM.tableCount.known && tableVM.tableCount.rows == 0 && tableVM.filters.isEmpty ? "This table is empty." : "No results found")
                                        .frame(width: width, height: 240)
                                }
                            }
                            .background(GeometryReader { g in
                                Color.clear.preference(key: GridScrollYKey.self, value: -g.frame(in: .named("gridV")).minY)
                            })
                            newRowsFooter(visCols: visCols, width: width)
                            }
                        }
                        .coordinateSpace(name: "gridV")
                        .frame(height: bodyHeight)
                        .onChange(of: tableVM.scrollRowRequest) { _, row in
                            guard let row else { return }
                            UILog.event("grid", "scroll", ["row": row])
                            scrollAnchorRow = row
                            tableVM.scrollRowRequest = nil
                            // Next turn, once the anchor has moved to that row.
                            DispatchQueue.main.async { proxy.scrollTo(Self.scrollAnchorID, anchor: .top) }
                        }
                        .onChange(of: appVM.edit.revealNewRowsToken) { _, _ in
                            DispatchQueue.main.async { proxy.scrollTo(Self.newRowsID, anchor: .bottom) }
                        }
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: GridScrollXKey.self, value: -g.frame(in: .named("gridH")).minX)
                    })
                }
                .coordinateSpace(name: "gridH")
                .background(palette.page)
                .onPreferenceChange(GridScrollYKey.self) { y in
                    let quantum = max(1, BehaviorConfig.windowOverscanRows)
                    let block = max(0, Int(y / max(1, rowHeight))) / quantum * quantum
                    if block != firstRowBlock { firstRowBlock = block }
                }
                .onPreferenceChange(GridScrollXKey.self) { x in
                    let quantum = CGFloat(max(1, BehaviorConfig.windowOverscanPx))
                    let block = (max(0, x) / quantum).rounded(.down) * quantum
                    if block != xBlock { xBlock = block }
                }
            }

            if tableVM.showQuickChart, let page = tableVM.currentPage, !page.rows.isEmpty {
                QuickChartStripView(tableVM: tableVM, page: page, palette: palette)
                    .frame(height: chartHeight)
            }
        }
    }

    // MARK: - Rows

    private static let scrollAnchorID = "gridScrollAnchor"

    /// Rows worth building: those in view plus a margin either side.
    private func rowWindow(count: Int, viewportHeight: CGFloat) -> Range<Int> {
        let over = BehaviorConfig.windowOverscanRows
        let visible = Int((viewportHeight / max(1, rowHeight)).rounded(.up))
        let first = min(firstRowBlock, max(0, count - 1))
        let lo = max(0, first - over)
        let hi = min(count, first + max(1, over) + visible + over)
        return lo..<max(lo, hi)
    }

    /// Columns worth building: those intersecting the viewport plus a margin.
    /// `x` in the layout is measured from the right edge of the gutter.
    private func columnWindow(_ cols: [GridCol], viewportWidth: CGFloat) -> [GridCol] {
        let over = CGFloat(BehaviorConfig.windowOverscanPx)
        let lo = xBlock - over - gutterWidth
        let hi = xBlock + over + viewportWidth + over - gutterWidth
        return cols.filter { $0.x + $0.width > lo && $0.x < hi }
    }

    /// The grid body. The scroll content is sized for every row and column, but
    /// only the window near the viewport gets views: a 50,000-row or 500-column
    /// page costs the same to draw and scroll as a small one.
    private func rows(
        for page: Page, cols: [GridCol], visCols: [GridCol], width: CGFloat, viewportHeight: CGFloat
    ) -> some View {
        let rowCount = page.rows.count
        // Scans every row, so compute once per page and column set, not per render.
        let barSignature = tableVM.smartFormat ? cols.map { "\($0.fullIndex):\($0.fmt)" }.joined(separator: ",") : "-"
        let barBounds = tableVM.pageDerived("barBounds", signature: barSignature) {
            computeBarBounds(page: page, cols: cols)
        }
        let window = rowWindow(count: rowCount, viewportHeight: viewportHeight)
        let lead = visCols.first?.x ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(window, id: \.self) { index in
                rowView(page: page, index: index, cols: visCols, lead: lead, barBounds: barBounds, width: width)
            }
        }
        .background(alignment: .topLeading) {
            GridBackdrop(firstRow: window.lowerBound,
                         rowCount: window.count,
                         rowHeight: rowHeight,
                         gutterWidth: gutterWidth,
                         columnXs: visCols.map { $0.x },
                         windowEnd: (visCols.last.map { $0.x + $0.width } ?? 0) + gutterWidth,
                         rule: palette.rule,
                         stripe: palette.stripe)
        }
        .padding(.top, CGFloat(window.lowerBound) * rowHeight)
        .frame(width: width, height: CGFloat(rowCount) * rowHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) { scrollAnchor(rowCount: rowCount) }
    }

    /// An empty, row-sized view placed at `scrollAnchorRow`. Rows outside the
    /// window have no view to scroll to, so `scrollTo` targets this instead.
    private func scrollAnchor(rowCount: Int) -> some View {
        Color.clear
            .frame(width: 1, height: rowHeight)
            .id(Self.scrollAnchorID)
            .padding(.top, CGFloat(max(0, min(scrollAnchorRow, rowCount - 1))) * rowHeight)
            .allowsHitTesting(false)
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
        cols: [GridCol],
        lead: CGFloat,
        barBounds: [Int: Double],
        width: CGFloat
    ) -> some View {
        let rowOrdinal = page.start + Int64(index) + 1
        let rowID = index < page.rowIDs.count ? page.rowIDs[index] : nil
        let isRowMatched = rowID != nil && rowID == tableVM.activeMatchRowID
        let isRowSelected = appVM.selectedRowIndex == index
        let isRowDeleted = rowID.map { appVM.edit.isDeleted(table: page.table, rowID: $0) } ?? false
        let isRowMarked = rowID.map { appVM.edit.markedRowIDs.contains($0) } ?? false

        return HStack(spacing: 0) {
            Text(tableVM.hidesRowNumbers ? "" : SQLiteValueFormatBridge.ordinal(rowOrdinal))
                .font(.system(size: 11 * zoom, weight: .regular, design: .monospaced))
                .foregroundColor(isRowMarked ? Color.accentColor : palette.dim)
                .padding(.trailing, 8)
                .frame(width: gutterWidth, height: rowHeight, alignment: .top)
                .padding(.top, 4)
                .background(isRowMarked ? Color.accentColor.opacity(0.18) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    // ⌘-click marks rows for row operations in edit mode (docs/HighRepEdit.md).
                    if canEditPage, NSEvent.modifierFlags.contains(.command), let id = rowID {
                        if appVM.edit.markedRowIDs.contains(id) { appVM.edit.markedRowIDs.remove(id) }
                        else { appVM.edit.markedRowIDs.insert(id) }
                        return
                    }
                    appVM.selectedRowIndex = index
                    appVM.selectedCell = (row: index, col: cols.first?.fullIndex ?? 0)
                    isGridFocused = true
                }

            // Stand-in for the columns scrolled off to the left.
            if lead > 0 { Color.clear.frame(width: lead, height: rowHeight) }

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

                let pendingVal: SQLiteValue? = rowID.flatMap { id in
                    c < page.columns.count ? appVM.edit.pending(table: page.table, rowID: id, column: page.columns[c].name) : nil
                }
                if appVM.edit.editingCell?.row == index, appVM.edit.editingCell?.col == c {
                    EditCellField(
                        initial: CellCoercion.editorText(for: pendingVal ?? cellVal),
                        width: entry.width, height: rowHeight, zoom: zoom, palette: palette,
                        onSubmit: { text, move in submitEdit(page: page, row: index, col: c, text: text, move: move) },
                        onNull: { submitNull(page: page, row: index, col: c) },
                        onCancel: { appVM.edit.editingCell = nil; isGridFocused = true }
                    )
                } else {
                CellView(
                    cell: pendingVal.map { CellText(text: $0.rawText, truncated: false) } ?? cellText,
                    value: pendingVal ?? cellVal,
                    column: entry.col,
                    width: entry.width,
                    height: rowHeight,
                    zoom: zoom,
                    palette: palette,
                    wrap: tableVM.wrapCells,
                    smartText: (tableVM.smartFormat && pendingVal == nil) ? CellFormat.pretty(value: cellVal, kind: entry.fmt) : nil,
                    tone: tableVM.smartFormat ? CellFormat.tone(value: cellVal, kind: entry.fmt) : .neutral,
                    barRatio: ratio,
                    showHighlight: tableVM.cellMatches(row: index, col: c),
                    highlightQuery: tableVM.searchQuery,
                    highlightCaseSensitive: tableVM.searchCaseSensitive,
                    isSelected: isCellSelected,
                    isActiveMatch: isActiveMatchCell,
                    isPending: pendingVal != nil,
                    originalText: pendingVal != nil ? cellVal.rawText : nil,
                    isDeleted: isRowDeleted
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { activate(page: page, row: index, col: c) }
                .onTapGesture {
                    appVM.selectedRowIndex = index
                    appVM.selectedCell = (row: index, col: c)
                    isGridFocused = true
                    if NSEvent.modifierFlags.contains(.option), let valStr = cellVal.textValue, !cellVal.isNull, !cellVal.isPartial {
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
        }
        .frame(width: width, height: rowHeight, alignment: .leading)
        .background(
            isRowMatched ? palette.matchFill
                : (isRowSelected ? palette.selectionFill : Color.clear)
        )
        .contextMenu { rowContextMenu(rowIdx: index, page: page) }
    }

    // MARK: - Skeleton

    private func skeletonRows(_ visCols: [GridCol]) -> some View {
        SkeletonBlock(count: 24,
                      rowHeight: rowHeight,
                      gutterWidth: gutterWidth,
                      widths: visCols.map { $0.width },
                      totalWidth: gutterWidth + visCols.reduce(0) { $0 + $1.width },
                      palette: palette)
    }

    // MARK: - New rows (docs/HighRepEdit.md)

    private static let newRowsID = "gridNewRows"

    /// Pending INSERTs, drawn from the edit buffer below the loaded page. They are never part
    /// of the page query, so paging, sorting and the Banquet URL are unaffected.
    @ViewBuilder
    private func newRowsFooter(visCols: [GridCol], width: CGFloat) -> some View {
        if canEditPage, let page = tableVM.currentPage {
            let pending = appVM.edit.newRows(table: page.table)
            if !pending.isEmpty {
                let lead = visCols.first?.x ?? 0
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pending, id: \.id) { nr in
                        HStack(spacing: 0) {
                            Text("new")
                                .font(.system(size: 10 * zoom, weight: .semibold, design: .monospaced))
                                .foregroundColor(.green)
                                .padding(.trailing, 8)
                                .frame(width: gutterWidth, height: rowHeight, alignment: .trailing)
                            if lead > 0 { Color.clear.frame(width: lead, height: rowHeight) }
                            ForEach(visCols, id: \.col.id) { entry in newRowCell(nr, entry) }
                        }
                        .frame(width: width, alignment: .leading)
                        .background(Color.green.opacity(0.10))
                        .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(palette.ruleStrong).frame(height: 1) }
                .id(Self.newRowsID)
            }
        }
    }

    @ViewBuilder
    private func newRowCell(_ nr: NewRow, _ entry: GridCol) -> some View {
        let c = entry.fullIndex
        let col = entry.col
        let insertable = EditViewModel.isInsertable(col)
        if appVM.edit.editingNewCell?.id == nr.id, appVM.edit.editingNewCell?.col == c {
            EditCellField(
                initial: nr.values[col.name].map { CellCoercion.editorText(for: $0) } ?? "",
                width: entry.width, height: rowHeight, zoom: zoom, palette: palette,
                onSubmit: { text, move in submitNewRowCell(nr, entry, text: text, move: move) },
                onNull: {
                    if let err = appVM.edit.stageNewRowNull(id: nr.id, column: col) { appVM.errorMessage = err }
                    appVM.edit.editingNewCell = nil; isGridFocused = true
                },
                onCancel: { appVM.edit.editingNewCell = nil; isGridFocused = true }
            )
        } else {
            let v = nr.values[col.name]
            Text(v.map { $0.isNull ? "NULL" : $0.rawText } ?? (insertable ? "" : "auto"))
                .font(.system(size: 12 * zoom, design: .monospaced))
                .foregroundColor(v == nil || v?.isNull == true ? palette.dim : palette.ink)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: entry.width, height: rowHeight, alignment: .leading)
                .overlay(alignment: .trailing) { Rectangle().fill(palette.rule.opacity(0.65)).frame(width: 1) }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if insertable { appVM.edit.editingNewCell = (id: nr.id, col: c) } }
                .help(insertable ? "Double-click to edit · empty cells use the column default" : "Assigned by SQLite")
                .contextMenu {
                    if insertable {
                        Button("Set NULL") { if let e = appVM.edit.stageNewRowNull(id: nr.id, column: col) { appVM.errorMessage = e } }
                        Button("Set Empty String") { if let e = appVM.edit.stageNewRowCell(id: nr.id, column: col, text: "") { appVM.errorMessage = e } }
                            .disabled(col.isNumeric)
                        Button("Use Default") { appVM.edit.clearNewRowCell(id: nr.id, column: col) }
                        Divider()
                    }
                    Button("Discard New Row") {
                        appVM.edit.session?.buffer.deleteRow(table: nr.table, rowID: nr.id, original: [:])
                        appVM.edit.noteBufferChanged()
                    }
                }
        }
    }

    /// Stages a typed value into a new row. An empty field on an unset cell leaves the column
    /// default alone, so Tab can pass over columns without tripping number parsing.
    private func submitNewRowCell(_ nr: NewRow, _ entry: GridCol, text: String, move: EditCellField.Move) -> String? {
        let cur = appVM.edit.newRows(table: nr.table).first { $0.id == nr.id } ?? nr
        if !(text.isEmpty && cur.values[entry.col.name] == nil) {
            if let err = appVM.edit.stageNewRowCell(id: nr.id, column: entry.col, text: text) { return err }
        }
        let vis = layout.filter { EditViewModel.isInsertable($0.col) }.map { $0.fullIndex }
        if move == .right, let p = vis.firstIndex(of: entry.fullIndex), p + 1 < vis.count {
            appVM.edit.editingNewCell = (id: nr.id, col: vis[p + 1])
        } else {
            appVM.edit.editingNewCell = nil
            isGridFocused = true
        }
        return nil
    }

    // MARK: - Helpers

    // MARK: - Editing (docs/BanquetEditStyle.md)

    /// True when the open table and page can take cell edits (rule 4).
    private var canEditPage: Bool {
        appVM.edit.canEditActiveTable
    }

    /// Double-click / Return: open the inline editor when editing, else the inspector.
    private func activate(page: Page, row: Int, col: Int) {
        guard canEditPage, row < page.rowIDs.count, row < page.rows.count,
              col < page.columns.count, col < page.rows[row].count,
              !appVM.edit.isDeleted(table: page.table, rowID: page.rowIDs[row]),
              EditViewModel.isCellEditable(column: page.columns[col], value: page.rows[row][col])
        else { inspect(page: page, row: row, col: col); return }
        appVM.selectedRowIndex = row
        appVM.selectedCell = (row: row, col: col)
        guard page.rows[row][col].isPartial else {
            appVM.edit.editingCell = (row: row, col: col)
            return
        }
        // The page holds only the head of this value. The editor, and the
        // original-value check at commit, both need all of it.
        Task {
            if await tableVM.resolveFullValues(row: row, cols: [col]) {
                appVM.edit.editingCell = (row: row, col: col)
            } else {
                appVM.errorMessage = "Could not load the full value of this cell to edit it."
            }
        }
    }

    private func submitEdit(page: Page, row: Int, col: Int, text: String, move: EditCellField.Move) -> String? {
        guard row < page.rowIDs.count else { return "Row has no rowid." }
        if let err = appVM.edit.stage(table: page.table, rowID: page.rowIDs[row], column: page.columns[col],
                                      original: page.rows[row][col], text: text) { return err }
        advance(page: page, row: row, col: col, move: move)
        return nil
    }

    private func submitNull(page: Page, row: Int, col: Int) {
        guard row < page.rowIDs.count else { return }
        if page.rows[row][col].isPartial {
            // Staging needs the stored original; fetch it, then come back with the patched page.
            Task {
                if await tableVM.resolveFullValues(row: row, cols: [col]), let fresh = tableVM.currentPage,
                   row < fresh.rows.count, col < fresh.rows[row].count, !fresh.rows[row][col].isPartial {
                    submitNull(page: fresh, row: row, col: col)
                } else {
                    appVM.errorMessage = "Could not load the full value of this cell to edit it."
                }
            }
            return
        }
        if let err = appVM.edit.stageNull(table: page.table, rowID: page.rowIDs[row], column: page.columns[col],
                                          original: page.rows[row][col]) {
            appVM.errorMessage = err
            return
        }
        advance(page: page, row: row, col: col, move: .none)
    }

    /// Single-cell paste for edit mode. False when there is nothing sensible to paste here,
    /// so ⌘V falls back to its usual meaning.
    private func pasteIntoSelectedCell(page: Page) -> Bool {
        guard let sel = appVM.selectedCell, sel.row < page.rows.count, sel.row < page.rowIDs.count,
              sel.col < page.columns.count, sel.col < page.rows[sel.row].count,
              !page.rows[sel.row][sel.col].isPartial,
              !appVM.edit.isDeleted(table: page.table, rowID: page.rowIDs[sel.row]),
              EditViewModel.isCellEditable(column: page.columns[sel.col], value: page.rows[sel.row][sel.col]),
              let text = NSPasteboard.general.string(forType: .string), !text.contains("\n") else { return false }
        if let err = appVM.edit.stage(table: page.table, rowID: page.rowIDs[sel.row], column: page.columns[sel.col],
                                      original: page.rows[sel.row][sel.col], text: text) {
            appVM.errorMessage = err
        }
        return true
    }

    private func submitEmpty(page: Page, row: Int, col: Int) {
        guard row < page.rowIDs.count else { return }
        if page.rows[row][col].isPartial {
            Task {
                if await tableVM.resolveFullValues(row: row, cols: [col]), let fresh = tableVM.currentPage,
                   row < fresh.rows.count, col < fresh.rows[row].count, !fresh.rows[row][col].isPartial {
                    submitEmpty(page: fresh, row: row, col: col)
                } else {
                    appVM.errorMessage = "Could not load the full value of this cell to edit it."
                }
            }
            return
        }
        if let err = appVM.edit.stageEmptyString(table: page.table, rowID: page.rowIDs[row], column: page.columns[col],
                                                 original: page.rows[row][col]) {
            appVM.errorMessage = err
        }
    }

    private func advance(page: Page, row: Int, col: Int, move: EditCellField.Move) {
        appVM.edit.editingCell = nil
        isGridFocused = true
        switch move {
        case .none: break
        case .down:
            let r = min(page.rows.count - 1, row + 1)
            appVM.selectedCell = (r, col); appVM.selectedRowIndex = r
        case .right:
            let vis = layout.map { $0.fullIndex }
            if let p = vis.firstIndex(of: col) { appVM.selectedCell = (row, vis[min(vis.count - 1, p + 1)]) }
        }
    }

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
        if case .textPrefix = value, page.rowKeyed, row < page.rowIDs.count, col < page.columns.count {
            let doc = tableVM.doc, table = page.table, colName = page.columns[col].name
            let rowID = page.rowIDs[row]
            info.loadText = {
                // No time budget: the user asked for this one value, however long it is.
                guard let v = doc.cellValues(table: table, columns: [colName], rowID: rowID)?.first else { return nil }
                if case .text(let s) = v { return s }
                return v.isNull ? nil : v.rawText
            }
        }
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
            if canEditPage, sel.col < page.columns.count,
               EditViewModel.isCellEditable(column: page.columns[sel.col], value: val) {
                Button("Set NULL") { submitNull(page: page, row: rowIdx, col: sel.col) }
                Button("Set Empty String") { submitEmpty(page: page, row: rowIdx, col: sel.col) }
                    .disabled(page.columns[sel.col].isNumeric)
                Divider()
            }
            if canEditPage {
                Button("Duplicate Row") { Task { await appVM.edit.duplicateSelectedRow() } }
                Button(appVM.edit.markedRowIDs.count > 1 ? "Delete \(appVM.edit.markedRowIDs.count) Rows" : "Delete Row") {
                    appVM.edit.deleteSelectedRows()
                }
                Divider()
            }
            if let valStr = val.textValue, !val.isNull, !val.isBlob, !val.isPartial {
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

    /// Rows a Page Up/Down moves when the whole table is one page.
    private static let allRowsPageStep = 25

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
            if tableVM.isShowingAllRows {
                let r = max(0, curRow - Self.allRowsPageStep)
                appVM.selectedCell = (r, curCol); appVM.selectedRowIndex = r
                return .handled
            }
            appVM.paginatePrevious(tableVM: tableVM); return .handled
        case .pageDown:
            if tableVM.isShowingAllRows {
                let r = min(maxRow, curRow + Self.allRowsPageStep)
                appVM.selectedCell = (r, curCol); appVM.selectedRowIndex = r
                return .handled
            }
            appVM.paginateNext(tableVM: tableVM); return .handled
        case .home:
            appVM.paginateFirst(tableVM: tableVM)
            appVM.selectedCell = (0, curCol); appVM.selectedRowIndex = 0
            return .handled
        case .end:
            if tableVM.isShowingAllRows {
                appVM.selectedCell = (maxRow, curCol); appVM.selectedRowIndex = maxRow
                return .handled
            }
            appVM.paginateLast(tableVM: tableVM); return .handled
        case .space, .return:
            if curRow < page.rows.count, curCol < tableVM.columns.count {
                if press.key == .return { activate(page: page, row: curRow, col: curCol) }
                else { inspect(page: page, row: curRow, col: curCol) }
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
            if press.characters.lowercased() == "z", press.modifiers.contains(.command), appVM.edit.isEditing(appVM.activeDocEntry) {
                if press.modifiers.contains(.shift) { appVM.edit.redo() } else { appVM.edit.undo() }
                return .handled
            }
            if press.characters == "v", press.modifiers.contains(.command) {
                // In edit mode ⌘V fills the selected cell; ⇧⌘V still pastes into the Banquet bar.
                if canEditPage, pasteIntoSelectedCell(page: page) { return .handled }
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

/// Zebra stripes, hairlines and column rules for the windowed rows and columns
/// only. One canvas for the whole table would be over a million points tall on
/// a 50,000-row page.
private struct GridBackdrop: View {
    let firstRow: Int
    let rowCount: Int
    let rowHeight: CGFloat
    let gutterWidth: CGFloat
    /// Left edges of the windowed columns, measured from the gutter's right edge.
    let columnXs: [CGFloat]
    /// Right edge of the last windowed column, measured from the row's left edge.
    let windowEnd: CGFloat
    let rule: Color
    let stripe: Color

    var body: some View {
        Canvas { ctx, size in
            // Zebra: tint odd rows (by their index in the page, not in the window).
            for i in 0..<rowCount where (firstRow + i) % 2 == 1 {
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
            // Vertical separators at the left edge of each windowed column; the
            // first column's left edge is the gutter rule.
            var v = Path()
            for x in columnXs {
                v.move(to: CGPoint(x: gutterWidth + x, y: 0))
                v.addLine(to: CGPoint(x: gutterWidth + x, y: size.height))
            }
            ctx.stroke(v, with: .color(rule.opacity(0.95)), lineWidth: 1.0)
        }
        .frame(width: max(0, windowEnd), height: CGFloat(rowCount) * rowHeight)
        .allowsHitTesting(false)
    }
}

private struct GridScrollYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct GridScrollXKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
    /// Staged, uncommitted edit (edit mode): tinted, with the original in the tooltip.
    var isPending: Bool = false
    var originalText: String? = nil
    /// Row staged for DELETE: struck through and tinted red until commit.
    var isDeleted: Bool = false

    private var trailing: Bool {
        switch value {
        case .integer, .real: return true
        case .null, .blob: return column.isNumeric
        case .text, .textPrefix: return false
        }
    }

    private var shownText: String { smartText ?? cell.text }

    public var body: some View {
        content
            .font(font)
            .strikethrough(isDeleted)
            .opacity(isDeleted ? 0.6 : 1)
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
                    : (isSelected ? palette.selectionFill
                        : (isDeleted ? Color.red.opacity(0.16) : (isPending ? Color.orange.opacity(0.22) : Color.clear)))
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
        if isDeleted { return "row will be deleted on commit" }
        if isPending { return "pending edit · was: \(originalText ?? "")" }
        if case .textPrefix(_, let total) = value {
            return "\(total.formatted()) bytes — double-click to inspect"
        }
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
