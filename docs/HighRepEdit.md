# HighRepEdit — Navicat-style table editing for sqlswift

Status: phases 1–2 implemented; phase 3 done except multi-cell paste and a form view for new rows; phase 4 (WITHOUT ROWID) not started.

## Context

Editing today (`Editor.swift`, `EditViewModel`, `VirtualizedGridView`) is single-cell
`UPDATE` only: ⌥⌘E session, staged buffer, Commit/Revert, undo/redo, optimistic
concurrency. Navicat's grid workflow is broader: add/delete/duplicate rows, multi-cell
selection, copy/paste, set NULL/empty, a form view, row-state colouring, Apply/Discard
toolbar, and a preview of the SQL that will run. Goal: match that grid workflow
(not DDL / design-table) without touching the Banquet bar.

Decisions made with the user:
- **Row ops allowed.** INSERT/DELETE are permitted *only inside an edit session*, parameterised,
  issued from the staged buffer in the one commit transaction. Still no DDL, no
  `writable_schema`, no user-supplied write SQL; the console stays SELECT-only.
- **Target = grid workflow**, not full Navicat (no auto-commit toggle, no design-table).
  WITHOUT ROWID tables are added in phase 4 (PK-keyed editing).

## Banquet bar protection — hard guardrails (non-negotiable)

Any change violating these is rejected in review. They restate BanquetEditStyle rules 2, 3, 11
and add enforcement.

1. **Zero URL impact.** No edit feature reads, writes, parses, or appends to the Banquet URL.
   Edit state (new rows, deleted rows, selection, form view, SQL preview) is host chrome.
2. **No new controls inside `BanquetBarView`.** Its only edit-related content stays the existing
   `editBadge` (`EDIT` / `EDIT · n`). New toolbar, buttons, and panels live in a separate
   `EditToolbarView` strip and the status bar. `BanquetBarView.swift` should end with a
   diff limited to (at most) the badge's count wording.
3. **Focus/keyboard isolation.** Every new shortcut handler (delete row, duplicate, paste, ⌘N, etc.)
   must no-op when `appVM.isBanquetBarEditing` is true, matching the existing guard at
   `VirtualizedGridView.swift:76`. ⌘Z/⇧⌘Z and ⌘C/⌘V must reach the bar's text field when it has focus.
4. **Navigation neutrality.** Sort/filter/page/table switches via the bar keep working while dirty and
   never discard pending row ops. Pending state is keyed independently of page contents.
5. **Bar ⇄ grid cases stay green.** `Tests/SQLDocAppTests/banquet-ui-cases.json` runs unchanged under
   `make ui-test` and `make ui-e2e`, plus new cases that run with edit mode on and pending rows
   present, asserting `banquetURL` is identical to the non-edit URL.
6. **No main-thread waits, no OFFSET scrolling, no full scans.** Row ops must not alter keyset paging
   (principles 2, 3, 5). Pending rows are rendered from the buffer, never merged into `Page` queries.

## Design

### Engine (`SQLDocCore/Engine/Editor.swift`)
- Generalise `CellEdit` into an `EditOp` enum: `.update(CellEdit)`, `.insert(NewRow)`, `.delete(table, rowID, originalRow)`.
  `NewRow` has a client-side temp id (negative Int64) and `[column: SQLiteValue]`.
- `EditBuffer` keeps the same keyed-by-(table,rowid) model; add `newRows` and `deletedRows`; undo/redo covers all op kinds
  (one stack, same `Action` shape). Editing a cell of a new row mutates the `NewRow`; deleting a new row just drops it.
  Deleting a row drops its pending cell edits.
- `EditSession.commit()` stays one `BEGIN IMMEDIATE … COMMIT`. Order: updates, deletes, inserts. Statements:
  - `DELETE FROM t WHERE rowid = ?` guarded by a row-equality check against `originalRow` (same optimistic rule 9, whole-row).
  - `INSERT INTO t (cols…) VALUES (?…)` with only columns the user set; DB defaults, autoincrement and NOT NULL apply.
    Reject at stage time if a NOT NULL column with no default is unset.
  - Zero rows affected → rollback + conflict naming the row, as today.
- `EditSession.sqlPreview() -> [String]`: renders the exact statements (with bound values inlined for display only, never executed).
- Duplicate row = `.insert` seeded from a fully fetched source row (use `Doc.cellValues` / `TableViewModel.resolveFullValues`; clipped
  `textPrefix` must be resolved first, principle 6). INTEGER PRIMARY KEY is left unset so SQLite assigns it.
- Eligibility is unchanged in phases 1–3 (base tables with rowid); phase 4 adds WITHOUT ROWID tables.
  BLOB cells still read-only except "set NULL".

