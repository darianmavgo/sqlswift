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
    @Published public var sortNumeric: Bool = false
    @Published public var lastTimingMicros: Int64 = 0
    @Published public var lastQueryPath: String = "keyset"
    @Published public var isLoading: Bool = false
    @Published public var isSorting: Bool = false

    // Virtualized window state
    @Published public var currentPage: Page?
    @Published public var currentOffset: Int64 = 0

    // Search / Find state matching sqldoc
    @Published public var searchQuery: String = ""
    /// nil = search every column.
    @Published public var searchColumn: String? = nil
    @Published public var searchCaseSensitive: Bool = false
    @Published public var matches: [FindMatch] = []
    @Published public var activeMatchIndex: Int = -1
    @Published public var activeMatchRowID: Int64? = nil
    @Published public var activeMatchColumnIndex: Int? = nil
    @Published public var searchProgress: Double = 0.0
    @Published public var isSearching: Bool = false
    @Published public var searchScanned: Int64 = 0
    @Published public var matchCapReached: Bool = false
    // Per-cell "contains the query" mask for the current page, rebuilt only when
    // the page or query changes — never per render/scroll frame.
    @Published public var highlightMask: [[Bool]] = []

    // Filter bar
    @Published public var filters: [ColumnFilter] = []
    @Published public var filteredCount: Int64? = nil

    // Power-2 spot-check
    @Published public var powerSampleMode: Bool = false

    // Display
    @Published public var hiddenColumns: Set<String> = []
    @Published public var rowHeightScale: Double = 1.0   // 1 = compact, 2 = regular, 3 = tall
    @Published public var wrapCells: Bool = false
    @Published public var smartFormat: Bool = true

    // Background-job label for the status bar ("counting…", "sampling…")
    @Published public var backgroundJob: String? = nil

    /// Columns actually shown in the grid (order preserved, hidden removed).
    public var visibleColumns: [Column] { columns.filter { !hiddenColumns.contains($0.name) } }

    private var findTask: Task<Void, Never>?
    private var filterCountTask: Task<Void, Never>?

    // Every load bumps this; a stale detached result whose generation no longer
    // matches is dropped instead of clobbering a newer page.
    private var loadGeneration: UInt64 = 0
    // Column widths are measured once from real data and then left alone (paging
    // must not reflow the grid). Reset explicitly re-measures.
    private var didMeasureFromData = false

    private static let matchCap = BehaviorConfig.findMatchCap
    private static let findDebounceNanos = UInt64(BehaviorConfig.findDebounceMs) * 1_000_000

    public init(doc: Doc, tableName: String, docID: String = "") {
        self.doc = doc
        self.docID = docID.isEmpty ? SessionManager.computeID(for: doc.path) : docID
        self.tableName = tableName
        loadInitialData()
    }

    deinit {
        findTask?.cancel()
        filterCountTask?.cancel()
        // Detach this table's background observers.
        doc.counterWorker.setObserver(for: tableName, nil)
        doc.columnSampler.setObserver(for: tableName, nil)
    }

    /// Called when this VM is evicted from the cache.
    public func dispose() {
        findTask?.cancel(); findTask = nil
        filterCountTask?.cancel(); filterCountTask = nil
        doc.counterWorker.setObserver(for: tableName, nil)
        doc.columnSampler.setObserver(for: tableName, nil)
    }

    public func loadInitialData() {
        self.isLoading = true

        // Cheap, synchronous facts only — a single PRAGMA and an O(1) estimate.
        do {
            self.columns = try doc.columns(for: tableName)
        } catch {
            self.columns = []
        }
        self.tableCount = doc.count(for: tableName)

        // Seed provisional widths from the header text so the skeleton and first
        // frame have a stable layout; real measurement happens once data lands.
        let savedWidths = StatePersistenceManager.shared.loadColumnWidths(dbID: docID, table: tableName) ?? [:]
        self.userSizedColumns = Set(savedWidths.keys)
        for col in columns {
            if let userWidth = savedWidths[col.name] {
                columnWidths[col.name] = userWidth
            } else {
                columnWidths[col.name] = ColumnWidthCalculator.optimalWidth(column: col, sampleTexts: [])
            }
        }

        doc.counterWorker.setObserver(for: tableName) { [weak self] count in
            Task { @MainActor in self?.tableCount = count }
        }
        doc.columnSampler.setObserver(for: tableName) { [weak self] hint in
            Task { @MainActor in self?.applyColumnHints(hint) }
        }
        _ = doc.columnHints(for: tableName)

        // Restore persisted per-table preferences.
        self.hiddenColumns = StatePersistenceManager.shared.loadHiddenColumns(dbID: docID, table: tableName)
            .intersection(Set(columns.map { $0.name }))
        if let s = StatePersistenceManager.shared.loadSort(dbID: docID, table: tableName),
           columns.contains(where: { $0.name == s.column }) {
            self.sortColumn = s.column
            self.isSortDesc = s.desc
            self.sortNumeric = s.numeric
        }

        // The actual first query runs off the main thread.
        loadPage(offset: 0)
    }

    // MARK: - Windowed loading (never blocks the main thread)

    /// Rows per page — honours a document's `_head` `page_size`, else 100.
    public var pageLimit: Int { doc.style.pageSize ?? 100 }

    public func loadPage(offset: Int64, limit: Int? = nil) {
        let limit = limit ?? pageLimit
        let clampedOffset = max(0, offset)
        self.currentOffset = clampedOffset
        let window = SQLDocCore.Window(
            table: tableName,
            limit: limit,
            offset: clampedOffset,
            sort: sortColumn,
            desc: isSortDesc,
            sortNumeric: sortNumeric,
            filters: filters,
            powerSample: powerSampleMode
        )
        runLoad(window)
    }

    public func nextPage() {
        guard let page = currentPage, !page.rows.isEmpty else { return }
        let limit = page.rows.count

        if powerSampleMode { return }
        if !filters.isEmpty {
            loadPage(offset: currentOffset + Int64(limit))
            return
        }

        if sortColumn == nil, let lastRowID = page.rowIDs.last {
            // Unsorted sequential scroll: exact O(log n) keyset seek.
            let window = SQLDocCore.Window(
                table: tableName,
                limit: limit,
                after: lastRowID,
                useAfter: true,
                offset: currentOffset + Int64(limit)
            )
            runLoad(window)
        } else if let sortCol = sortColumn,
                  let lastRowID = page.rowIDs.last,
                  let anchorValue = lastSortValue(on: page), !anchorValue.isNull {
            // Sorted scroll: keyset on (sortValue, rowid) — no deep OFFSET counting.
            let window = SQLDocCore.Window(
                table: tableName,
                limit: limit,
                after: lastRowID,
                useAfter: true,
                offset: currentOffset + Int64(limit),
                sort: sortCol,
                desc: isSortDesc,
                sortNumeric: sortNumeric,
                afterSortValue: anchorValue
            )
            runLoad(window)
        } else {
            loadPage(offset: currentOffset + Int64(limit))
        }
    }

    public func previousPage() {
        loadPage(offset: max(0, currentOffset - Int64(pageLimit)))
    }

    public func loadLastPage() {
        if powerSampleMode { return }
        let total = !filters.isEmpty ? filteredCount : (tableCount.known ? tableCount.rows : nil)
        if let total, total > 0 {
            loadPage(offset: max(0, total - Int64(pageLimit)))
        } else {
            nextPage()
        }
    }

    // MARK: - Filters

    public func setFilter(column: String, op: ColumnFilter.Op, value: String) {
        filters.removeAll { $0.column == column }
        if op.needsValue && value.isEmpty {
            applyFiltersChanged()
            return
        }
        filters.append(ColumnFilter(column: column, op: op, value: value))
        applyFiltersChanged()
    }

    public func clearFilters() {
        guard !filters.isEmpty else { return }
        filters = []
        filteredCount = nil
        loadPage(offset: 0)
    }

    private func applyFiltersChanged() {
        loadPage(offset: 0)
        filterCountTask?.cancel()
        guard !filters.isEmpty else { filteredCount = nil; return }
        let docRef = doc
        let table = tableName
        let fs = filters
        backgroundJob = "counting…"
        filterCountTask = Task.detached(priority: .utility) { [weak self] in
            let n = docRef.filteredCount(table: table, filters: fs)
            await MainActor.run {
                guard let self, self.filters == fs else { return }
                self.filteredCount = n
                self.backgroundJob = nil
            }
        }
    }

    // MARK: - Power-2 spot-check

    public func togglePowerSample() {
        powerSampleMode.toggle()
        loadPage(offset: 0)
    }

    // MARK: - Jump to row

    /// Scroll so the row at 1-based ordinal `n` is on the current page and select it.
    @Published public var selectRowRequest: Int? = nil
    public func jumpToOrdinal(_ n: Int64) {
        let target = max(0, n - 1)
        let lim = Int64(pageLimit)
        let pageOffset = (target / lim) * lim
        let indexOnPage = Int(target % lim)
        if currentOffset == pageOffset, let page = currentPage, indexOnPage < page.rows.count {
            selectRowRequest = indexOnPage           // already here
        } else {
            pendingSelectRow = indexOnPage
            loadPage(offset: pageOffset)
        }
    }

    private var pendingSelectRow: Int?
    public func consumePendingSelection() -> Int? {
        defer { pendingSelectRow = nil }
        return pendingSelectRow
    }

    // MARK: - Columns show/hide

    public func setColumn(_ name: String, hidden: Bool) {
        if hidden { hiddenColumns.insert(name) } else { hiddenColumns.remove(name) }
        StatePersistenceManager.shared.saveHiddenColumns(dbID: docID, table: tableName, hidden: hiddenColumns)
    }

    public func showAllColumns() {
        hiddenColumns.removeAll()
        StatePersistenceManager.shared.saveHiddenColumns(dbID: docID, table: tableName, hidden: [])
    }

    /// The sort-column value of the last row on a page, for keyset anchoring.
    private func lastSortValue(on page: Page) -> SQLiteValue? {
        guard let sortCol = sortColumn,
              let colIdx = columns.firstIndex(where: { $0.name == sortCol }),
              let lastRow = page.rows.last,
              colIdx < lastRow.count else { return nil }
        return lastRow[colIdx]
    }

    private func runLoad(_ window: SQLDocCore.Window) {
        loadGeneration &+= 1
        let generation = loadGeneration
        self.isLoading = true
        let docRef = doc

        Task.detached(priority: .userInitiated) {
            let result: Page? = try? docRef.rows(window: window)
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.isLoading = false
                self.isSorting = false
                guard let page = result else { return }
                self.currentPage = page
                self.currentOffset = page.start
                self.lastTimingMicros = page.micros
                self.lastQueryPath = page.path
                self.measureColumnsFromPage(page)
                self.rebuildHighlightMask()
            }
        }
    }

    // MARK: - Sorting

    public func sortBy(column: String) {
        if sortColumn == column {
            if isSortDesc {
                sortColumn = nil
                isSortDesc = false
                sortNumeric = false
            } else {
                isSortDesc = true
            }
        } else {
            sortColumn = column
            isSortDesc = false
            // Default to numeric ordering for numeric-typed columns.
            sortNumeric = columns.first(where: { $0.name == column })?.isNumeric ?? false
        }
        isSorting = true
        persistSort()
        loadPage(offset: 0)
    }

    public func setSort(column: String?, desc: Bool, numeric: Bool? = nil) {
        sortColumn = column
        isSortDesc = desc
        if let column {
            sortNumeric = numeric ?? (columns.first(where: { $0.name == column })?.isNumeric ?? false)
        } else {
            sortNumeric = false
        }
        isSorting = true
        persistSort()
        loadPage(offset: 0)
    }

    public func toggleSortNumeric() {
        guard sortColumn != nil else { return }
        sortNumeric.toggle()
        isSorting = true
        persistSort()
        loadPage(offset: 0)
    }

    private func persistSort() {
        StatePersistenceManager.shared.saveSort(
            dbID: docID, table: tableName,
            column: sortColumn, desc: isSortDesc, numeric: sortNumeric)
    }

    // MARK: - Banquet Integration

    /// Applies query parameters, sort, and slice offset from a parsed Banquet object.
    public func applyBanquet(_ banquet: Banquet) {
        if let sortCol = banquet.sortColumn, !sortCol.isEmpty {
            setSort(column: sortCol, desc: banquet.isSortDesc)
        }

        if let offset = banquet.offset {
            loadPage(offset: Int64(offset))
        } else {
            loadPage(offset: 0)
        }
    }

    // MARK: - Column widths

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
            for row in page.text where colIdx < row.count {
                samples.append(row[colIdx].text)
            }
        }
        let fitted = ColumnWidthCalculator.optimalWidth(column: col, sampleTexts: samples, maxWidth: 600)
        columnWidths[column] = fitted
        userSizedColumns.insert(column)
        saveUserWidths()
    }

    public func resetColumnWidths() {
        userSizedColumns.removeAll()
        didMeasureFromData = false
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
            if let w = columnWidths[colName] { userDict[colName] = w }
        }
        StatePersistenceManager.shared.saveColumnWidths(dbID: docID, table: tableName, widths: userDict)
    }

    /// Measure widths from the data exactly once. Paging and sorting afterwards
    /// keep the columns where they are — the grid must not reflow under the user.
    private func measureColumnsFromPage(_ page: Page) {
        guard !didMeasureFromData else { return }
        didMeasureFromData = true
        for (colIdx, col) in columns.enumerated() {
            if userSizedColumns.contains(col.name) { continue }
            var samples: [String] = []
            for row in page.text where colIdx < row.count {
                samples.append(row[colIdx].text)
            }
            columnWidths[col.name] = ColumnWidthCalculator.optimalWidth(column: col, sampleTexts: samples)
        }
    }

    private func applyColumnHints(_ hint: ColumnHint) {
        // The background sample sees more of the table than the first page — let
        // it refine widths once, then leave them alone.
        for (i, col) in columns.enumerated() {
            if userSizedColumns.contains(col.name) { continue }
            if i < hint.samples.count {
                let current = columnWidths[col.name] ?? DesignToken.colDefaultWidth
                let hinted = ColumnWidthCalculator.optimalWidth(column: col, sampleTexts: [hint.samples[i]])
                // Only widen — never yank a column narrower after the user has seen it.
                columnWidths[col.name] = max(current, hinted)
            }
        }
        didMeasureFromData = true
    }

    // MARK: - Clipboard & Export Helpers

    public func copyCellValue(rowIdx: Int, colIdx: Int) {
        guard let page = currentPage, rowIdx >= 0, rowIdx < page.rows.count else { return }
        let row = page.rows[rowIdx]
        guard colIdx >= 0, colIdx < row.count else { return }
        let val = row[colIdx]
        let textToCopy: String
        switch val {
        case .null: textToCopy = "NULL"
        case .integer(let i): textToCopy = "\(i)"
        case .real(let r): textToCopy = "\(r)"
        case .text(let s): textToCopy = s
        case .blob(let bytes): textToCopy = "<BLOB: \(bytes) bytes>"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textToCopy, forType: .string)
    }

    public func copyRowAsJSON(rowIdx: Int) {
        guard let page = currentPage, rowIdx >= 0, rowIdx < page.rows.count else { return }
        let row = page.rows[rowIdx]
        var dict: [String: Any] = [:]
        for (idx, col) in columns.enumerated() where idx < row.count {
            switch row[idx] {
            case .null: dict[col.name] = NSNull()
            case .integer(let i): dict[col.name] = i
            case .real(let r): dict[col.name] = r
            case .text(let s): dict[col.name] = s
            case .blob(let b): dict[col.name] = "<BLOB \(b) bytes>"
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
        let tsv = page.rows[rowIdx].map { $0.displayText }.joined(separator: "\t")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .string)
    }

    public func copyRowAsCSV(rowIdx: Int) {
        guard let page = currentPage, rowIdx >= 0, rowIdx < page.rows.count else { return }
        let csv = page.rows[rowIdx].map { $0.csvText }.joined(separator: ",")
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
        self.searchScanned = 0
        self.matchCapReached = false

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.isSearching = false
            self.highlightMask = []
            return
        }

        self.isSearching = true
        rebuildHighlightMask()
        let docRef = doc
        let table = tableName
        let cap = Self.matchCap
        let scope = searchColumn
        let caseSensitive = searchCaseSensitive

        findTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Debounce: absorb a burst of keystrokes before touching the database.
            try? await Task.sleep(nanoseconds: Self.findDebounceNanos)
            if Task.isCancelled { return }

            var cursor: Int64 = 0
            var done = false

            while !done && !Task.isCancelled {
                guard let res = try? docRef.find(table: table, query: trimmed, from: cursor, limit: 50, column: scope, caseSensitive: caseSensitive) else { break }
                cursor = res.next
                done = res.done

                let hitCap: Bool = await MainActor.run {
                    guard let self else { return true }
                    let remaining = max(0, cap - self.matches.count)
                    if remaining > 0 {
                        self.matches.append(contentsOf: res.matches.prefix(remaining))
                    }
                    self.searchScanned = res.next
                    self.searchProgress = res.progress
                    if self.matches.count >= cap { self.matchCapReached = true }
                    if self.activeMatchIndex == -1 && !self.matches.isEmpty {
                        self.jumpToMatch(index: 0)
                    }
                    return self.matches.count >= cap
                }

                if hitCap { break }
                if !done {
                    try? await Task.sleep(nanoseconds: UInt64(BehaviorConfig.findTickSleepMs) * 1_000_000)
                }
            }

            await MainActor.run {
                self?.isSearching = false
                self?.searchProgress = 1.0
            }
        }
    }

    public func nextMatch() {
        guard !matches.isEmpty else { return }
        jumpToMatch(index: (activeMatchIndex + 1) % matches.count)
    }

    public func previousMatch() {
        guard !matches.isEmpty else { return }
        jumpToMatch(index: (activeMatchIndex - 1 + matches.count) % matches.count)
    }

    public func cancelFind() {
        findTask?.cancel()
        self.isSearching = false
        self.searchQuery = ""
        self.matches = []
        self.activeMatchIndex = -1
        self.activeMatchRowID = nil
        self.activeMatchColumnIndex = nil
        self.matchCapReached = false
        self.searchScanned = 0
        self.highlightMask = []
    }

    /// Recompute which visible cells contain the query. Cheap (one pass over the
    /// 100-row page) and done only on page/query change, so the grid body never
    /// runs a substring scan while scrolling.
    func rebuildHighlightMask() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let page = currentPage else {
            if !highlightMask.isEmpty { highlightMask = [] }
            return
        }
        let opts: String.CompareOptions = searchCaseSensitive ? [] : .caseInsensitive
        let scopeIdx = searchColumn.flatMap { name in columns.firstIndex(where: { $0.name == name }) }
        highlightMask = page.text.map { row in
            row.enumerated().map { colIdx, cell in
                if let scopeIdx, scopeIdx != colIdx { return false }
                return cell.text.range(of: q, options: opts) != nil
            }
        }
    }

    public func cellMatches(row: Int, col: Int) -> Bool {
        guard row < highlightMask.count, col < highlightMask[row].count else { return false }
        return highlightMask[row][col]
    }

    public func jumpToMatch(index: Int) {
        guard index >= 0 && index < matches.count else { return }
        self.activeMatchIndex = index
        let match = matches[index]
        self.activeMatchRowID = match.rowID
        self.activeMatchColumnIndex = match.column

        // Resolving the ordinal can touch the database; keep it off the main thread.
        let docRef = doc
        let table = tableName
        let rowID = match.rowID
        let currentOff = currentOffset
        Task.detached(priority: .userInitiated) { [weak self] in
            let targetOrdinal = docRef.ordinal(for: table, rowID: rowID)
            let pageOffset = max(0, (targetOrdinal / 100) * 100)
            guard currentOff != pageOffset else { return }
            await MainActor.run { self?.loadPage(offset: pageOffset) }
        }
    }
}
