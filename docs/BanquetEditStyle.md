# Banquet Edit Style

**Status: experimental (sqlswift only).** Every other Banquet standard describes
*viewing*. This one describes how an interactive client lets a user change cell values
in a SQLite file. It does **not** change the Banquet URL grammar. If it holds up it can
be promoted to `banquet/standards/`.

Scope of this revision: **updating existing cell values only.** No row insert/delete, no
schema changes, no user-supplied write SQL.

## Conventions & Rules

1. **Opt-in session.** Documents open read-only. Edit mode is an explicit, per-document
   session. It MUST NOT start implicitly (not from a URL, a paste, or a drop).
2. **URL neutrality.** Edit mode MUST NOT alter the Banquet URL. The bar shows the same
   canonical view URL in and out of edit mode (Bar Style rule 3 still holds). Edit state
   is host chrome, not address.
3. **Visible state.** While editing, an `EDIT` badge is shown, and the number of pending
   edits whenever it is above zero.
4. **Eligibility.** Only base tables with a `rowid` are editable (not views, virtual
   tables, or `WITHOUT ROWID` tables). Ineligible tables stay read-only and the client
   states why. BLOB cells and the rowid itself are not editable.
5. **Cell editing.** Double-click, or Return on the selected cell, opens an inline editor
   showing the *raw* value (Grid Style rule 3, raw view), never the smart-formatted one.
   Return stages the edit and moves down; Tab stages and moves right; Esc cancels.
6. **Typing and NULL.** Input is coerced by column affinity: INTEGER to a 64-bit integer,
   REAL to a double, anything else to text. A value that does not parse is rejected
   inline and not staged. NULL is set explicitly (context menu), never by empty text.
   NOT NULL columns refuse NULL.
7. **Staged buffer.** Edits are held in memory keyed by (table, rowid, column). Pending
   cells render tinted with the new value. Editing a cell back to its original value
   drops the pending entry.
8. **Commit / Revert.** Commit writes every pending edit in one `BEGIN IMMEDIATE …
   COMMIT` transaction. On any failure the whole transaction rolls back and nothing is
   applied. Revert discards the buffer.
9. **Optimistic concurrency.** Each `UPDATE` carries `AND col IS <original>`. If a row
   changed underneath (zero rows affected) the commit aborts and names the cell.
10. **Undo / Redo.** Undo and redo walk the staged buffer, not the database. A commit
    clears the stack.
11. **Navigation while dirty.** Sorting, filtering, paging and in-table Banquet
    navigation are allowed; pending edits are keyed by rowid and survive. Pending values
    do not affect sort order until committed. Closing the document, opening another file
    or leaving edit mode with pending edits asks Commit / Discard / Cancel.
12. **After commit.** The page reloads, counts and column caches invalidate, and the
    client MUST NOT report its own write as an external change on disk.
13. **Guarantees retained.** Outside an edit session no write path exists. Inside one,
    only parameterised single-cell `UPDATE` statements are issued: no DDL, no
    user-supplied SQL. The query console remains SELECT-only.

## sqlswift bindings

| Rule | Where |
|---|---|
| 1, 13 | `Doc.beginEditing()` opens a separate read-write connection; the foreground/background connections stay `query_only` |
| 4, 6, 7, 9, 10 | `SQLDocCore/Engine/Editor.swift` (`EditBuffer`, `CellCoercion`, `Doc.commit`) |
| 2, 3, 5, 11 | `EditViewModel`, `VirtualizedGridView`, `StatusBarView` |
| keys | ⌥⌘E toggle, ⌘S commit, ⌘Z / ⇧⌘Z undo/redo (rows in `config/seed.sql`) |
