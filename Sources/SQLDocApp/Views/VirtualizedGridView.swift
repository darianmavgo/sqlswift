import SwiftUI
import AppKit
import SQLDocCore

public struct VirtualizedGridView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel
    let gutterWidth: CGFloat = 60
    @FocusState private var isGridFocused: Bool

    public init(appVM: AppViewModel, tableVM: TableViewModel) {
        self.appVM = appVM
        self.tableVM = tableVM
    }

    private var rowHeight: CGFloat {
        DesignToken.rowHeight * appVM.zoomScale
    }

    public var body: some View {
        VStack(spacing: 0) {
            if tableVM.columns.isEmpty && !tableVM.isLoading {
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
                // Top Pagination Bar (placed above header and grid)
                topPaginationBar

                // Single unified horizontal scroll container for both Header and Rows
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Table header (pinned at top of vertical scroll)
                        GridHeaderView(tableVM: tableVM, zoomScale: appVM.zoomScale)
                            .background(Color(NSColor.controlBackgroundColor))

                        // Table rows / Skeleton rows
                        if tableVM.isLoading && tableVM.currentPage == nil {
                            skeletonLoadingView
                        } else if let page = tableVM.currentPage, !page.rows.isEmpty {
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(page.rows.enumerated()), id: \.offset) { index, row in
                                        let rowOrdinal = page.start + Int64(index) + 1
                                        let rowID = index < page.rowIDs.count ? page.rowIDs[index] : nil
                                        let isEven = index % 2 == 0
                                        let isRowMatched = (rowID != nil && rowID == tableVM.activeMatchRowID)
                                        let isRowSelected = appVM.selectedRowIndex == index || isRowMatched

                                        HStack(spacing: 0) {
                                            // Row gutter index
                                            Text("\(rowOrdinal)")
                                                .font(.system(size: 11 * appVM.zoomScale, weight: .regular, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .frame(width: gutterWidth, height: rowHeight)
                                                .background(isRowSelected ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor).opacity(0.6))
                                                .overlay(Rectangle().frame(width: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .trailing)
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    appVM.selectedRowIndex = index
                                                    appVM.selectedCell = (row: index, col: 0)
                                                    isGridFocused = true
                                                }

                                            // Columns
                                            ForEach(Array(tableVM.columns.enumerated()), id: \.element.id) { colIdx, col in
                                                let colWidth = (tableVM.columnWidths[col.name] ?? 120) * appVM.zoomScale
                                                let cellVal = colIdx < row.count ? row[colIdx] : SQLiteValue.null
                                                let isCurMatchCell = (rowID != nil && rowID == tableVM.activeMatchRowID && colIdx == tableVM.activeMatchColumnIndex)
                                                let isCellSelected = isCurMatchCell || (appVM.selectedCell?.row == index && appVM.selectedCell?.col == colIdx)

                                                CellView(
                                                    value: cellVal,
                                                    isNumeric: col.isNumeric,
                                                    width: colWidth,
                                                    height: rowHeight,
                                                    zoomScale: appVM.zoomScale,
                                                    searchQuery: tableVM.searchQuery,
                                                    isSelected: isCellSelected,
                                                    isCurrentMatch: isCurMatchCell
                                                )
                                                .overlay(
                                                    Rectangle()
                                                        .frame(width: 1)
                                                        .foregroundColor(Color(NSColor.separatorColor).opacity(0.3)),
                                                    alignment: .trailing
                                                )
                                                .contentShape(Rectangle())
                                                .onTapGesture(count: 2) {
                                                    appVM.selectedRowIndex = index
                                                    appVM.selectedCell = (row: index, col: colIdx)
                                                    appVM.inspectingCell = CellInspectInfo(
                                                        tableName: tableVM.tableName,
                                                        colName: col.name,
                                                        colType: col.type,
                                                        value: cellVal,
                                                        rowOrdinal: rowOrdinal
                                                    )
                                                }
                                                .onTapGesture {
                                                    appVM.selectedRowIndex = index
                                                    appVM.selectedCell = (row: index, col: colIdx)
                                                    isGridFocused = true
                                                }
                                                .contextMenu {
                                                    cellContextMenu(rowIdx: index, colIdx: colIdx, col: col, val: cellVal, rowOrdinal: rowOrdinal)
                                                }
                                            }
                                        }
                                        .frame(height: rowHeight)
                                        .background(
                                            isRowMatched ? Color.accentColor.opacity(0.12) :
                                            (isRowSelected ? Color.accentColor.opacity(0.08) :
                                            (isEven ? Color(NSColor.controlBackgroundColor).opacity(0.15) : Color.clear))
                                        )
                                        .overlay(
                                            Rectangle()
                                                .frame(height: 1)
                                                .foregroundColor(Color(NSColor.separatorColor).opacity(0.2)),
                                            alignment: .bottom
                                        )
                                        .contextMenu {
                                            rowContextMenu(rowIdx: index)
                                        }
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
                            .padding(.top, 40)
                        }
                    }
                }
            }
        }
        .focusable()
        .focused($isGridFocused)
        .onKeyPress { press in
            handleKeyPress(press)
        }
        .onAppear {
            isGridFocused = true
        }
    }

    // MARK: - Top Pagination Bar
    private var topPaginationBar: some View {
        HStack(spacing: 10) {
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

            if let page = tableVM.currentPage {
                let startRow = page.start + 1
                let endRow = page.start + Int64(page.rows.count)
                let totalStr = tableVM.tableCount.displayString
                let approxMarker = page.approx ? "~" : ""
                Text("Rows \(startRow)–\(endRow) of \(totalStr)\(approxMarker)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }

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

            Button(action: { tableVM.loadLastPage() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Jump to end (End)")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Skeleton Loading View
    private var skeletonLoadingView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<15, id: \.self) { idx in
                    HStack(spacing: 0) {
                        // Gutter
                        Text("\(idx + 1)")
                            .font(.system(size: 11 * appVM.zoomScale, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.3))
                            .frame(width: gutterWidth, height: rowHeight)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                            .overlay(Rectangle().frame(width: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .trailing)

                        // Columns
                        ForEach(tableVM.columns) { col in
                            let width = (tableVM.columnWidths[col.name] ?? 120) * appVM.zoomScale
                            SkeletonCell(width: width, height: rowHeight)
                                .overlay(Rectangle().frame(width: 1).foregroundColor(Color(NSColor.separatorColor).opacity(0.2)), alignment: .trailing)
                        }
                    }
                    .frame(height: rowHeight)
                    .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor).opacity(0.2)), alignment: .bottom)
                }
            }
        }
    }

    // MARK: - Context Menus
    @ViewBuilder
    private func cellContextMenu(rowIdx: Int, colIdx: Int, col: Column, val: SQLiteValue, rowOrdinal: Int64) -> some View {
        Button(action: {
            tableVM.copyCellValue(rowIdx: rowIdx, colIdx: colIdx)
        }) {
            Label("Copy Cell Value", systemImage: "doc.on.doc")
        }

        Button(action: {
            appVM.inspectingCell = CellInspectInfo(
                tableName: tableVM.tableName,
                colName: col.name,
                colType: col.type,
                value: val,
                rowOrdinal: rowOrdinal
            )
        }) {
            Label("Inspect Cell Value…", systemImage: "info.circle")
        }

        Divider()

        Button(action: {
            tableVM.copyRowAsJSON(rowIdx: rowIdx)
        }) {
            Label("Copy Row as JSON", systemImage: "curlybraces")
        }

        Button(action: {
            tableVM.copyRowAsTSV(rowIdx: rowIdx)
        }) {
            Label("Copy Row as TSV", systemImage: "tablecells")
        }

        Button(action: {
            tableVM.copyRowAsCSV(rowIdx: rowIdx)
        }) {
            Label("Copy Row as CSV", systemImage: "list.bullet.rectangle")
        }

        Divider()

        Button(action: {
            appVM.exportCurrentTable()
        }) {
            Label("Export Table as CSV…", systemImage: "arrow.down.to.line")
        }
    }

    @ViewBuilder
    private func rowContextMenu(rowIdx: Int) -> some View {
        Button(action: {
            tableVM.copyRowAsJSON(rowIdx: rowIdx)
        }) {
            Label("Copy Row as JSON", systemImage: "curlybraces")
        }

        Button(action: {
            tableVM.copyRowAsTSV(rowIdx: rowIdx)
        }) {
            Label("Copy Row as TSV", systemImage: "tablecells")
        }

        Button(action: {
            tableVM.copyRowAsCSV(rowIdx: rowIdx)
        }) {
            Label("Copy Row as CSV", systemImage: "list.bullet.rectangle")
        }

        Divider()

        Button(action: {
            appVM.exportCurrentTable()
        }) {
            Label("Export Table as CSV…", systemImage: "arrow.down.to.line")
        }
    }

    // MARK: - Keyboard Handling
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard let page = tableVM.currentPage, !page.rows.isEmpty else {
            return .ignored
        }

        let maxRow = page.rows.count - 1
        let maxCol = max(0, tableVM.columns.count - 1)

        switch press.key {
        case .upArrow:
            let curRow = appVM.selectedCell?.row ?? 0
            let curCol = appVM.selectedCell?.col ?? 0
            let nextRow = max(0, curRow - 1)
            appVM.selectedCell = (row: nextRow, col: curCol)
            appVM.selectedRowIndex = nextRow
            return .handled

        case .downArrow:
            let curRow = appVM.selectedCell?.row ?? 0
            let curCol = appVM.selectedCell?.col ?? 0
            let nextRow = min(maxRow, curRow + 1)
            appVM.selectedCell = (row: nextRow, col: curCol)
            appVM.selectedRowIndex = nextRow
            return .handled

        case .leftArrow:
            let curRow = appVM.selectedCell?.row ?? 0
            let curCol = appVM.selectedCell?.col ?? 0
            let nextCol = max(0, curCol - 1)
            appVM.selectedCell = (row: curRow, col: nextCol)
            return .handled

        case .rightArrow:
            let curRow = appVM.selectedCell?.row ?? 0
            let curCol = appVM.selectedCell?.col ?? 0
            let nextCol = min(maxCol, curCol + 1)
            appVM.selectedCell = (row: curRow, col: nextCol)
            return .handled

        case .pageUp:
            tableVM.previousPage()
            return .handled

        case .pageDown:
            tableVM.nextPage()
            return .handled

        case .home:
            tableVM.loadPage(offset: 0)
            appVM.selectedCell = (row: 0, col: appVM.selectedCell?.col ?? 0)
            appVM.selectedRowIndex = 0
            return .handled

        case .end:
            tableVM.loadLastPage()
            return .handled

        case .space, .return:
            if let sel = appVM.selectedCell, sel.row < page.rows.count, sel.col < tableVM.columns.count {
                let col = tableVM.columns[sel.col]
                let val = sel.col < page.rows[sel.row].count ? page.rows[sel.row][sel.col] : SQLiteValue.null
                let rowOrdinal = page.start + Int64(sel.row) + 1
                appVM.inspectingCell = CellInspectInfo(
                    tableName: tableVM.tableName,
                    colName: col.name,
                    colType: col.type,
                    value: val,
                    rowOrdinal: rowOrdinal
                )
            }
            return .handled

        case .escape:
            if appVM.inspectingCell != nil {
                appVM.inspectingCell = nil
                return .handled
            }
            if appVM.isFindBarVisible {
                appVM.isFindBarVisible = false
                tableVM.cancelFind()
                return .handled
            }
            return .ignored

        default:
            return .ignored
        }
    }
}