### Coercion
- Extend `CellCoercion` with an "empty string" action (Navicat's *Set to Empty String*) alongside explicit NULL; empty text
  still never means NULL implicitly. Reuse `CellCoercion.parse` for paste.

### App layer
- `EditViewModel`: add `insertRow(table:)`, `duplicateRows(...)`, `deleteRows(...)`, `pasteBlock(...)`, `sqlPreview`; bump `revision` as today.
  New `selection: Set<RowKey>` model (multi-row, shift/⌘-click) owned here, not in the URL layer.
- `VirtualizedGridView` / `GridHeaderView`:
  - Row-state visuals using `ColorToken`s added to `config/seed.sql`: modified cell (exists), **new row**, **deleted row** (strike + tint).
  - Pending new rows render in a footer region below the loaded page ("new row" strip, Navicat-style), outside page/keyset logic.
  - Multi-cell/row selection, ⌘C copy (TSV), ⌘V paste into selection → one staged batch (one undo step).
  - Context menu: Set NULL, Set Empty String, Duplicate Row, Delete Row, Copy as…
  - Return/Tab behaviour from rule 5 unchanged; Tab off the last cell of the last row does *not* auto-create a row (explicit ⌘N only, avoids accidental inserts).
- New `EditToolbarView` (below the bar, only in edit mode): `+ Row`, `− Row`, `Duplicate`, `Apply`, `Discard`, `SQL…` (sheet previewing
  `sqlPreview`). `StatusBarView` keeps its pending count and gains new/deleted counts.
- `RowDetailPanel` / `DataInspectorView` become the form view: edit all columns of the selected row (and fill a new row) staging through
  the same `EditViewModel`.
- Dirty guard (rule 11) extended: close/leave with any pending op still asks Commit / Discard / Cancel.
- Keybindings added as rows in `config/seed.sql` (`make generate`): new row, delete row, duplicate row, SQL preview; no collisions with existing `mod+z/s/alt+e`.

### Docs
- Update CLAUDE.md principle 1 and `docs/BanquetEditStyle.md` (scope line, rules 4, 8, 13) to permit session-scoped INSERT/DELETE,
  add rules for new/deleted rows and the SQL preview, and add the bar guardrails above as a normative rule.

## Phases
1. **Engine**: `EditOp`, buffer, commit (delete/insert), `sqlPreview`, tests.
2. **VM + grid**: selection, delete/duplicate/insert, state visuals, paste, toolbar, dirty guard.
3. **Form view + SQL sheet + Navicat polish** (copy-as, set-empty), docs update.
4. **PK-keyed editing (WITHOUT ROWID)** — see below.
Each phase is shippable and ends with the bar regression check.

### Phase 4: PK-keyed editing

Why: a `WITHOUT ROWID` table has no `rowid`, but always has a primary key, so the PK is a
stable row identity. Rowid tables keep using `rowid` (stronger than matching on all columns,
and unaffected by duplicate rows).

- **Row identity.** Replace the `Int64` rowid in buffer keys and `EditOp` with a `RowKey`:
  `.rowid(Int64)` or `.pk([SQLiteValue])` (values in `Column.pkIndex` order, composite keys supported).
  `Page` must carry the PK values per row for `WITHOUT ROWID` tables (it already tracks PK values for
  keyset paging, `Page.swift:204`), so no extra query is needed.
- **Statements.** For PK-keyed tables:
  `UPDATE t SET c = ? WHERE pk1 IS ? AND pk2 IS ? AND c IS ?` and
  `DELETE FROM t WHERE pk1 IS ? AND …`. The optimistic guards (rule 9) and the zero-rows-affected
  rollback are unchanged. `INSERT` is unchanged except that the PK columns are required
  (they are NOT NULL by definition in a WITHOUT ROWID table), checked at stage time.
- **PK cells.** Editing a PK value is allowed for PK-keyed tables (Navicat allows it) but the
  edit is staged as an `UPDATE … SET pk = ? WHERE pk IS <original>`. The grid keeps the row's
  original `RowKey` for identity until commit, then reloads. Reject at stage time if the new key
  collides with another row on the loaded page; the database remains the final arbiter (a UNIQUE
  failure rolls the whole transaction back).
- **Eligibility.** `EditSession.ineligibleReason` stops rejecting `!hasRowID`; it rejects only
  views, virtual tables, and a WITHOUT ROWID table whose PK columns can't be read (should not occur).
  Update `docs/BanquetEditStyle.md` rule 4 accordingly.
- **Edge cases to test.** Composite PK; PK containing NULL-able legacy columns (SQLite permits NULL in
  non-INTEGER PKs of rowid tables, so rowid tables never switch to PK keying); TEXT PKs with
  clipped values (resolve full value first, principle 6); BLOB PK (read-only, refuse); a PK change that
  collides; two edits to the same PK-keyed row, one of which changes the PK.
- **Bar impact.** None: identity is internal to the edit buffer and never appears in the URL
  (guardrail 1). Keyset paging is unchanged.
- **Verification.** `make test` cases for each edge case above; `make ui-test` / `make ui-e2e` with a
  WITHOUT ROWID fixture added to `testdata`/`scripts/make_testdata.sh`; the existing banquet cases
  must stay green.

## Critical files
- `Sources/SQLDocCore/Engine/Editor.swift` (engine)
- `Sources/SQLDocApp/ViewModels/EditViewModel.swift`
- `Sources/SQLDocApp/Views/VirtualizedGridView.swift`, `Components/{GridHeaderView,StatusBarView,RowDetailPanel,DataInspectorView,EditCellField}.swift`
- new `Components/EditToolbarView.swift`
- `config/seed.sql` (colours, keybindings) → `make generate`
- `Sources/SQLDocApp/Views/Components/BanquetBarView.swift` — **read-only target**, badge wording only
- `Tests/SQLDocTests/` (new `EditorTests.swift`), `Tests/SQLDocAppTests/{BanquetUITests.swift,banquet-ui-cases.json}`

## Verification
- `make test`: EditBuffer undo/redo over mixed ops; commit atomicity (a conflict mid-batch rolls back inserts/deletes);
  NOT NULL / default handling; clipped-value refusal; duplicate-row seeding.
- `make ui-test` and `make ui-e2e` (after `make hot`): existing banquet cases unchanged, plus edit-mode cases proving `banquetURL`
  is byte-identical with pending inserts/deletes present, and that bar typing/⌘Z isn't hijacked.
- Manual in dev app: drive via `bin/ui-command.txt`, read `bin/ui-state.json` and `bin/ui.log`; confirm no
  `[perf] main thread stalled` after paste of a large block and after delete of many rows.
- `sh scripts/make_testdata.sh` then edit `stress.db` (~500 MB): insert/delete must stay constant-time to stage and commit.
- `make config-check` after seed changes.
