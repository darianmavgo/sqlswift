import Foundation

// Cell editing. See docs/BanquetEditStyle.md. The only write path in the product:
// parameterised single-cell UPDATEs, issued from a connection that exists only
// while an edit session is open. Doc's own connections stay query_only.

public enum EditError: Error, LocalizedError, Equatable {
    case notEditable(String)
    case invalidValue(String)
    case conflict(table: String, rowID: Int64, column: String)
    case commitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notEditable(let why): return why
        case .invalidValue(let why): return why
        case .conflict(let t, let r, let c):
            return "Row \(r) of \(t) changed since it was loaded (column \(c)). Nothing was saved."
        case .commitFailed(let m): return "Could not save: \(m)"
        }
    }
}

/// One staged change to one cell.
public struct CellEdit: Equatable, Sendable {
    public let table: String
    public let rowID: Int64
    public let column: String
    public let original: SQLiteValue
    public let new: SQLiteValue

    public init(table: String, rowID: Int64, column: String, original: SQLiteValue, new: SQLiteValue) {
        self.table = table; self.rowID = rowID; self.column = column
        self.original = original; self.new = new
    }
}

/// A row staged for INSERT. `id` is a client-side temporary id (always negative) so the
/// grid can address the row before it has a rowid. Only the columns the user set are
/// listed; the rest take the table's defaults at commit.
public struct NewRow: Equatable, Sendable {
    public let table: String
    public let id: Int64
    public var values: [String: SQLiteValue]

    public init(table: String, id: Int64, values: [String: SQLiteValue]) {
        self.table = table; self.id = id; self.values = values
    }
}

/// A row staged for DELETE. `original` is what the grid showed, used as the
/// optimistic-concurrency guard (rule 9) for columns that can be compared.
public struct RowDelete: Equatable, Sendable {
    public let table: String
    public let rowID: Int64
    public let original: [String: SQLiteValue]

    public init(table: String, rowID: Int64, original: [String: SQLiteValue]) {
        self.table = table; self.rowID = rowID; self.original = original
    }
}

/// The staged-edits buffer: cell updates keyed by (table, rowid, column), new rows and
/// deleted rows, with one undo/redo stack across all three. Nothing here touches the
/// database; `EditSession.commit` writes it out.
public final class EditBuffer: @unchecked Sendable {
    private struct Key: Hashable { let table: String; let rowID: Int64; let column: String }
    private struct RowRef: Hashable { let table: String; let rowID: Int64 }

    /// One reversible step. Several changes form one undo step (a delete that also
    /// drops that row's pending cell edits, a paste, ...).
    private enum Change {
        case cell(Key, before: CellEdit?, after: CellEdit?)
        case newRow(Int64, before: NewRow?, after: NewRow?)
        case delete(RowRef, before: RowDelete?, after: RowDelete?)
    }
    private struct Action { let changes: [Change] }

    private let lock = NSLock()
    private var edits: [Key: CellEdit] = [:]
    private var inserts: [Int64: NewRow] = [:]
    private var deletes: [RowRef: RowDelete] = [:]
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []
    private var nextTempID: Int64 = -1

    public init() {}

    /// Everything pending: cell updates + new rows + deleted rows.
    public var count: Int { lock.lock(); defer { lock.unlock() }; return edits.count + inserts.count + deletes.count }
    public var updateCount: Int { lock.lock(); defer { lock.unlock() }; return edits.count }
    public var insertCount: Int { lock.lock(); defer { lock.unlock() }; return inserts.count }
    public var deleteCount: Int { lock.lock(); defer { lock.unlock() }; return deletes.count }
    public var canUndo: Bool { lock.lock(); defer { lock.unlock() }; return !undoStack.isEmpty }
    public var canRedo: Bool { lock.lock(); defer { lock.unlock() }; return !redoStack.isEmpty }

    /// The pending new value for a cell, if any.
    public func pending(table: String, rowID: Int64, column: String) -> SQLiteValue? {
        lock.lock(); defer { lock.unlock() }
        return edits[Key(table: table, rowID: rowID, column: column)]?.new
    }

