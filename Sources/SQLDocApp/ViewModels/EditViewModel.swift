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
    /// A cell of a pending new row showing the inline editor (`id` is the row's temporary id).
    @Published public var editingNewCell: (id: Int64, col: Int)? = nil
    /// Rows picked with ⌘-click on the gutter, by rowid. Row ops act on these, else on the selected row.
    @Published public var markedRowIDs: Set<Int64> = []
    @Published public var showSQLPreview = false
    /// Bumped to ask the grid to scroll its new-rows footer into view.
    @Published public private(set) var revealNewRowsToken = 0
    public private(set) var docID: String?

    weak var appVM: AppViewModel?

    public init() {}

    public func isEditing(_ entry: DocEntry?) -> Bool {
        session != nil && entry != nil && entry?.id == docID
    }
    public var pendingCount: Int { session?.buffer.count ?? 0 }
    public var isDirty: Bool { pendingCount > 0 }
    public var updateCount: Int { session?.buffer.updateCount ?? 0 }
    public var insertCount: Int { session?.buffer.insertCount ?? 0 }
    public var deleteCount: Int { session?.buffer.deleteCount ?? 0 }
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

    public func isDeleted(table: String, rowID: Int64) -> Bool {
        _ = revision
        return session?.buffer.isDeleted(table: table, rowID: rowID) ?? false
    }

    public func newRows(table: String) -> [NewRow] {
        _ = revision
        return session?.buffer.newRows(table: table) ?? []
    }

    /// The statements a commit would run (display only).
    public var sqlPreview: [String] {
        _ = revision
        return session?.sqlPreview() ?? []
    }

    /// True when the table open in the active grid takes edits: an edit session on this doc,
    /// an eligible base table, and a plain table view (not a custom query or a summary).
    public var canEditActiveTable: Bool {
        guard isEditing(appVM?.activeDocEntry), let vm = appVM?.activeTableVM else { return false }
        return ineligibleReason(table: vm.tableName) == nil
            && !vm.isCustomBanquetQuery && vm.displayKind != .summary
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
        editingNewCell = nil
        markedRowIDs = []
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

    /// For callers that changed `session.buffer` directly.
    public func noteBufferChanged() { revision += 1 }

    public func undo() { if session?.buffer.undo() == true { revision += 1 } }
    public func redo() { if session?.buffer.redo() == true { revision += 1 } }

    public func revert() {
        session?.buffer.revert()
        editingCell = nil
        editingNewCell = nil
        markedRowIDs = []
        revision += 1
        UILog.event("edit", "revert")
    }

    // MARK: Row operations (docs/HighRepEdit.md)

    /// Stages an empty new row and opens its first editable cell.
    @discardableResult
    public func newRow() -> Bool {
        guard canEditActiveTable, let vm = appVM?.activeTableVM else { return false }
        let table = vm.tableName
        let id = session?.buffer.insertRow(table: table) ?? 0
        guard id != 0 else { return false }
        revision += 1
        let first = vm.columns.firstIndex { Self.isInsertable($0) } ?? 0
        editingNewCell = (id: id, col: first)
        revealNewRowsToken += 1
        UILog.event("edit", "new row", ["table": table, "tempID": "\(id)", "pending": "\(pendingCount)"])
        return true
    }

    /// Rowid aliases are assigned by SQLite; they are never typed in.
    static func isInsertable(_ c: Column) -> Bool {
        !(c.pk && c.pkIndex == 1 && c.type.uppercased() == "INTEGER")
    }

    /// Rows a row operation applies to: the ⌘-marked rows, else the selected row.
    private func targetIndices(page: Page) -> [Int] {
        if !markedRowIDs.isEmpty {
            return page.rowIDs.indices.filter { markedRowIDs.contains(page.rowIDs[$0]) }
        }
        if let r = appVM?.selectedRowIndex, r >= 0, r < page.rows.count { return [r] }
        return []
    }

    /// Stages the target rows for deletion, as one undo step per row.
    @discardableResult
    public func deleteSelectedRows() -> Int {
        guard canEditActiveTable, let vm = appVM?.activeTableVM, let page = vm.currentPage,
              page.rowKeyed else { return 0 }
        let idx = targetIndices(page: page).filter { $0 < page.rowIDs.count }
        for r in idx {
            var original: [String: SQLiteValue] = [:]
            for (c, col) in page.columns.enumerated() where c < page.rows[r].count { original[col.name] = page.rows[r][c] }
            session?.buffer.deleteRow(table: page.table, rowID: page.rowIDs[r], original: original)
        }
        markedRowIDs = []
        if !idx.isEmpty { revision += 1 }
        UILog.event("edit", "delete rows", ["count": "\(idx.count)", "pending": "\(pendingCount)"])
        return idx.count
    }

    /// Stages a copy of the selected row as a new row. Clipped cells are fetched whole first;
    /// BLOB cells cannot be copied and are left to their default.
    public func duplicateSelectedRow() async {
        guard canEditActiveTable, let vm = appVM?.activeTableVM, let page0 = vm.currentPage,
              page0.rowKeyed, let r = targetIndices(page: page0).first, r < page0.rows.count else { return }
        guard await vm.resolveFullValues(row: r), let page = vm.currentPage, r < page.rows.count else {
            appVM?.errorMessage = "Could not load the full row to duplicate it."
            return
        }
        var values: [String: SQLiteValue] = [:]
        for (c, col) in page.columns.enumerated() where c < page.rows[r].count {
            let v = page.rows[r][c]
            if !Self.isInsertable(col) || v.isBlob || v.isPartial { continue }
            values[col.name] = v
        }
        _ = session?.buffer.insertRow(table: page.table, values: values)
        revision += 1
        revealNewRowsToken += 1
        UILog.event("edit", "duplicate row", ["table": page.table, "row": "\(r)", "pending": "\(pendingCount)"])
    }

    /// Stages `text` into a cell of a pending new row (coerced by affinity, rule 6).
    public func stageNewRowCell(id: Int64, column: Column, text: String) -> String? {
        switch CellCoercion.parse(text, for: column) {
        case .failure(let e): return e.localizedDescription
        case .success(let v): setNewRow(id, column, v); return nil
        }
    }

    public func stageNewRowNull(id: Int64, column: Column) -> String? {
        switch CellCoercion.null(for: column) {
        case .failure(let e): return e.localizedDescription
        case .success(let v): setNewRow(id, column, v); return nil
        }
    }

    /// Clears a new-row cell so the column default applies.
    public func clearNewRowCell(id: Int64, column: Column) {
        session?.buffer.setNewRowValue(id: id, column: column.name, value: nil)
        revision += 1
    }

    public func stageEmptyString(table: String, rowID: Int64, column: Column, original: SQLiteValue) -> String? {
        switch CellCoercion.emptyString(for: column) {
        case .failure(let e): return e.localizedDescription
        case .success(let v): put(table, rowID, column, original, v); return nil
        }
    }

    private func setNewRow(_ id: Int64, _ column: Column, _ value: SQLiteValue) {
        session?.buffer.setNewRowValue(id: id, column: column.name, value: value)
        revision += 1
        UILog.event("edit", "stage new row cell", ["tempID": "\(id)", "col": column.name])
    }

    // MARK: Commit

    @discardableResult
    public func commit() -> Bool {
        guard let s = session, isDirty else { return true }
        do {
            try s.commit()
            revision += 1
            editingCell = nil
            editingNewCell = nil
            markedRowIDs = []
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
