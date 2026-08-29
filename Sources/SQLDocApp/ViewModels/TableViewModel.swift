import SwiftUI
import AppKit
import SQLDocCore

@MainActor
public final class TableViewModel: ObservableObject {
    public let doc: Doc
    public let docID: String
    public let tableName: String

    @Published public var columns: [Column] = []
    @Published public var tableCount: TableCount = .unknown
    @Published public var columnWidths: [String: CGFloat] = [:]
    @Published public var userSizedColumns: Set<String> = []
    @Published public var sortColumn: String? = nil
    @Published public var isSortDesc: Bool = false
    @Published public var lastTimingMicros: Int64 = 0
    @Published public var lastQueryPath: String = "keyset"
    @Published public var isLoading: Bool = false

    // Virtualized window state
    @Published public var currentPage: Page?
    @Published public var currentOffset: Int64 = 0

    // Search / Find state matching sqldoc
    @Published public var searchQuery: String = ""
    @Published public var matches: [FindMatch] = []
    @Published public var activeMatchIndex: Int = -1
    @Published public var activeMatchRowID: Int64? = nil
    @Published public var activeMatchColumnIndex: Int? = nil
    @Published public var searchProgress: Double = 0.0
    @Published public var isSearching: Bool = false

    private var findTask: Task<Void, Never>?

    public init(doc: Doc, tableName: String, docID: String = "") {
        self.doc = doc
        self.docID = docID.isEmpty ? SessionManager.computeID(for: doc.path) : docID
        self.tableName = tableName
        loadInitialData()
    }

    deinit {
        findTask?.cancel()
    }

    public func loadInitialData() {
        self.isLoading = true
        do {
            self.columns = try doc.columns(for: tableName)
        } catch {
            self.columns = []
        }

        self.tableCount = doc.count(for: tableName)

        // Try restoring explicitly saved user column widths
        let savedWidths = StatePersistenceManager.shared.loadColumnWidths(dbID: docID, table: tableName) ?? [:]
        self.userSizedColumns = Set(savedWidths.keys)

        for col in columns {
            if let userWidth = savedWidths[col.name] {
                columnWidths[col.name] = userWidth
            } else {
                columnWidths[col.name] = ColumnWidthCalculator.optimalWidth(
                    column: col,
                    sampleTexts: []
                )
            }
        }

        // Register counter listener
        doc.counterWorker.onCountUpdated = { [weak self] updatedTable, count in
            guard let self, updatedTable == self.tableName else { return }
            Task { @MainActor in
                self.tableCount = count
            }
        }

        // Register column hints listener
        doc.columnSampler.onHintUpdated = { [weak self] updatedTable, hint in
            guard let self, updatedTable == self.tableName else { return }
            Task { @MainActor in
                self.applyColumnHints(hint)
            }
        }

        // Start background hint sampling
        _ = doc.columnHints(for: tableName)

        // Load first page
        loadPage(offset: 0)
    }

    public func loadPage(offset: Int64, limit: Int = 100) {
        self.isLoading = true
        self.currentOffset = max(0, offset)
        let window = Window(
            table: tableName,
            limit: limit,
            offset: currentOffset,
            sort: sortColumn,
            desc: isSortDesc
        )
        do {
            let page = try doc.rows(window: window)
            self.currentPage = page
            self.lastTimingMicros = page.micros
            self.lastQueryPath = page.path
            measureColumnsFromPage(page)
        } catch {
            // handle error
        }
        self.isLoading = false
    }

    public func nextPage() {
        guard let page = currentPage, !page.rows.isEmpty else { return }
        let limit = page.rows.count
        if let lastRowID = page.rowIDs.last, sortColumn == nil {
            let window = Window(
                table: tableName,
                limit: limit,
                after: lastRowID,
                useAfter: true,
                offset: currentOffset + Int64(limit)
            )
            if let next = try? doc.rows(window: window) {
                self.currentPage = next
                self.currentOffset += Int64(limit)
                self.lastTimingMicros = next.micros
                self.lastQueryPath = next.path
                measureColumnsFromPage(next)
            }
        } else {
            loadPage(offset: currentOffset + Int64(limit))
        }
    }

