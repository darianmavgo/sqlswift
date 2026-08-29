import SwiftUI
import AppKit
import SQLDocCore

public struct CellInspectInfo: Identifiable, Sendable {
    public let id = UUID()
    public let tableName: String
    public let colName: String
    public let colType: String
    public let value: SQLiteValue
    public let rowOrdinal: Int64

    public init(tableName: String, colName: String, colType: String, value: SQLiteValue, rowOrdinal: Int64) {
        self.tableName = tableName
        self.colName = colName
        self.colType = colType
        self.value = value
        self.rowOrdinal = rowOrdinal
    }
}

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var activeDocEntry: DocEntry?
    @Published public var openDocuments: [DocEntry] = []
    @Published public var recentItems: [RecentItem] = []
    @Published public var selectedTableName: String = ""
    @Published public var isGalleryView: Bool = false
    @Published public var isFindBarVisible: Bool = false
    @Published public var zoomScale: Double = 1.0
    @Published public var errorMessage: String? = nil
    @Published public var isDropTargeted: Bool = false

    // State persistence & Settings
    @Published public var themeMode: AppThemeMode = .system {
        didSet {
            StatePersistenceManager.shared.themeMode = themeMode
        }
    }

    // Busy overlay state
    @Published public var isBusy: Bool = false
    @Published public var busyTitle: String = ""
    @Published public var busyMessage: String = ""
    @Published public var busyProgress: Double? = nil
    public var cancelBusyAction: (() -> Void)? = nil

    // Cell Inspector
    @Published public var inspectingCell: CellInspectInfo? = nil

    // Selection state
    @Published public var selectedCell: (row: Int, col: Int)? = nil
    @Published public var selectedRowIndex: Int? = nil

    public let session = SessionManager.shared
    public let recents = RecentsManager.shared
    public let persistence = StatePersistenceManager.shared

    public init() {
        self.themeMode = persistence.themeMode
        self.zoomScale = persistence.zoomScale
        refreshSession()
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
        if activeDocEntry == nil, let first = session.first() {
            setActiveDocument(first)
        }
    }

    public func open(path: String, isImmutable: Bool = false) {
        do {
            let entry = try session.open(path: path, options: DocOptions(isImmutable: isImmutable))
            refreshSession()
            setActiveDocument(entry)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let firstURL = urls.first {
            open(url: firstURL)
            return
        }

        // 2. Try string content
        if let string = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            var path = string
            // Handle file:// URIs
            if path.hasPrefix("file://"), let url = URL(string: path) {
                path = url.path
            }
            // Strip wrapping quotes
            if (path.hasPrefix("\"") && path.hasSuffix("\"")) || (path.hasPrefix("'") && path.hasSuffix("'")) {
                path = String(path.dropFirst().dropLast())
            }
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                open(path: expanded)
                return
            } else {
                errorMessage = "Cannot open pasted path: File not found at '\(path)'"
                return
            }
        }

        errorMessage = "Clipboard does not contain a valid database file path."
    }

    public func setActiveDocument(_ entry: DocEntry) {
        self.activeDocEntry = entry
        let visibleTables = entry.doc.tables.filter { !$0.hidden }
        let defaultTable = visibleTables.first?.name ?? entry.doc.tables.first?.name ?? ""
        self.selectedTableName = defaultTable
        self.isGalleryView = false
        self.selectedCell = nil
        self.selectedRowIndex = nil
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
        if let active = activeDocEntry {
            closeDoc(id: active.id)
        }
    }

    public func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]

        if panel.runModal() == .OK {
            for url in panel.urls {
                open(url: url)
            }
        }
    }

    public func exportCurrentTable() {
        guard let doc = activeDocEntry?.doc, !selectedTableName.isEmpty else { return }
        do {
            let csv = try doc.exportCSV(for: selectedTableName)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(selectedTableName).csv"
            panel.allowedContentTypes = [.commaSeparatedText]

            if panel.runModal() == .OK, let targetURL = panel.url {
                try csv.write(to: targetURL, atomically: true, encoding: .utf8)
            }
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
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
}
