import SwiftUI
import AppKit
import SQLDocCore

/// Edit-mode state for the app (docs/BanquetEditStyle.md). One session at a time,
/// bound to one document; the engine does the actual work (`EditSession`).
/// It never touches the Banquet URL (rule 2).
@MainActor
public final class EditViewModel: ObservableObject {
    @Published public private(set) var session: EditSession?
    /// Bumped on every buffer change so views re-read `pending(...)`.
    @Published public private(set) var revision = 0
    /// The cell showing the inline editor, in page row / full column indices.
    @Published public var editingCell: (row: Int, col: Int)? = nil
    public private(set) var docID: String?

    weak var appVM: AppViewModel?

    public init() {}

    public func isEditing(_ entry: DocEntry?) -> Bool {
        session != nil && entry != nil && entry?.id == docID
    }
    public var pendingCount: Int { session?.buffer.count ?? 0 }
    public var isDirty: Bool { pendingCount > 0 }
    public var canUndo: Bool { session?.buffer.canUndo ?? false }
    public var canRedo: Bool { session?.buffer.canRedo ?? false }

    /// Rule 4, at table level.
    public func ineligibleReason(table: String) -> String? {
        guard let s = session else { return "Not in edit mode." }
        return EditSession.ineligibleReason(doc: s.doc, table: table)
    }

    /// Rule 4, at cell level: the rowid alias and BLOBs are not editable.
    public static func isCellEditable(column: Column, value: SQLiteValue) -> Bool {
        if value.isBlob { return false }
        if column.pk && column.pkIndex == 1 && column.type.uppercased() == "INTEGER" { return false }
        return true
    }

    public func pending(table: String, rowID: Int64, column: String) -> SQLiteValue? {
        _ = revision
        return session?.buffer.pending(table: table, rowID: rowID, column: column)
    }

    // MARK: Session

    @discardableResult
    public func enter(_ entry: DocEntry) -> Bool {
        if isEditing(entry) { return true }
        guard exit() else { return false } // another doc's session, possibly dirty
        do {
            session = try EditSession(doc: entry.doc)
            docID = entry.id
            UILog.event("edit", "enter", ["doc": entry.path])
            return true
        } catch {
            appVM?.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Leaves edit mode. Returns false if the user cancelled the dirty prompt.
    @discardableResult
    public func exit() -> Bool {
        guard session != nil else { return true }
        if !resolvePending() { return false }
        session?.close()
        session = nil
        docID = nil
        editingCell = nil
        revision += 1
        UILog.event("edit", "exit")
        return true
    }

    public func toggle() {
        guard let entry = appVM?.activeDocEntry else { return }
        if isEditing(entry) { exit() } else { enter(entry) }
    }

    /// Rule 11: with pending edits, ask Commit / Discard / Cancel. True means "go ahead".
    public func resolvePending() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save \(pendingCount) pending edit\(pendingCount == 1 ? "" : "s")?"
        alert.informativeText = "Your changes have not been written to the database."
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return commit()
        case .alertSecondButtonReturn: revert(); return true
        default: return false
        }
    }

    // MARK: Staging

    /// Stages `text` for a cell. Returns an error message if it can't be staged (rules 6, 7).
    public func stage(table: String, rowID: Int64, column: Column, original: SQLiteValue, text: String) -> String? {
        switch CellCoercion.parse(text, for: column) {
        case .failure(let e): return e.localizedDescription
        case .success(let v): put(table, rowID, column, original, v); return nil
        }
    }

    public func stageNull(table: String, rowID: Int64, column: Column, original: SQLiteValue) -> String? {
        switch CellCoercion.null(for: column) {
        case .failure(let e): return e.localizedDescription
        case .success(let v): put(table, rowID, column, original, v); return nil
        }
    }

    private func put(_ table: String, _ rowID: Int64, _ column: Column, _ original: SQLiteValue, _ new: SQLiteValue) {
        session?.buffer.stage(CellEdit(table: table, rowID: rowID, column: column.name, original: original, new: new))
        revision += 1
        UILog.event("edit", "stage", ["table": table, "row": "\(rowID)", "col": column.name, "pending": "\(pendingCount)"])
    }

    public func undo() { if session?.buffer.undo() == true { revision += 1 } }
    public func redo() { if session?.buffer.redo() == true { revision += 1 } }

    public func revert() {
        session?.buffer.revert()
        editingCell = nil
        revision += 1
        UILog.event("edit", "revert")
    }

    // MARK: Commit

    @discardableResult
    public func commit() -> Bool {
        guard let s = session, isDirty else { return true }
        do {
            try s.commit()
            revision += 1
            editingCell = nil
            UILog.event("edit", "commit ok")
            appVM?.reloadTables(docID: docID)
            return true
        } catch {
            appVM?.errorMessage = error.localizedDescription
            UILog.event("edit", "commit failed", ["error": error.localizedDescription])
            return false
        }
    }
}