    public func isDeleted(table: String, rowID: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deletes[RowRef(table: table, rowID: rowID)] != nil
    }

    /// Stage `edit`. Re-editing a cell keeps its first-seen original; setting a cell
    /// back to that original drops the entry (rule 7). Ignored for a row staged for delete.
    public func stage(_ edit: CellEdit) {
        stageBatch([edit])
    }

    /// Stage several cell edits as one undo step (paste, fill).
    public func stageBatch(_ batch: [CellEdit]) {
        lock.lock(); defer { lock.unlock() }
        var changes: [Change] = []
        for edit in batch {
            if deletes[RowRef(table: edit.table, rowID: edit.rowID)] != nil { continue }
            let key = Key(table: edit.table, rowID: edit.rowID, column: edit.column)
            let before = edits[key] // edits apply as we go, so a batch may touch one cell twice
            let original = before?.original ?? edit.original
            let after: CellEdit? = edit.new == original
                ? nil
                : CellEdit(table: edit.table, rowID: edit.rowID, column: edit.column, original: original, new: edit.new)
            if before == after { continue }
            let c = Change.cell(key, before: before, after: after)
            changes.append(c)
            apply(c, forward: true)
        }
        record(changes)
    }

    /// Stages a new row and returns its temporary (negative) id.
    @discardableResult
    public func insertRow(table: String, values: [String: SQLiteValue] = [:]) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextTempID
        nextTempID -= 1
        let row = NewRow(table: table, id: id, values: values)
        let c = Change.newRow(id, before: nil, after: row)
        apply(c, forward: true)
        record([c])
        return id
    }

    /// Sets (or, with nil, unsets so the database default applies) one column of a new row.
    public func setNewRowValue(id: Int64, column: String, value: SQLiteValue?) {
        lock.lock(); defer { lock.unlock() }
        guard let before = inserts[id] else { return }
        var after = before
        after.values[column] = value
        if after == before { return }
        let c = Change.newRow(id, before: before, after: after)
        apply(c, forward: true)
        record([c])
    }

    /// A new row's staged values, or nil if `id` is not a pending new row.
    public func newRow(id: Int64) -> NewRow? {
        lock.lock(); defer { lock.unlock() }
        return inserts[id]
    }

    /// Pending new rows for a table, oldest first.
    public func newRows(table: String) -> [NewRow] {
        lock.lock(); defer { lock.unlock() }
        return inserts.values.filter { $0.table == table }.sorted { $0.id > $1.id }
    }

    /// Stage a row for deletion. A pending new row (negative id) is simply dropped; a stored
    /// row also drops its pending cell edits. One undo step restores both.
    public func deleteRow(table: String, rowID: Int64, original: [String: SQLiteValue]) {
        lock.lock(); defer { lock.unlock() }
        if rowID < 0 {
            guard let nr = inserts[rowID], nr.table == table else { return }
            let c = Change.newRow(rowID, before: nr, after: nil)
            apply(c, forward: true)
            record([c])
            return
        }
        let ref = RowRef(table: table, rowID: rowID)
        guard deletes[ref] == nil else { return }
        var changes: [Change] = edits
            .filter { $0.key.table == table && $0.key.rowID == rowID }
            .map { Change.cell($0.key, before: $0.value, after: nil) }
        changes.append(.delete(ref, before: nil, after: RowDelete(table: table, rowID: rowID, original: original)))
        for c in changes { apply(c, forward: true) }
        record(changes)
    }

    @discardableResult
    public func undo() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = undoStack.popLast() else { return false }
        for c in a.changes.reversed() { apply(c, forward: false) }
        redoStack.append(a)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = redoStack.popLast() else { return false }
        for c in a.changes { apply(c, forward: true) }
        undoStack.append(a)
        return true
    }

    public func revert() {
        lock.lock(); defer { lock.unlock() }
        edits.removeAll(); inserts.removeAll(); deletes.removeAll()
        undoStack.removeAll(); redoStack.removeAll()
        nextTempID = -1
    }

    /// Deterministic order for commit and display.
    public func all() -> [CellEdit] {
        lock.lock(); defer { lock.unlock() }
        return edits.values.sorted {
            ($0.table, $0.rowID, $0.column) < ($1.table, $1.rowID, $1.column)
        }
    }

    public func allDeletes() -> [RowDelete] {
        lock.lock(); defer { lock.unlock() }
        return deletes.values.sorted { ($0.table, $0.rowID) < ($1.table, $1.rowID) }
    }

    /// New rows in creation order.
    public func allNewRows() -> [NewRow] {
        lock.lock(); defer { lock.unlock() }
        return inserts.values.sorted { $0.id > $1.id }
    }

    private func record(_ changes: [Change]) {
        guard !changes.isEmpty else { return }
        undoStack.append(Action(changes: changes))
        redoStack.removeAll()
    }

    private func apply(_ change: Change, forward: Bool) {
        switch change {
        case .cell(let key, let before, let after):
            let v = forward ? after : before
            if let v { edits[key] = v } else { edits.removeValue(forKey: key) }
        case .newRow(let id, let before, let after):
            let v = forward ? after : before
            if let v { inserts[id] = v } else { inserts.removeValue(forKey: id) }
        case .delete(let ref, let before, let after):
            let v = forward ? after : before
            if let v { deletes[ref] = v } else { deletes.removeValue(forKey: ref) }
        }
    }
}