    public func previousPage() {
        let step: Int64 = 100
        let newOffset = max(0, currentOffset - step)
        loadPage(offset: newOffset)
    }

    public func loadLastPage() {
        if tableCount.known && tableCount.rows > 0 {
            let limit: Int64 = 100
            let lastOffset = max(0, tableCount.rows - limit)
            loadPage(offset: lastOffset)
        } else {
            nextPage()
        }
    }

    public func sortBy(column: String) {
        if sortColumn == column {
            if isSortDesc {
                sortColumn = nil
                isSortDesc = false
            } else {
                isSortDesc = true
            }
        } else {
            sortColumn = column
            isSortDesc = false
        }
        loadPage(offset: 0)
    }

    public func updateWidth(column: String, width: CGFloat) {
        let clamped = max(48, min(800, width))
        columnWidths[column] = clamped
        userSizedColumns.insert(column)
        saveUserWidths()
    }

    public func autoFitWidth(column: String) {
        guard let colIdx = columns.firstIndex(where: { $0.name == column }) else { return }
        let col = columns[colIdx]
        var samples: [String] = []

        if let page = currentPage {
            for row in page.rows {
                if colIdx < row.count {
                    samples.append(row[colIdx].displayText)
                }
            }
        }

        let fitted = ColumnWidthCalculator.optimalWidth(
            column: col,
            sampleTexts: samples,
            maxWidth: 600
        )
        columnWidths[column] = fitted
        userSizedColumns.insert(column)
        saveUserWidths()
    }

    public func resetColumnWidths() {
        userSizedColumns.removeAll()
        StatePersistenceManager.shared.clearColumnWidths(dbID: docID, table: tableName)
        if let page = currentPage {
            measureColumnsFromPage(page)
        } else {
            for col in columns {
                columnWidths[col.name] = ColumnWidthCalculator.optimalWidth(column: col, sampleTexts: [])
            }
        }
    }

    private func saveUserWidths() {
        var userDict: [String: CGFloat] = [:]
        for colName in userSizedColumns {
            if let w = columnWidths[colName] {
                userDict[colName] = w
            }
        }
        StatePersistenceManager.shared.saveColumnWidths(dbID: docID, table: tableName, widths: userDict)
    }

    private func measureColumnsFromPage(_ page: Page) {
        for (colIdx, col) in columns.enumerated() {
            // Do not override columns the user explicitly sized
            if userSizedColumns.contains(col.name) {
                continue
            }

            var samples: [String] = []
            for row in page.rows {
                if colIdx < row.count {
                    samples.append(row[colIdx].displayText)
                }
            }

            let calculated = ColumnWidthCalculator.optimalWidth(
                column: col,
                sampleTexts: samples
            )
            columnWidths[col.name] = calculated
        }
    }

    private func applyColumnHints(_ hint: ColumnHint) {
        for (i, col) in columns.enumerated() {
            if userSizedColumns.contains(col.name) {
                continue
            }
            if i < hint.samples.count {
                let sample = hint.samples[i]
                let calculated = ColumnWidthCalculator.optimalWidth(
                    column: col,
                    sampleTexts: [sample]
                )
                columnWidths[col.name] = calculated
            }
        }
    }

    // MARK: - Clipboard & Export Helpers

    public func copyCellValue(rowIdx: Int, colIdx: Int) {
        guard let page = currentPage, rowIdx >= 0, rowIdx < page.rows.count else { return }
        let row = page.rows[rowIdx]
        guard colIdx >= 0, colIdx < row.count else { return }
        let val = row[colIdx]
        let textToCopy: String
        switch val {
        case .null:
            textToCopy = "NULL"
        case .integer(let i):
            textToCopy = "\(i)"
        case .real(let r):
            textToCopy = "\(r)"
        case .text(let s):
            textToCopy = s
        case .blob(let bytes):
            textToCopy = "<BLOB: \(bytes) bytes>"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textToCopy, forType: .string)
    }

