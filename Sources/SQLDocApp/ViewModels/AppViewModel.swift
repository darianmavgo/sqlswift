import SwiftUI
import AppKit
import Combine
import SQLDocCore

public struct CellInspectInfo: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let tableName: String
    public let colName: String
    public let colType: String
    public let value: SQLiteValue
    public let rowOrdinal: Int64
    /// For blob cells: how to fetch the actual bytes (rowid known → lazy load).
    public var loadBlob: (() -> Data?)? = nil

    public init(tableName: String, colName: String, colType: String, value: SQLiteValue, rowOrdinal: Int64) {
        self.tableName = tableName
        self.colName = colName
        self.colType = colType
        self.value = value
        self.rowOrdinal = rowOrdinal
    }
}

public enum FolderSortOrder: String, CaseIterable, Sendable {
    case folder = "By Folder"
    case modified = "Newest"
    case size = "Largest"
    case name = "Name"
}

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var activeDocEntry: DocEntry? {
        didSet { saveHotReloadSession() }
    }
    @Published public var openDocuments: [DocEntry] = []
    @Published public var recentItems: [RecentItem] = []
    @Published public var workspaceItems: [RecentItem] = []
    /// True while the database's table list (banquet-table-list-style) is showing instead of one table.
    @Published public var isTableListVisible: Bool = false
    @Published public var selectedTableName: String = "" {
        didSet {
            if selectedTableName != oldValue { UILog.event("nav", "select table", ["table": selectedTableName]) }
            saveHotReloadSession()
        }
    }
    @Published public var isFolderBrowserVisible: Bool = false {
        didSet { saveHotReloadSession() }
    }
    @Published public var currentFolderPath: String = "" {
        didSet { saveHotReloadSession() }
    }
    @Published public var folderFiles: [SQLiteFileEntry] = []
    @Published public var folderSummaries: [FolderSummary] = []
    @Published public var selectedSubfolder: String? = nil {
        didSet { saveHotReloadSession() }
    }
    @Published public var folderSearchQuery: String = ""
    @Published public var folderSortOrder: FolderSortOrder = .folder
    @Published public var extraQueryParams: [String] = []
    @Published public var isScanningFolder: Bool = false
    @Published public var isFindBarVisible: Bool = false
    @Published public var zoomScale: Double = 1.0
    @Published public var errorMessage: String? = nil {
        didSet { if let e = errorMessage { UILog.event("error", e) } }
    }
    @Published public var isDropTargeted: Bool = false

    // State persistence & Settings
    @Published public var themeMode: AppThemeMode = .system {
        didSet {
            StatePersistenceManager.shared.themeMode = themeMode
        }
    }

    // Busy overlay state
    /// Opens (file or Banquet URL) running on worker threads; lets tests and UI scripts wait for quiescence.
    public private(set) var inFlightOpens = 0
    @Published public var isBusy: Bool = false
    @Published public var busyTitle: String = ""
    @Published public var busyMessage: String = ""
    @Published public var busyProgress: Double? = nil
    public var cancelBusyAction: (() -> Void)? = nil

    // Cell Inspector
    @Published public var inspectingCell: CellInspectInfo? = nil

    // Sheets / panels
    @Published public var showSchemaSheet: Bool = false
    @Published public var showQueryConsole: Bool = false
    @Published public var showJumpToRow: Bool = false
    @Published public var showSidebar: Bool = true
    @Published public var showRowDetail: Bool = false

    /// Mirror of the table view-model on screen, so menu commands can act on it.
    /// Its changes are forwarded so menu check marks stay current.
    public private(set) var activeTableVM: TableViewModel?
    private var activeTableVMObserver: AnyCancellable?

    private var tableVMCache: [String: TableViewModel] = [:]

    /// Resolves the table view-model for the current doc + table selection.
    /// Called from lifecycle callbacks (never during `body` evaluation) whenever the
    /// active document or table changes. Evicts view-models for databases that are
    /// no longer open (freeing their pages and background observers), and applies
    /// any pending drill-down / Banquet query to the resolved view-model.
    public func syncActiveTableVM() {
        let openIDs = Set(openDocuments.map { $0.id })
        for (key, vm) in tableVMCache where !openIDs.contains(String(key.split(separator: ":").first ?? "")) {
            vm.dispose()
            tableVMCache.removeValue(forKey: key)
        }

        guard let entry = activeDocEntry, !selectedTableName.isEmpty else {
            setActiveTableVM(nil)
            return
        }
        let key = "\(entry.id):\(selectedTableName)"
        let vm: TableViewModel
        if let existing = tableVMCache[key] {
            vm = existing
        } else {
            let created = TableViewModel(doc: entry.doc, tableName: selectedTableName, docID: entry.id)
            tableVMCache[key] = created
            vm = created
        }
        if let drill = pendingDrillDown, drill.table == selectedTableName {
            vm.setFilters(drill.filters)
            pendingDrillDown = nil
        }
        if let pending = pendingBanquet,
           pending.table.isEmpty || pending.table == selectedTableName {
            vm.applyBanquet(pending)
            pendingBanquet = nil
        }
        setActiveTableVM(vm)
    }

    public func setActiveTableVM(_ vm: TableViewModel?) {
        guard activeTableVM !== vm else { return }
        activeTableVM = vm
        activeTableVMObserver = vm?.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        objectWillChange.send()
    }

    /// What the window is showing right now, for `bin/ui-state.json`. Includes the
    /// Banquet URL the bar renders so a mismatch with the grid is visible at a glance.
    public func uiStateSnapshot() -> [String: Any] {
        var s: [String: Any] = [
            "doc": activeDocEntry?.path ?? "",
            "table": selectedTableName,
            "folderBrowserVisible": isFolderBrowserVisible,
            "sidebar": showSidebar,
            "rowDetailPanel": showRowDetail,
            "bannerError": errorMessage ?? "",
            "banquetBarEditing": isBanquetBarEditing,
            "banquetURL": banquetURLString(for: activeTableVM),
            "banquetBarText": banquetBarText,
            "suggestions": banquetSuggestionsSnapshot,
            "nav": ["back": canNavigateBack, "forward": canNavigateForward, "current": navStack.current ?? ""] as [String: Any],
            "folder": [
                "path": currentFolderPath,
                "subfolder": selectedSubfolder ?? "",
                "dbCount": folderFiles.count,
                "dbs": folderFiles.prefix(12).map { URL(fileURLWithPath: $0.path).lastPathComponent },
                "sort": "\(folderSortOrder)",
            ] as [String: Any],
        ]
        if let sel = selectedCell { s["selectedCell"] = ["row": sel.row, "col": sel.col] }
        if let vm = activeTableVM {
            s["grid"] = [
                "displayKind": vm.displayKind.rawValue,
                "visibleColumns": vm.visibleColumns.map(\.name),
                "totalColumns": vm.columns.count,
                "sort": vm.sortColumn.map { ($0, vm.isSortDesc ? "desc" : "asc") }.map { "\($0.0) \($0.1)" } ?? "",
                "filters": vm.filters.count,
                "offset": vm.currentOffset,
                "pageLimit": vm.pageLimit,
                "rowsLoaded": vm.currentPage?.rows.count ?? 0,
                "queryPath": vm.lastQueryPath,
                "queryMicros": vm.lastTimingMicros,
                "isLoading": vm.isLoading,
                "thinTable": isThinTable,
            ] as [String: Any]
        }
        return s
    }

    /// Detail panel is only offered where the grid has horizontal room.
    public static let thinTableMaxColumns = 8
    public var isThinTable: Bool {
        guard let vm = activeTableVM else { return false }
        return vm.displayKind != .summary && vm.visibleColumns.count <= Self.thinTableMaxColumns
    }

    // Selection state
    @Published public var selectedCell: (row: Int, col: Int)? = nil
    @Published public var selectedRowIndex: Int? = nil

    // Banquet Bar state
    @Published public var isBanquetBarEditing: Bool = false
    /// What the Banquet bar field currently shows. Deliberately not @Published (every
    /// keystroke would re-render observers); read only by the UI-state snapshot.
    public var banquetBarText: String = ""
    @Published public var banquetBarPendingPaste: String? = nil
    /// Dev-only (UICommands `type`): replaces the bar text as if the user typed it.
    @Published public var banquetBarInjectedText: String? = nil
    @Published public var banquetCopiedFeedback: Bool = false
    @Published public var pendingBanquet: Banquet? = nil
    @Published public var pendingDrillDown: (table: String, filters: [ColumnFilter])? = nil

    /// Switches to `targetTable` in the current document and applies `filters` (1-click relational drill-down).
    public func drillDown(toTable targetTable: String, filters: [ColumnFilter]) {
        self.pendingDrillDown = (table: targetTable, filters: filters)
        self.isFolderBrowserVisible = false
        self.selectedTableName = targetTable
    }

    public let session = SessionManager.shared
    public let recents = RecentsManager.shared
    /// Shared by default; a test assigns its own so parallel cases can't see each other's URLs.
    public var banquetHistory = BanquetHistory.shared
    /// ↑/↓ history recall state for the bar. Not @Published (changes per keystroke).
    public var barRecall = BanquetRecall()

    /// One ↑ (`older`) or ↓ step through history. Returns the text to put in the bar.
    public func recallStep(older: Bool, current: String) -> String? {
        barRecall.step(older: older, current: current, entries: banquetHistory.entries)
    }
    public let persistence = StatePersistenceManager.shared

    private var isRestoringSession = false

    public init() {
        self.themeMode = persistence.themeMode
        self.zoomScale = persistence.zoomScale
        refreshSession()
        restoreHotReloadSession()
    }

    private func saveHotReloadSession() {
        guard !isRestoringSession else { return }
        let defaults = UserDefaults.standard
        defaults.set(currentFolderPath, forKey: "sqldoc.hotReload.folderPath")
        defaults.set(selectedSubfolder, forKey: "sqldoc.hotReload.subfolder")
        defaults.set(activeDocEntry?.path, forKey: "sqldoc.hotReload.docPath")
        defaults.set(selectedTableName, forKey: "sqldoc.hotReload.tableName")
        defaults.set(isFolderBrowserVisible, forKey: "sqldoc.hotReload.isFolderBrowserVisible")
    }

    private func restoreHotReloadSession() {
        isRestoringSession = true
        defer { isRestoringSession = false }

        let defaults = UserDefaults.standard
        let savedFolder = defaults.string(forKey: "sqldoc.hotReload.folderPath") ?? ""
        let savedSubfolder = defaults.string(forKey: "sqldoc.hotReload.subfolder")
        let savedDocPath = defaults.string(forKey: "sqldoc.hotReload.docPath") ?? ""
        let savedTable = defaults.string(forKey: "sqldoc.hotReload.tableName") ?? ""
        let savedFolderVisible = defaults.object(forKey: "sqldoc.hotReload.isFolderBrowserVisible") as? Bool

        if !savedDocPath.isEmpty && FileManager.default.fileExists(atPath: savedDocPath) && !FolderScanner.isDirectory(savedDocPath) {
            open(path: savedDocPath, targetTable: savedTable.isEmpty ? nil : savedTable)
            self.isFolderBrowserVisible = savedFolderVisible ?? false
            if !savedFolder.isEmpty && FolderScanner.isDirectory(savedFolder) {
                openFolder(path: savedFolder, selectSubfolder: savedSubfolder, showBrowser: savedFolderVisible ?? false)
            }
        } else if !savedFolder.isEmpty && FolderScanner.isDirectory(savedFolder) {
            openFolder(path: savedFolder, selectSubfolder: savedSubfolder, showBrowser: true)
        }
    }

    public static func defaultStartingFolder() -> String {
        ""
    }

    public static func quickFolders() -> [(label: String, path: String)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let raw: [(String, String)] = [
            ("trade_well / data", "\(home)/Documents/trade_well/backtestgosqlite/data"),
            ("trade_well / reports", "\(home)/Documents/trade_well/backtestgosqlite/data/reports"),
            ("view_sqlite", "\(home)/Documents/view_sqlite"),
            ("Documents", "\(home)/Documents")
        ]
        return raw.filter { fm.fileExists(atPath: $0.1) }
    }

    public func openFolder(path: String, selectSubfolder: String? = nil, showBrowser: Bool = true) {
        let resolved = FolderScanner.resolveLocalPath(path)
        guard FolderScanner.isDirectory(resolved) else {
            errorMessage = "Cannot find folder at '\(path)'"
            return
        }
        self.currentFolderPath = resolved
        self.selectedSubfolder = selectSubfolder
        if showBrowser {
            self.isFolderBrowserVisible = true
        }
        self.errorMessage = nil
        self.isScanningFolder = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = FolderScanner.scan(rootPath: resolved, maxDepth: 6, inspectSchema: true)
            await MainActor.run {
                guard let self, self.currentFolderPath == resolved else { return }
                self.folderFiles = scanned.files
                self.folderSummaries = scanned.folders
                self.isScanningFolder = false
            }
        }
    }

    public func refreshCurrentFolder() {
        guard !currentFolderPath.isEmpty else { return }
        openFolder(path: currentFolderPath, selectSubfolder: selectedSubfolder, showBrowser: isFolderBrowserVisible)
    }

    public var effectiveColorScheme: ColorScheme? {
        switch themeMode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            if let docTheme = activeDocEntry?.doc.style.theme.lowercased() {
                if docTheme == "light" { return .light }
                if docTheme == "dark" { return .dark }
            }
            return nil
        }
    }

    public func refreshSession() {
        self.openDocuments = session.list()
        self.recentItems = recents.getRecents()
        if workspaceItems.isEmpty {
            self.workspaceItems = Self.discoverWorkspaceDatabases()
        }
        if activeDocEntry == nil, let first = session.first() {
            setActiveDocument(first)
        }
    }

    private static func discoverWorkspaceDatabases() -> [RecentItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidateRoots = [
            "\(home)/Documents/trade_well/backtestgosqlite/data",
            "\(home)/Documents/view_sqlite"
        ]
        var found: [RecentItem] = []
        var seen = Set<String>()

        for root in candidateRoots where fm.fileExists(atPath: root) {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                guard ["db", "sqlite", "sqlite3"].contains(ext) else { continue }
                let path = url.path
                if path.contains("/.build/") || path.contains("/testdata/") || path.hasSuffix("/sqldoc.db") {
                    continue
                }
                guard seen.insert(path).inserted else { continue }
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(vals?.fileSize ?? 0)
                let modified = vals?.contentModificationDate ?? Date.distantPast
                // Build a friendly relative label when inside a subfolder like reports/4/rotation.db
                let displayName: String
                if path.hasPrefix(root + "/") {
                    displayName = String(path.dropFirst(root.count + 1))
                } else {
                    displayName = url.lastPathComponent
                }
                found.append(RecentItem(path: path, name: displayName, size: size, lastOpened: modified))
            }
        }
        return found.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Opens a file or folder without ever blocking the main thread: path probing and
    /// `Doc.open` (header read, `PRAGMA journal_mode`, schema discovery — any of which can
    /// wait on a locked WAL or a slow volume) run on a worker; only the state swap is on main.
    /// `completion` fires on the main actor once the open has succeeded or failed.
    public func open(path: String, isImmutable: Bool = false, targetTable: String? = nil,
                     completion: (@MainActor () -> Void)? = nil) {
        UILog.event("nav", "open", ["path": path, "table": targetTable ?? "-"])
        let session = self.session
        inFlightOpens += 1
        // Only show the busy overlay if the open is actually slow.
        let busyTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let name = (path as NSString).lastPathComponent
            self?.setBusy(title: "Opening \(name)", message: "Reading schema…")
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let resolved = FolderScanner.resolveLocalPath(path)
            let isDir = FolderScanner.isDirectory(resolved)
            var entry: DocEntry?
            var failure: Error?
            if !isDir {
                do { entry = try session.open(path: resolved, options: DocOptions(isImmutable: isImmutable)) }
                catch { failure = error }
            }
            let result = (entry, failure)
            await MainActor.run {
                busyTimer.cancel()
                guard let self else { return }
                self.inFlightOpens -= 1
                if self.isBusy, self.busyTitle.hasPrefix("Opening ") { self.clearBusy() }
                defer { completion?() }

                if isDir {
                    self.openFolder(path: resolved, showBrowser: true)
                    return
                }
                if let entry = result.0 {
                    self.refreshSession()
                    self.setActiveDocument(entry, preferredTable: targetTable)
                    self.isFolderBrowserVisible = false
                    // If currentFolderPath isn't an ancestor of this file, scan the file's parent folder for the sidebar
                    let parentDir = (resolved as NSString).deletingLastPathComponent
                    if self.currentFolderPath.isEmpty || !resolved.hasPrefix(self.currentFolderPath) {
                        self.openFolder(path: parentDir, showBrowser: false)
                    }
                    self.errorMessage = nil
                    return
                }
                // Not a SQLite file? Try converting a plain-text format we understand.
                if FileImporter.canImport(path: resolved) {
                    self.importAndOpen(path: resolved)
                    return
                }
                let ext = (resolved as NSString).pathExtension.lowercased()
                if ["xlsx", "xls", "pdf"].contains(ext) {
                    self.errorMessage = ".\(ext) import isn't supported yet — convert it to CSV or SQLite first."
                    return
                }
                self.errorMessage = result.1?.localizedDescription ?? "Could not open \(resolved)"
            }
        }
    }

    private func importAndOpen(path: String) {
        let name = (path as NSString).lastPathComponent
        setBusy(title: "Importing \(name)", message: "Converting to SQLite…")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let dbPath = try FileImporter.importToTempDB(path: path)
                await MainActor.run {
                    self?.clearBusy()
                    self?.open(path: dbPath)
                }
            } catch {
                await MainActor.run {
                    self?.clearBusy()
                    self?.errorMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    public func open(url: URL, isImmutable: Bool = false) {
        open(path: url.path, isImmutable: isImmutable)
    }

    public func openDropped(data: Data, originalName: String) {
        do {
            let entry = try session.openTemporary(data: data, originalName: originalName)
            refreshSession()
            setActiveDocument(entry)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func pasteFromClipboard() {
        let pb = NSPasteboard.general

        // 1. Try file URLs from pasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let firstURL = urls.first,
           firstURL.isFileURL,
           FileManager.default.fileExists(atPath: firstURL.path) {
            open(url: firstURL)
            return
        }

        // 2. Try string content: if it's a local file/folder, open it; otherwise paste into Banquet bar for editing!
        if let rawString = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawString.isEmpty {
            let singleLine = rawString
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let resolved = FolderScanner.resolveLocalPath(singleLine)
            if FileManager.default.fileExists(atPath: resolved) {
                open(path: resolved)
                return
            } else {
                banquetBarPendingPaste = singleLine
                isBanquetBarEditing = true
                return
            }
        }
    }

    public func setActiveDocument(_ entry: DocEntry, preferredTable: String? = nil) {
        self.activeDocEntry = entry
        let visibleTables = entry.doc.tables.filter { !$0.hidden }
        if let pref = preferredTable, entry.doc.tables.contains(where: { $0.name == pref }) {
            self.selectedTableName = pref
        } else {
            self.selectedTableName = visibleTables.first?.name ?? entry.doc.tables.first?.name ?? ""
        }
        self.isFolderBrowserVisible = false
        self.selectedCell = (0, 0)
        self.selectedRowIndex = 0
        self.inspectingCell = nil
    }

    public func selectDoc(id: String) {
        if let entry = session.get(id: id) {
            setActiveDocument(entry)
        }
    }

    public func closeDoc(id: String) {
        let isCurrent = activeDocEntry?.id == id
        session.close(id: id)
        refreshSession()
        if isCurrent {
            if let next = session.first() {
                setActiveDocument(next)
            } else {
                activeDocEntry = nil
                selectedTableName = ""
            }
        }
    }

    public func closeCurrentDoc() {
        UILog.event("nav", "close doc")
        if let active = activeDocEntry {
            closeDoc(id: active.id)
        }
    }

    public func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Open"
        panel.message = "Choose a SQLite file (.db, .sqlite) or a folder to browse all SQLite files inside it."

        if panel.runModal() == .OK {
            for url in panel.urls {
                open(url: url)
            }
        }
    }

    /// Re-reads whatever is on screen from disk: the folder listing, or the active table
    /// (caches dropped, count re-estimated, current page re-fetched).
    public func reload() {
        UILog.event("nav", "reload")
        if isFolderBrowserVisible || activeDocEntry == nil {
            guard !currentFolderPath.isEmpty else { return }
            openFolder(path: currentFolderPath, selectSubfolder: selectedSubfolder, showBrowser: isFolderBrowserVisible)
        } else {
            activeTableVM?.reloadFromDisk()
        }
    }

    /// The SQL the current Banquet URL translates to, for the SQL console's first view.
    public func queryConsoleSeedSQL() -> String? {
        guard let vm = activeTableVM, activeDocEntry != nil, !selectedTableName.isEmpty,
              !isTableListVisible else { return nil }
        var b = banquet(for: vm)
        if b.select.isEmpty || b.select == ["*"] { b.select = ["*"] }
        return BanquetComposer.compose(b)
    }

    public func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Browse Folder"
        panel.message = "Choose a folder to list all SQLite databases inside it."

        if panel.runModal() == .OK, let url = panel.url {
            openFolder(path: url.path, showBrowser: true)
        }
    }

    public func exportCurrentTable(as format: ExportFormat = .csv) {
        guard let doc = activeDocEntry?.doc, !selectedTableName.isEmpty else { return }
        let table = selectedTableName
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table).\(format.fileExtension)"
        guard panel.runModal() == .OK, let targetURL = panel.url else { return }

        setBusy(title: "Exporting \(table)", message: format.label)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let text = try doc.export(table: table, as: format)
                try text.write(to: targetURL, atomically: true, encoding: .utf8)
                await MainActor.run { self?.clearBusy() }
            } catch {
                await MainActor.run {
                    self?.clearBusy()
                    self?.errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    public func setThemeMode(_ mode: AppThemeMode) {
        themeMode = mode
    }

    public func setBusy(title: String, message: String, progress: Double? = nil, cancellable: (() -> Void)? = nil) {
        self.isBusy = true
        self.busyTitle = title
        self.busyMessage = message
        self.busyProgress = progress
        self.cancelBusyAction = cancellable
    }

    public func clearBusy() {
        self.isBusy = false
        self.busyTitle = ""
        self.busyMessage = ""
        self.busyProgress = nil
        self.cancelBusyAction = nil
    }

    public func zoomIn() {
        zoomScale = min(BehaviorConfig.zoomMax, zoomScale + 0.1)
        persistence.zoomScale = zoomScale
    }

    public func zoomOut() {
        zoomScale = max(BehaviorConfig.zoomMin, zoomScale - 0.1)
        persistence.zoomScale = zoomScale
    }

    public func zoomReset() {
        zoomScale = BehaviorConfig.zoomDefault
        persistence.zoomScale = zoomScale
    }

    // MARK: - Banquet Integration

    /// Composes a `Banquet` model from current document, table selection, and table view model state.
    public func banquet(for tableVM: TableViewModel?) -> Banquet {
        guard let entry = activeDocEntry else {
            return Banquet()
        }

        let dataset = entry.doc.path
        let table = selectedTableName
        let sortCol = tableVM?.sortColumn
        let isSortDesc = tableVM?.isSortDesc ?? false
        let filters = tableVM?.filters
        // Showing every row: no slice, so the URL says what the user typed.
        let allRows = tableVM?.isShowingAllRows ?? false
        let offset: Int? = allRows ? nil : Int(tableVM?.currentOffset ?? 0)
        let limit: Int? = allRows ? nil : (tableVM?.pageLimit ?? 100)

        // Preserve explicit column projection if set via Banquet or manual column hiding
        let selectCols: [String]
        if let tableVM {
            let projected = tableVM.projectedColumnNames
            if !projected.isEmpty {
                selectCols = projected
            } else if tableVM.banquetSelect != ["*"] && !tableVM.banquetSelect.isEmpty {
                selectCols = tableVM.banquetSelect
            } else {
                selectCols = ["*"]
            }
        } else {
            selectCols = ["*"]
        }

        // Build where clause from filters (or preserve raw whereClause from Banquet URL)
        let whereClause: String?
        if let filters, !filters.isEmpty {
            let clauses = filters.compactMap { filter -> String? in
                let val = filter.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let col = filter.column
                switch filter.op {
                case .equals:
                    return "\(col) = '\(val.replacingOccurrences(of: "'", with: "''"))'"
                case .notEquals:
                    return "\(col) != '\(val.replacingOccurrences(of: "'", with: "''"))'"
                case .contains:
                    return "\(col) LIKE '%\(val)%'"
                case .startsWith:
                    return "\(col) LIKE '\(val)%'"
                case .greater:
                    return "\(col) > \(val)"
                case .less:
                    return "\(col) < \(val)"
                case .isNull:
                    return "\(col) IS NULL"
                case .isNotNull:
                    return "\(col) IS NOT NULL"
                }
            }
            whereClause = clauses.isEmpty ? tableVM?.banquetWhereClause : clauses.joined(separator: " AND ")
        } else {
            whereClause = tableVM?.banquetWhereClause
        }

        var extraParams = (tableVM?.extraQueryParams.isEmpty == false)
            ? (tableVM?.extraQueryParams ?? [])
            : self.extraQueryParams
        // The display mode is part of the view, so it travels in the URL: a bookmark or
        // pasted link reopens in Trim/Summary rather than whatever the table defaults to.
        extraParams.removeAll { $0.lowercased().hasPrefix("display=") }
        if let tableVM, tableVM.displayKind != .raw {
            let explicitList = !selectCols.contains("*") && selectCols != ["*"]
            if tableVM.displayKind == .summary || !explicitList {
                extraParams.append("display=\(tableVM.displayKind.rawValue)")
            }
        }

        return Banquet(
            dataSetPath: dataset,
            table: table,
            select: selectCols,
            sortColumn: sortCol,
            isSortDesc: isSortDesc,
            whereClause: whereClause,
            limit: limit,
            offset: offset,
            groupBy: tableVM?.banquetGroupBy,
            having: tableVM?.banquetHaving,
            extraQueryParams: extraParams,
            rawQuery: tableVM?.rawQuery ?? ""
        )
    }

    // MARK: - Banquet-Driven Pagination

    /// Executes a Banquet URL query with an updated `[offset : offset + limit]` slice.
    public func executeBanquetSlice(offset: Int64, limit: Int? = nil, tableVM: TableViewModel) {
        var b = banquet(for: tableVM)
        let pageLen = limit ?? tableVM.pageLimit
        b.offset = Int(max(0, offset))
        b.limit = pageLen
        let url = BanquetSerializer.canonicalString(for: b)
        openBanquet(urlString: url, activeTableVM: tableVM)
    }

    public func paginateFirst(tableVM: TableViewModel) {
        guard !tableVM.isShowingAllRows else { return }   // one page holds every row
        executeBanquetSlice(offset: 0, limit: tableVM.pageLimit, tableVM: tableVM)
    }

    public func paginatePrevious(tableVM: TableViewModel) {
        guard !tableVM.isShowingAllRows else { return }   // one page holds every row
        let prevOffset = max(0, tableVM.currentOffset - Int64(tableVM.pageLimit))
        executeBanquetSlice(offset: prevOffset, limit: tableVM.pageLimit, tableVM: tableVM)
    }

    public func paginateNext(tableVM: TableViewModel) {
        guard !tableVM.isShowingAllRows else { return }   // one page holds every row
        let step = Int64(tableVM.currentPage?.rows.count ?? tableVM.pageLimit)
        let nextOffset = tableVM.currentOffset + max(1, step)
        executeBanquetSlice(offset: nextOffset, limit: tableVM.pageLimit, tableVM: tableVM)
    }

    public func paginateLast(tableVM: TableViewModel) {
        guard !tableVM.isShowingAllRows else { return }   // one page holds every row
        let total = !tableVM.filters.isEmpty
            ? tableVM.filteredCount
            : (tableVM.tableCount.known ? tableVM.tableCount.rows : nil)
        if let total, total > 0 {
            let lastOffset = max(0, total - Int64(tableVM.pageLimit))
            executeBanquetSlice(offset: lastOffset, limit: tableVM.pageLimit, tableVM: tableVM)
        } else {
            paginateNext(tableVM: tableVM)
        }
    }

    /// Returns the canonical Banquet URL string for the current view.
    public func banquetURLString(for tableVM: TableViewModel?) -> String {
        if isFolderBrowserVisible || activeDocEntry == nil {
            var url = currentFolderPath
            if let sub = selectedSubfolder, !sub.isEmpty {
                url += "/" + sub
            }
            // Never emit a `databases` segment: a bare container ends in "/", and a sort
            // clause is itself clause-like so the parser still reads it as a collection.
            if !url.hasSuffix("/") { url += "/" }
            switch folderSortOrder {
            case .size:
                url += "-size_bytes"
            case .modified:
                url += "-modified"
            case .name:
                url += "+name"
            case .folder:
                break
            }
            var qParams: [String] = []
            let q = folderSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                qParams.append("where=\(q)")
            }
            for extra in extraQueryParams {
                let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !qParams.contains(trimmed) {
                    qParams.append(trimmed)
                }
            }
            if !qParams.isEmpty {
                url += "?" + qParams.joined(separator: "&")
            }
            return url
        }
        if isTableListVisible, let entry = activeDocEntry {
            return entry.doc.path + "/tables"
        }
        let b = banquet(for: tableVM)
        return BanquetSerializer.canonicalString(for: b)
    }

    /// Copies the canonical Banquet URL for the active table to the pasteboard.
    public func copyBanquetURL(for tableVM: TableViewModel?) {
        let urlStr = banquetURLString(for: tableVM)
        guard !urlStr.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urlStr, forType: .string)

        banquetCopiedFeedback = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { [weak self] in
                self?.banquetCopiedFeedback = false
            }
        }
    }

    // MARK: - Omnibox: suggestions, history, back/forward

    /// Completions currently offered by the bar's dropdown (written by the bar, read by
    /// `uiStateSnapshot` so ui-e2e can assert them). Not @Published: it changes per keystroke.
    public private(set) var banquetSuggestionsSnapshot: [String] = []

    public func setSuggestionsSnapshot(_ completions: [String]) {
        guard completions != banquetSuggestionsSnapshot else { return }
        banquetSuggestionsSnapshot = completions
        // Only the dev snapshot reads this; skip the re-render cost in normal use.
        if UILog.isEnabled { objectWillChange.send() }
    }

    /// Forget back/forward and URL history (ui-e2e starts each case from a clean slate).
    public func resetNavigation() {
        navStack = BanquetNavStack()
        barRecall.reset()
        banquetHistory.clear()
        updateNavFlags()
    }

    private var navStack = BanquetNavStack()
    @Published public private(set) var canNavigateBack = false
    @Published public private(set) var canNavigateForward = false

    /// Everything the suggester may look at, from state that is already loaded.
    public func banquetSuggestContext(tableVM: TableViewModel?) -> BanquetSuggestContext {
        func file(_ path: String) -> BanquetSuggestContext.File {
            .init(path: path, name: (path as NSString).lastPathComponent)
        }
        return BanquetSuggestContext(
            history: banquetHistory.entries,
            recents: recents.getRecents().map { .init(path: $0.path, name: $0.name) },
            openDocs: openDocuments.map { file($0.doc.path) },
            activeDocPath: activeDocEntry?.doc.path,
            tables: activeDocEntry?.doc.tables.filter { !$0.hidden }.map(\.name) ?? [],
            activeTable: tableVM?.tableName,
            columns: tableVM?.rawColumns.map(\.name) ?? [])
    }

    /// Remembers a submitted URL for suggestions and for ⌘[ / ⌘]. `from` is the URL the
    /// grid showed before the jump, so the first Back has somewhere to go.
    public func noteBanquetNavigation(from: String, to: String) {
        navStack.visit(from)
        navStack.visit(to)
        banquetHistory.record(to)
        updateNavFlags()
    }

    public func navigateBack() {
        guard let url = navStack.back() else { return }
        updateNavFlags()
        openBanquet(urlString: url, activeTableVM: activeTableVM)
    }

    public func navigateForward() {
        guard let url = navStack.forward() else { return }
        updateNavFlags()
        openBanquet(urlString: url, activeTableVM: activeTableVM)
    }

    private func updateNavFlags() {
        canNavigateBack = navStack.canGoBack
        canNavigateForward = navStack.canGoForward
    }

    /// Navigates to a Banquet URL or local file/folder path: resolves dataset path, folder, table, sort, and filters.
    public func openBanquet(urlString: String, activeTableVM: TableViewModel? = nil,
                            completion: (@MainActor () -> Void)? = nil) {
        UILog.event("banquet", "open url", ["url": urlString])
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion?(); return }

        // Filesystem probes can stall (network volumes, iCloud placeholders), so they never run on main.
        inFlightOpens += 1
        Task.detached(priority: .userInitiated) { [weak self] in
            let directPath = FolderScanner.resolveLocalPath(trimmed)
            let isDir = FolderScanner.isDirectory(directPath)
            let exists = isDir || FileManager.default.fileExists(atPath: directPath)
            await MainActor.run {
                guard let self else { return }
                defer { self.inFlightOpens -= 1 }
                // A folder or file path typed or pasted directly opens immediately.
                if isDir {
                    self.openFolder(path: directPath, showBrowser: true)
                    completion?()
                    return
                }
                if exists {
                    self.open(path: directPath, completion: completion)
                    return
                }
                do {
                    let b = try BanquetParser.parse(trimmed)
                    self.applyBanquet(b, activeTableVM: activeTableVM, completion: completion)
                } catch {
                    self.errorMessage = "Failed to parse Banquet URL: \(error.localizedDescription)"
                    completion?()
                }
            }
        }
    }

    /// Applies a parsed `Banquet` query onto the application state. Opening the target
    /// database is asynchronous, so the table-level steps run from `finishApplyBanquet`.
    public func applyBanquet(_ b: Banquet, activeTableVM: TableViewModel? = nil,
                             completion: (@MainActor () -> Void)? = nil) {
        self.pendingBanquet = b
        self.extraQueryParams = b.extraQueryParams

        // 1. Check if this is a Folder Collection query (e.g. data/databases, data/reports/1/oos/databases/-size_bytes?where=markov)
        let isKnownDB = b.dataSetPath.hasSuffix(".db") || b.dataSetPath.hasSuffix(".sqlite") || b.dataSetPath.hasSuffix(".sqlite3")
        if b.isCollection || b.table == "databases" || (b.table == "tables" && !isKnownDB) {
            let targetPath = b.dataSetPath.isEmpty ? currentFolderPath : FolderScanner.resolveLocalPath(b.dataSetPath)
            var rootFolder = currentFolderPath
            var subfolder: String? = nil

            if FolderScanner.isDirectory(targetPath) {
                if !currentFolderPath.isEmpty && targetPath.hasPrefix(currentFolderPath) && targetPath != currentFolderPath {
                    subfolder = String(targetPath.dropFirst(currentFolderPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                } else {
                    rootFolder = targetPath
                }
            }

            // Map collection sort
            if let sc = b.sortColumn?.lowercased() {
                if sc.contains("size") {
                    folderSortOrder = .size
                } else if sc.contains("mod") || sc.contains("date") || sc.contains("time") {
                    folderSortOrder = .modified
                } else if sc.contains("name") {
                    folderSortOrder = .name
                } else {
                    folderSortOrder = .folder
                }
            }

            // Map collection filter / search
            if let w = b.whereClause, !w.isEmpty {
                folderSearchQuery = w
            }

            openFolder(path: rootFolder, selectSubfolder: subfolder, showBrowser: true)
            self.isFolderBrowserVisible = true
            self.pendingBanquet = nil
            completion?()
            return
        }

        // 2. Open or select database file if specified
        if !b.dataSetPath.isEmpty {
            let resolved = FolderScanner.resolveLocalPath(b.dataSetPath)
            if FolderScanner.isDirectory(resolved) {
                openFolder(path: resolved, showBrowser: true)
                self.isFolderBrowserVisible = true
                self.pendingBanquet = nil
                completion?()
                return
            }
            if let current = activeDocEntry, current.doc.path == resolved || (current.doc.path as NSString).lastPathComponent == b.dataSetPath {
                self.isFolderBrowserVisible = false
            } else if let existing = openDocuments.first(where: { $0.doc.path == resolved || ($0.doc.path as NSString).lastPathComponent == b.dataSetPath }) {
                setActiveDocument(existing)
            } else {
                // Open off-main, then continue with the table-level steps.
                open(path: resolved) { [weak self] in
                    guard let self else { completion?(); return }
                    if self.activeDocEntry == nil || self.errorMessage != nil {
                        completion?()
                        return
                    }
                    self.finishApplyBanquet(b, activeTableVM: activeTableVM)
                    completion?()
                }
                return
            }
        }
        finishApplyBanquet(b, activeTableVM: activeTableVM)
        completion?()
    }

    private func finishApplyBanquet(_ b: Banquet, activeTableVM: TableViewModel?) {
        // 3. Database Overview (tables or empty table name)
        if b.table == "tables" || b.table.isEmpty {
            self.isFolderBrowserVisible = false
            self.isTableListVisible = activeDocEntry != nil
            self.pendingBanquet = nil
            return
        }

        // 4. Select table if specified
        self.isTableListVisible = false
        if !b.table.isEmpty, let entry = activeDocEntry {
            if entry.doc.tables.contains(where: { $0.name == b.table }) {
                self.isFolderBrowserVisible = false
                if self.selectedTableName != b.table {
                    self.selectedTableName = b.table
                }
            }
        }

        // 5. Apply sort, filters, columns, slice clauses onto the table view model
        let targetTable = b.table.isEmpty ? selectedTableName : b.table
        if let vm = activeTableVM, vm.tableName == targetTable {
            vm.applyBanquet(b)
            self.pendingBanquet = nil
        }
    }
}