/// Turns the text a user typed into a value, by column affinity (rule 6).
public enum CellCoercion {
    public static func parse(_ text: String, for column: Column) -> Result<SQLiteValue, EditError> {
        let t = column.type.uppercased()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if t.contains("INT") {
            guard let v = Int64(trimmed) else {
                return .failure(.invalidValue("“\(text)” is not a whole number (column \(column.name))."))
            }
            return .success(.integer(v))
        }
        if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") {
            guard let v = Double(trimmed), v.isFinite else {
                return .failure(.invalidValue("“\(text)” is not a number (column \(column.name))."))
            }
            return .success(.real(v))
        }
        if column.isNumeric { // NUMERIC / DECIMAL / BOOLEAN: integer if it looks like one
            if let i = Int64(trimmed) { return .success(.integer(i)) }
            if let d = Double(trimmed), d.isFinite { return .success(.real(d)) }
            return .failure(.invalidValue("“\(text)” is not a number (column \(column.name))."))
        }
        return .success(.text(text))
    }

    /// NULL is explicit, and refused for NOT NULL columns.
    public static func null(for column: Column) -> Result<SQLiteValue, EditError> {
        column.notNull
            ? .failure(.invalidValue("Column \(column.name) does not allow NULL."))
            : .success(.null)
    }

    /// Navicat's "Set to Empty String": explicit, like NULL. Only text columns take it; a
    /// numeric column would store '' as text and break its affinity.
    public static func emptyString(for column: Column) -> Result<SQLiteValue, EditError> {
        column.isNumeric
            ? .failure(.invalidValue("Column \(column.name) is numeric; an empty string is not a valid value."))
            : .success(.text(""))
    }

    /// Raw text shown in the inline editor.
    public static func editorText(for value: SQLiteValue) -> String {
        switch value {
        case .null: return ""
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        case .text(let s): return s
        // The grid resolves the full value before opening an editor on it.
        case .textPrefix(let s, _): return s
        case .blob: return ""
        }
    }
}

/// An open edit session on one document: a read-write connection plus a buffer.
public final class EditSession: @unchecked Sendable {
    public let doc: Doc
    public let buffer = EditBuffer()
    private let conn: SQLiteConnection

    /// Opens the read-write connection. Refused for immutable documents, which
    /// ignore writes from other connections (rule 1).
    public init(doc: Doc) throws {
        if doc.options.isImmutable {
            throw EditError.notEditable("This database was opened immutable (read-only volume or locked). Reopen it normally to edit.")
        }
        guard FileManager.default.isWritableFile(atPath: doc.path) else {
            throw EditError.notEditable("This file is not writable.")
        }
        do {
            self.conn = try SQLiteConnection(path: doc.path, readOnly: false)
        } catch {
            throw EditError.notEditable("Could not open for writing: \(error.localizedDescription)")
        }
        self.doc = doc
    }