    public func copyRowAsJSON(rowIdx: Int) {
        guard let page = currentPage, rowIdx >= 0, rowIdx < page.rows.count else { return }
        let row = page.rows[rowIdx]
        var dict: [String: Any] = [:]
        for (idx, col) in columns.enumerated() {
            if idx < row.count {
                switch row[idx] {
                case .null:
                    dict[col.name] = NSNull()
                case .integer(let i):
                    dict[col.name] = i
                case .real(let r):
                    dict[col.name] = r
                case .text(let s):
                    dict[col.name] = s
                case .blob(let b):
                    dict[col.name] = "<BLOB \(b) bytes>"
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        }
    }

    public func copyRowAsTSV(rowIdx: Int) {
        guard let page = currentPage, rowIdx >= 0, rowIdx < page.rows.count else { return }
        let row = page.rows[rowIdx]
        let values = row.map { $0.displayText }
        let tsv = values.joined(separator: "\t")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .string)
    }

    public func copyRowAsCSV(rowIdx: Int) {
        guard let page = currentPage, rowIdx >= 0, rowIdx < page.rows.count else { return }
        let row = page.rows[rowIdx]
        let escaped = row.map { val -> String in
            switch val {
            case .null: return ""
            case .integer(let i): return "\(i)"
            case .real(let r): return "\(r)"
            case .text(let s):
                if s.contains(",") || s.contains("\"") || s.contains("\n") {
                    return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return s
            case .blob(let b): return "<BLOB \(b) bytes>"
            }
        }
        let csv = escaped.joined(separator: ",")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(csv, forType: .string)
    }

    // MARK: - Streaming Search / Find

    public func startFind(query: String) {
        findTask?.cancel()
        self.searchQuery = query
        self.matches = []
        self.activeMatchIndex = -1
        self.activeMatchRowID = nil
        self.activeMatchColumnIndex = nil
        self.searchProgress = 0.0

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.isSearching = false
            return
        }

        self.isSearching = true

        findTask = Task.detached { [weak self] in
            guard let self else { return }
            var cursor: Int64 = 0
            var done = false

            while !done && !Task.isCancelled {
                guard let res = try? self.doc.find(table: self.tableName, query: trimmed, from: cursor, limit: 50) else {
                    break
                }
                cursor = res.next
                done = res.done

                await MainActor.run {
                    self.matches.append(contentsOf: res.matches)
                    self.searchProgress = res.progress
                    if self.activeMatchIndex == -1 && !self.matches.isEmpty {
                        self.jumpToMatch(index: 0)
                    }
                }

                if !done {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }

            await MainActor.run {
                self.isSearching = false
                self.searchProgress = 1.0
            }
        }
    }

    public func nextMatch() {
        guard !matches.isEmpty else { return }
        let nextIdx = (activeMatchIndex + 1) % matches.count
        jumpToMatch(index: nextIdx)
    }

    public func previousMatch() {
        guard !matches.isEmpty else { return }
        let prevIdx = (activeMatchIndex - 1 + matches.count) % matches.count
        jumpToMatch(index: prevIdx)
    }

    public func cancelFind() {
        findTask?.cancel()
        self.isSearching = false
        self.searchQuery = ""
        self.matches = []
        self.activeMatchIndex = -1
        self.activeMatchRowID = nil
        self.activeMatchColumnIndex = nil
    }

    public func jumpToMatch(index: Int) {
        guard index >= 0 && index < matches.count else { return }
        self.activeMatchIndex = index
        let match = matches[index]
        self.activeMatchRowID = match.rowID
        self.activeMatchColumnIndex = match.column

        let targetOrdinal = doc.ordinal(for: tableName, rowID: match.rowID)
        let pageOffset = max(0, (targetOrdinal / 100) * 100)

        if currentOffset != pageOffset {
            loadPage(offset: pageOffset)
        }
    }
}