// MARK: - Skeleton Cell
public struct SkeletonCell: View {
    let width: CGFloat
    let height: CGFloat
    @State private var shimmer: Bool = false

    public var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    Color(NSColor.controlBackgroundColor)
                        .opacity(shimmer ? 0.8 : 0.3)
                )
                .frame(width: max(20, width * 0.65), height: 8)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }
}

// MARK: - Cell View
public struct CellView: View {
    let value: SQLiteValue
    let isNumeric: Bool
    let width: CGFloat
    let height: CGFloat
    let zoomScale: Double
    let searchQuery: String
    let isSelected: Bool
    let isCurrentMatch: Bool

    public init(
        value: SQLiteValue,
        isNumeric: Bool,
        width: CGFloat,
        height: CGFloat,
        zoomScale: Double,
        searchQuery: String = "",
        isSelected: Bool = false,
        isCurrentMatch: Bool = false
    ) {
        self.value = value
        self.isNumeric = isNumeric
        self.width = width
        self.height = height
        self.zoomScale = zoomScale
        self.searchQuery = searchQuery
        self.isSelected = isSelected
        self.isCurrentMatch = isCurrentMatch
    }

    public var body: some View {
        HStack(spacing: 0) {
            switch value {
            case .null:
                if !searchQuery.isEmpty && "NULL".localizedCaseInsensitiveContains(searchQuery) {
                    Text(highlightedText(content: "NULL", query: searchQuery, isCurrentMatch: isCurrentMatch))
                        .font(.system(size: 11 * zoomScale, weight: .regular, design: .monospaced).italic())
                } else {
                    Text("NULL")
                        .font(.system(size: 11 * zoomScale, weight: .regular, design: .monospaced).italic())
                        .foregroundColor(Color.secondary.opacity(0.5))
                }

            case .blob:
                let s = value.displayText
                if !searchQuery.isEmpty && s.localizedCaseInsensitiveContains(searchQuery) {
                    Text(highlightedText(content: s, query: searchQuery, isCurrentMatch: isCurrentMatch))
                        .font(.system(size: 10 * zoomScale, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(3)
                } else {
                    Text(s)
                        .font(.system(size: 10 * zoomScale, weight: .semibold, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(3)
                }

            case .integer, .real:
                let s = value.displayText
                if !searchQuery.isEmpty && s.localizedCaseInsensitiveContains(searchQuery) {
                    Text(highlightedText(content: s, query: searchQuery, isCurrentMatch: isCurrentMatch))
                        .font(.system(size: 12 * zoomScale, weight: .regular, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(s)
                        .font(.system(size: 12 * zoomScale, weight: .regular, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

            case .text(let s):
                if !searchQuery.isEmpty && s.localizedCaseInsensitiveContains(searchQuery) {
                    Text(highlightedText(content: s, query: searchQuery, isCurrentMatch: isCurrentMatch))
                        .font(.system(size: 12 * zoomScale, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                } else {
                    Text(s)
                        .font(.system(size: 12 * zoomScale, weight: .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height, alignment: isNumeric ? .trailing : .leading)
        .background(
            isCurrentMatch ? Color.accentColor.opacity(0.25) :
            (isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            isCurrentMatch ? RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 2) :
            (isSelected ? RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5) : nil)
        )
    }

    private func highlightedText(content: String, query: String, isCurrentMatch: Bool) -> AttributedString {
        guard !query.isEmpty else {
            return AttributedString(content)
        }

        var attributed = AttributedString(content)
        var searchRange = content.startIndex..<content.endIndex

        while let range = content.range(of: query, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(range, in: attributed) {
                // Highlighting matching sqldoc: #ffd54f golden background with dark text #202124
                let bg = isCurrentMatch
                    ? Color(red: 1.0, green: 0.72, blue: 0.15) // #ffb726 active focus highlight
                    : Color(red: 1.0, green: 0.835, blue: 0.31) // #ffd54f standard match
                attributed[attrRange].backgroundColor = bg
                attributed[attrRange].foregroundColor = Color(red: 0.125, green: 0.13, blue: 0.14) // #202124
                if isCurrentMatch {
                    attributed[attrRange].inlinePresentationIntent = .stronglyEmphasized
                }
            }
            searchRange = range.upperBound..<content.endIndex
        }

        return attributed
    }
}