    public func close() { conn.close() }

    /// Why `table` cannot be edited, or nil if it can (rule 4).
    public static func ineligibleReason(doc: Doc, table: String) -> String? {
        guard let t = doc.table(named: table) else { return "Unknown table." }
        if t.isView { return "Views are read-only." }
        if t.isVirtual { return "Virtual tables are read-only." }
        if !t.hasRowID { return "WITHOUT ROWID tables are read-only." }
        return nil
    }

    /// Columns a new row must supply: NOT NULL, no default, not a rowid alias.
    /// Empty when the row can be inserted (rule 6).
    public func missingRequiredColumns(table: String, values: [String: SQLiteValue]) -> [String] {
        guard let cols = try? conn.query("PRAGMA table_info(\(Doc.quoteIdent(table)))") else { return [] }
        // table_info: cid, name, type, notnull, dflt_value, pk
        return cols.compactMap { r -> String? in
            guard r.count >= 6, let name = r[1].textValue else { return nil }
            let notNull = (r[3].intValue ?? 0) != 0
            let hasDefault = !r[4].isNull
            let isRowidAlias = (r[5].intValue ?? 0) == 1 && (r[2].textValue ?? "").uppercased() == "INTEGER"
            if notNull && !hasDefault && !isRowidAlias && values[name] == nil { return name }
            return nil
        }
    }

    /// The statements `commit()` would run, in order, with values inlined for display only.
    /// Never executed: commit binds parameters.
    public func sqlPreview() -> [String] {
        var out: [String] = []
        for e in buffer.all() {
            let col = Doc.quoteIdent(e.column)
            out.append("UPDATE \(Doc.quoteIdent(e.table)) SET \(col) = \(EditSession.literal(e.new)) WHERE rowid = \(e.rowID) AND \(col) IS \(EditSession.literal(e.original));")
        }
        for d in buffer.allDeletes() {
            let guards = EditSession.deleteGuards(d).map { "\(Doc.quoteIdent($0.column)) IS \(EditSession.literal($0.value))" }
            let tail = (["rowid = \(d.rowID)"] + guards).joined(separator: " AND ")
            out.append("DELETE FROM \(Doc.quoteIdent(d.table)) WHERE \(tail);")
        }
        for n in buffer.allNewRows() {
            let cols = n.values.keys.sorted()
            if cols.isEmpty {
                out.append("INSERT INTO \(Doc.quoteIdent(n.table)) DEFAULT VALUES;")
            } else {
                let names = cols.map(Doc.quoteIdent).joined(separator: ", ")
                let vals = cols.map { EditSession.literal(n.values[$0] ?? .null) }.joined(separator: ", ")
                out.append("INSERT INTO \(Doc.quoteIdent(n.table)) (\(names)) VALUES (\(vals));")
            }
        }
        return out
    }

