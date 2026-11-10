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

/// The staged-edits buffer: keyed by (table, rowid, column), with undo/redo.
public final class EditBuffer: @unchecked Sendable {
    private struct Key: Hashable { let table: String; let rowID: Int64; let column: String }
    private struct Action { let key: Key; let before: CellEdit?; let after: CellEdit? }

    private let lock = NSLock()
    private var edits: [Key: CellEdit] = [:]
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []

    public init() {}

    public var count: Int { lock.lock(); defer { lock.unlock() }; return edits.count }
    public var canUndo: Bool { lock.lock(); defer { lock.unlock() }; return !undoStack.isEmpty }
    public var canRedo: Bool { lock.lock(); defer { lock.unlock() }; return !redoStack.isEmpty }

    /// The pending new value for a cell, if any.
    public func pending(table: String, rowID: Int64, column: String) -> SQLiteValue? {
        lock.lock(); defer { lock.unlock() }
        return edits[Key(table: table, rowID: rowID, column: column)]?.new
    }

    /// Stage `edit`. Re-editing a cell keeps its first-seen original; setting a cell
    /// back to that original drops the entry (rule 7).
    public func stage(_ edit: CellEdit) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(table: edit.table, rowID: edit.rowID, column: edit.column)
        let before = edits[key]
        let original = before?.original ?? edit.original
        let after: CellEdit? = edit.new == original
            ? nil
            : CellEdit(table: edit.table, rowID: edit.rowID, column: edit.column, original: original, new: edit.new)
        if before == after { return }
        apply(key, after)
        undoStack.append(Action(key: key, before: before, after: after))
        redoStack.removeAll()
    }

    @discardableResult
    public func undo() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = undoStack.popLast() else { return false }
        apply(a.key, a.before)
        redoStack.append(a)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = redoStack.popLast() else { return false }
        apply(a.key, a.after)
        undoStack.append(a)
        return true
    }

    public func revert() {
        lock.lock(); defer { lock.unlock() }
        edits.removeAll(); undoStack.removeAll(); redoStack.removeAll()
    }

    /// Deterministic order for commit and display.
    public func all() -> [CellEdit] {
        lock.lock(); defer { lock.unlock() }
        return edits.values.sorted {
            ($0.table, $0.rowID, $0.column) < ($1.table, $1.rowID, $1.column)
        }
    }

    private func apply(_ key: Key, _ edit: CellEdit?) {
        if let edit { edits[key] = edit } else { edits.removeValue(forKey: key) }
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

    /// Writes every pending edit in one transaction (rules 8, 9, 12).
    public func commit() throws {
        let edits = buffer.all()
        guard !edits.isEmpty else { return }
        for e in edits {
            if let why = EditSession.ineligibleReason(doc: doc, table: e.table) { throw EditError.notEditable(why) }
            // A clipped original can never satisfy the `IS ?` guard below, and a
            // clipped new value would truncate the cell. Refuse both outright.
            if e.original.isPartial || e.new.isPartial {
                throw EditError.commitFailed("\(e.table).\(e.column) row \(e.rowID): the full cell value was not loaded.")
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
            try conn.exec("COMMIT")
        } catch {
            _ = try? conn.exec("ROLLBACK")
            if let e = error as? EditError { throw e }
            throw EditError.commitFailed(error.localizedDescription)
        }
        buffer.revert()
        doc.invalidateCaches() // also refreshes the disk stamp, so our write isn't "external"
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
