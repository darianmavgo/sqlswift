import SwiftUI
import AppKit
import SQLDocCore

@MainActor
public final class TableViewModel: ObservableObject {
    public let doc: Doc
    public let tableName: String

    @Published public var columns: [Column] = []
    @Published public var tableCount: TableCount = .unknown
    @Published public var columnWidths: [String: CGFloat] = [:]
    @Published public var sortColumn: String? = nil
    @Published public var isSortDesc: Bool = false
    @Published public var lastTimingMicros: Int64 = 0
    @Published public var lastQueryPath: String = "keyset"

    // Virtualized window state
    @Published public var currentPage: Page?
    @Published public var currentOffset: Int64 = 0

    // Search state
    @Published public var searchQuery: String = ""
    @Published public var matches: [FindMatch] = []
    @Published public var activeMatchIndex: Int = -1
    @Published public var searchProgress: Double = 0.0
    @Published public var isSearching: Bool = false

    private var findTask: Task<Void, Never>?
    private var isDisposed = false

    public init(doc: Doc, tableName: String) {
        self.doc = doc
        self.tableName = tableName
        loadInitialData()
    }

    deinit {
        findTask?.cancel()
    }

    public func loadInitialData() {
        do {
            self.columns = try doc.columns(for: tableName)
        } catch {
            self.columns = []
        }

        self.tableCount = doc.count(for: tableName)

        // Initialize column widths
        for col in columns {
            let titleWidth = CGFloat(col.name.count * 9 + 40)
            columnWidths[col.name] = max(100, min(300, titleWidth))
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
        } catch {
            // handle error
        }
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
        columnWidths[column] = max(60, min(800, width))
    }

    public func autoFitWidth(column: String) {
        guard let colIdx = columns.firstIndex(where: { $0.name == column }) else { return }
        let col = columns[colIdx]
        var maxChars = col.name.count + 4

        if let page = currentPage {
            for row in page.rows {
                if colIdx < row.count {
                    maxChars = max(maxChars, row[colIdx].displayText.count)
                }
            }
        }

        let fitted = CGFloat(maxChars * 8 + 32)
        columnWidths[column] = max(80, min(500, fitted))
    }

    private func applyColumnHints(_ hint: ColumnHint) {
        for (i, col) in columns.enumerated() {
            if i < hint.samples.count {
                let sample = hint.samples[i]
                let sampleChars = max(col.name.count + 4, sample.count)
                let calculated = CGFloat(sampleChars * 8 + 28)
                let current = columnWidths[col.name] ?? 100
                columnWidths[col.name] = max(current, min(400, calculated))
            }
        }
    }

    // MARK: - Streaming Search

    public func startFind(query: String) {
        findTask?.cancel()
        self.searchQuery = query
        self.matches = []
        self.activeMatchIndex = -1
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
                        self.activeMatchIndex = 0
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
        activeMatchIndex = (activeMatchIndex + 1) % matches.count
        jumpToMatch(index: activeMatchIndex)
    }

    public func previousMatch() {
        guard !matches.isEmpty else { return }
        activeMatchIndex = (activeMatchIndex - 1 + matches.count) % matches.count
        jumpToMatch(index: activeMatchIndex)
    }

    public func cancelFind() {
        findTask?.cancel()
        self.isSearching = false
        self.searchQuery = ""
        self.matches = []
        self.activeMatchIndex = -1
    }

    private func jumpToMatch(index: Int) {
        guard index >= 0 && index < matches.count else { return }
        let match = matches[index]
        let targetOrdinal = doc.ordinal(for: tableName, rowID: match.rowID)
        let pageOffset = max(0, targetOrdinal - 20)
        loadPage(offset: pageOffset)
    }
}