    /// Writes every pending edit in one transaction (rules 8, 9, 12). Order: updates,
    /// deletes, inserts. Any failure rolls the whole transaction back.
    public func commit() throws {
        let edits = buffer.all()
        let deletes = buffer.allDeletes()
        let inserts = buffer.allNewRows()
        guard !(edits.isEmpty && deletes.isEmpty && inserts.isEmpty) else { return }
        let tables = Set(edits.map(\.table) + deletes.map(\.table) + inserts.map(\.table))
        for t in tables.sorted() {
            if let why = EditSession.ineligibleReason(doc: doc, table: t) { throw EditError.notEditable(why) }
        }
        for e in edits {
            // A clipped original can never satisfy the `IS ?` guard below, and a
            // clipped new value would truncate the cell. Refuse both outright.
            if e.original.isPartial || e.new.isPartial {
                throw EditError.commitFailed("\(e.table).\(e.column) row \(e.rowID): the full cell value was not loaded.")
            }
        }
        for n in inserts {
            for (c, v) in n.values where v.isPartial || v.isBlob {
                throw EditError.commitFailed("New row in \(n.table): column \(c) holds a value that cannot be written.")
            }
            let missing = missingRequiredColumns(table: n.table, values: n.values)
            if !missing.isEmpty {
                throw EditError.invalidValue("New row in \(n.table) needs a value for: \(missing.joined(separator: ", ")).")
            }
        }
        do {
            try conn.exec("BEGIN IMMEDIATE")
        } catch {
            throw EditError.commitFailed(error.localizedDescription)
        }
        do {
            for e in edits {
                let col = Doc.quoteIdent(e.column)
                let sql = "UPDATE \(Doc.quoteIdent(e.table)) SET \(col) = ? WHERE rowid = ? AND \(col) IS ?"
                _ = try conn.query(sql, args: [EditSession.bind(e.new), e.rowID, EditSession.bind(e.original)])
                let changed = try conn.queryRow("SELECT changes()")?.first?.intValue ?? 0
                if changed != 1 { throw EditError.conflict(table: e.table, rowID: e.rowID, column: e.column) }
            }
            for d in deletes {
                let guards = EditSession.deleteGuards(d)
                var sql = "DELETE FROM \(Doc.quoteIdent(d.table)) WHERE rowid = ?"
                var args: [Any] = [d.rowID]
                for g in guards {
                    sql += " AND \(Doc.quoteIdent(g.column)) IS ?"
                    args.append(EditSession.bind(g.value))
                }
                _ = try conn.query(sql, args: args)
                let changed = try conn.queryRow("SELECT changes()")?.first?.intValue ?? 0
                if changed != 1 { throw EditError.conflict(table: d.table, rowID: d.rowID, column: "(row)") }
            }
            for n in inserts {
                let cols = n.values.keys.sorted()
                let sql: String
                var args: [Any] = []
                if cols.isEmpty {
                    sql = "INSERT INTO \(Doc.quoteIdent(n.table)) DEFAULT VALUES"
                } else {
                    let names = cols.map(Doc.quoteIdent).joined(separator: ", ")
                    let marks = Array(repeating: "?", count: cols.count).joined(separator: ", ")
                    sql = "INSERT INTO \(Doc.quoteIdent(n.table)) (\(names)) VALUES (\(marks))"
                    args = cols.map { EditSession.bind(n.values[$0] ?? .null) }
                }
                _ = try conn.query(sql, args: args)
                let changed = try conn.queryRow("SELECT changes()")?.first?.intValue ?? 0
                if changed != 1 { throw EditError.commitFailed("Could not insert a row into \(n.table).") }
            }
            try conn.exec("COMMIT")
        } catch {
            _ = try? conn.exec("ROLLBACK")
            if let e = error as? EditError { throw e }
            throw EditError.commitFailed(error.localizedDescription)
        }
        buffer.revert()
        doc.invalidateCaches() // also refreshes the disk stamp, so our write isn't "external"
    }

    /// Columns of a deleted row that can guard the DELETE. Clipped text and BLOBs cannot be
    /// compared by value, so they are left out; the rowid plus the rest still pins the row.
    private static func deleteGuards(_ d: RowDelete) -> [(column: String, value: SQLiteValue)] {
        d.original
            .filter { !$0.value.isPartial && !$0.value.isBlob }
            .sorted { $0.key < $1.key }
            .map { (column: $0.key, value: $0.value) }
    }

    /// SQL literal for the preview only.
    private static func literal(_ v: SQLiteValue) -> String {
        switch v {
        case .null: return "NULL"
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        case .text(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case .textPrefix(let s, _): return "'" + s.replacingOccurrences(of: "'", with: "''") + "…' /* clipped */"
        case .blob(let n): return "x'…' /* \(n) bytes */"
        }
    }

    private static func bind(_ v: SQLiteValue) -> Any {
        switch v {
        case .null, .blob: return NSNull()
        case .integer(let i): return i
        case .real(let d): return d
        case .text(let s): return s
        case .textPrefix: return NSNull() // unreachable: commit() rejects partial values
        }
    }
}
