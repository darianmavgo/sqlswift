import SwiftUI
import AppKit
import SQLDocCore

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

    public let session = SessionManager.shared
    public let recents = RecentsManager.shared

    public init() {
        refreshSession()
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

    public func setActiveDocument(_ entry: DocEntry) {
        self.activeDocEntry = entry
        let visibleTables = entry.doc.tables.filter { !$0.hidden }
        let defaultTable = visibleTables.first?.name ?? entry.doc.tables.first?.name ?? ""
        self.selectedTableName = defaultTable
        self.isGalleryView = false
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

    public func zoomIn() {
        zoomScale = min(2.0, zoomScale + 0.1)
    }

    public func zoomOut() {
        zoomScale = max(0.7, zoomScale - 0.1)
    }

    public func zoomReset() {
        zoomScale = 1.0
    }
}
