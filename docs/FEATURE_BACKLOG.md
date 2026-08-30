# sqlswift — feature backlog from prior projects

A scan of every SQLite-viewer project in `~/Documents` and `~/Documents/Archive`,
pulling out features you've already designed or shipped once and will likely want
in sqlswift. Each item notes where it came from.

Projects surveyed:

| Project | Stack | What it was |
|---|---|---|
| **sqldoc** | Go + Cgo + WebView + vanilla-JS grid | Direct predecessor. Localhost HTTP + 900-line JS virtual grid. The `FinishPort.html` / `RefactorSwift.html` in that repo are the port plan for sqlswift. |
| **sqlitewebpage** | Go, AG Grid, `RenderDatabase → self-contained .html` | "Share a SQLite file the way you share a web page." Rich `_head` metadata engine. |
| **sqliter / sqliteplutogrid** | Flutter + `trina_grid` + `macos_ui` | Native-feel viewer with Flight3/Banquet remote sync, file browser, format conversion, Power2 sampling. `SqlitervsDataflare.md` is a parity roadmap. |
| **wailssqliter** | Wails (Go + React) | Early "no HTTP, use bindings" native attempt. |
| **mksqlite** | Go | Ingestion engine: any file → SQLite. Not a viewer, but the natural "open a CSV" backend. |

---

## Already in sqlswift (baseline)

Keyset scrolling · estimate-then-exact row count · background column-width
sampling · O(1) rowid bounds (two scalar subqueries) · incremental all-column
find with live progress · column-scoped find · stable keyset sort + numeric sort ·
column resize / double-click auto-fit / persisted widths · multi-table gallery ·
data inspector (JSON pretty-print, epoch-date detection, hex/binary) · row/cell
context menus · copy row as JSON/TSV/CSV · CSV export · skeleton loading · busy
overlay · fast/slow query timing badge · manual light/dark override · zoom ·
recents · drag-drop and paste-path open · `_style`/`_head`/`_nav` self-describing
tables · `info` and `bench` CLI · immutable open mode.

---

> **Status (commits `97fea9e`, `284e468`, `1ca240d`):** Tier 1 and Tier 2 are
> implemented except where noted `[deferred]`. `[deferred]` items need an
> external library (Excel/PDF) or are larger follow-ups (regex find, column
> drag-reorder).

## Tier 1 — you've built or fully specced these more than once

### SQL editor / query console  ✅
A second tab: monospace editor, syntax highlighting, `⌘↵` runs, results render in
the same grid. Read-only `SELECT` only fits sqlswift's "not an editor" stance.
*Source: Sqliter `SqlitervsDataflare.md` §3.7 and `CLIENT_DESIGN_DOC.md` §6
("Saved Queries"), listed as the top parity gap vs Dataflare every time.*

### Per-column filter bar  ✅
A filter row under the header — one field per column, debounced, issues
`WHERE "col" LIKE ?` (or `=`, `>`, `<`, `IS NULL`). Distinct from find: find
locates, filter narrows the result set.
*Source: Sqliter `SqlitervsDataflare.md` §3.5, `UpdatesFeb20.md`; Dataflare parity.*

### Full schema view  ✅
Column **type, NOT NULL, PK, default**, plus **foreign keys** (`PRAGMA
foreign_key_list`) and **indexes** (`PRAGMA index_list`), and the raw
`CREATE TABLE` DDL. Today sqlswift shows column name + type only.
*Source: sqldoc `schema.go` (partial), Sqliter `SqlitervsDataflare.md` §3.6,
Dataflare parity. `RefactorSwift.html` lists "Schema View" as a subsystem.*

### Table sidebar (vs the titlebar picker)  ✅
A collapsible left list of tables/views, row counts inline, click to switch.
sqldoc's JS frontend had this; the Swift port replaced it with a menu picker and
`FinishPort.html` flags that as an open "structural style deviation."
*Source: sqldoc frontend, `FinishPort.html` "Sidebar vs Picker". (Sqliter went
the other way — "no sidebar, it belongs in the menu bar" — so this is a real
decision, not a given.)*

### Open non-SQLite files (CSV / JSON / Excel / Markdown / HTML / PDF / TXT)
Detect a non-DB file on open, convert to a temp `.db`, open that. mksqlite already
does every one of these conversions as a Go library; Sqliter wired the same flow
through Flight3's `/api/convert`. Natural fit: bundle a converter or shell out to
`mksqlite`.
*Source: mksqlite README (all formats), Sqliter `ConversionService` /
`CLIENT_DESIGN_DOC.md` §3.4.*

### Export as a self-contained HTML page  ✅
"Share the table the way you'd share a web page" — one `.html` file, data inlined,
styled from the document's own `_head`. This was the entire point of sqlitewebpage.
*Source: sqlitewebpage `RenderDatabase()`, `render.go`.*

### Richer `_head` / `_style` convention  ✅ (favicon/desc/author/font/bg/text/css/page_size parsed; page_size + HTML export wired)
sqlswift reads `title`, `accent`, `theme`. sqlitewebpage's engine also honours
`description`, `author`, `favicon`, `og:*`, `twitter:*`, `canonical`,
`custom_css`, `head_script`, `page_size`, `font_family`, `bg`/`text` colours,
`base_href`. Worth adopting the ones that make sense natively (`favicon` →
window/dock, `page_size`, `font_family`, `bg`/`text`) and keeping the rest for
the HTML-export path.
*Source: sqlitewebpage `metadata.go` `applyHeadKeyValue`.*

### More export / copy formats  ✅ CSV/TSV/JSON/SQL/Markdown/HTML · Excel [deferred]
Beyond CSV: JSON, TSV, SQL `INSERT` dump, **Markdown table** (for pasting into
GitHub/docs), Excel `.xlsx`. Copy *selection* (not just whole row) in any of these.
*Source: sqldoc copy-row menu (JSON/TSV/CSV already), mksqlite (SQL dump, MD),
Sqliter `CsvExportService`.*

---

## Tier 2 — designed once, clearly wanted

### Dynamic / resizable row height  ✅ (Compact/Regular/Tall + wrap)
Row height is hardcoded `26 * zoom`. Long text needs an auto-expand mode and/or a
drag-to-resize row grip.
*Source: `FinishPort.html` "Dynamic Row Heights" (explicit gap).*

### Smart in-cell formatting  ✅
Render Unix permission bits as `rwxr-xr-x`, epoch seconds/millis as local
date-time, bytes as `1.4 MB` — in the grid, keyed off column name/type, not only
in the inspector. sqlswift already detects epochs in the inspector; push it into
the cell.
*Source: Sqliter `utils/formatters.dart` (`formatPermissions`, epoch), README
"Smart Formatting".*

### Power2 sampling  ✅
One click shows rows at ordinals 1, 2, 4, 8, 16, 32… — a logarithmic spot-check
of a huge table without scrolling. Sqliter's signature original feature.
*Source: Sqliter README "Power2 Analysis", `db_service.dart`.*

### Jump-to-row dialog  ✅ (⌘L)
`⌘L` → type an ordinal or rowid → scroll there. The scrollbar interpolation
exists; this is the keyboard entry point.
*Source: Sqliter `CLIENT_DESIGN_DOC.md` §3.2 "Jump to Row".*

### Find: regex, case-sensitive, whole-cell, FTS5  ✅ case-sensitive + column scope · regex/whole-cell/FTS5 [deferred]
sqldoc's find is substring-only (`CAST(col AS TEXT) LIKE '%q%'`). Add toggles, and
route through an FTS5 table when the document has one.
*Source: `RefactorSwift.html` ("Swift SQLite FTS5 / LIKE streaming query"),
sqldoc `find.go`.*

### Load-progress badge  ✅
"Loaded 100 / 12,400 rows" in the status bar while a background job (count,
sample, find) runs. sqlswift shows the find scan count now; generalize it.
*Source: Sqliter `SqlitervsDataflare.md` §3.10.*

### Persist sort preference per table  ✅
Column widths already persist; sort column/direction should too.
*Source: Sqliter `SqlitervsDataflare.md` §3.9.*

### Blob handling  ✅ (image preview, hex dump, Save…)
sqldoc deliberately never ships blob bytes (web security). A native app can:
show an image blob as a thumbnail/Quick Look, hex-dump a small blob, "save blob
as…". 
*Source: sqldoc README "Safety" (the constraint a native app removes).*

### Column show/hide and reorder  ✅ show/hide + persist · drag-reorder [deferred]
Hide noisy columns, drag to reorder. Persist alongside widths.
*Source: general viewer parity (Dataflare); implied by Sqliter `_optimizeColumns`.*

### Error dialogs, never silent failures  ✅ (export/import/query surfaced)
Sqliter's #1 hard-won lesson: a bad path / bad table name / missing column list
produced a black screen. Every failure path needs a visible `MacosAlertDialog`
equivalent. sqlswift has an error `.alert` for open failures — extend it to
per-table load, find, export.
*Source: Sqliter `SqlitervsDataflare.md` §3.1–3.3, §4.*

---

## Tier 3 — deeper macOS integration (from RefactorSwift.html "Deep Apple Ecosystem")

- **Quick Look extension** — Spacebar-preview a `.db` in Finder (first N rows of
  the first table) without launching the app.
- **Spotlight importer** — index table and column names so a database's schema is
  searchable from Finder.
- **macOS Shortcuts** actions — "export table X from database Y as CSV".
- **Native window tabs** (`⌘T`) and multi-window, Fullscreen / Split View.
- **`fillScreen()` on launch** — the Go launcher forced the window to screen size;
  sqlswift uses SwiftUI defaults. (`FinishPort.html` "Full Screen Startup".)
- **`NSDocumentController` recents** instead of the hand-rolled list — gets the
  system "Open Recent" menu and Dock menu for free. (`RefactorSwift.html`.)
- **App Store / notarized packaging** — standard Xcode scheme vs the current
  Makefile + `lsregister` dance.

---

## Tier 4 — remote / server (real philosophical tension)

sqldoc had these; the Swift port **deliberately dropped them** (`FinishPort.html`:
"permanently losing cross-platform web UI capabilities"). Listed because you built
them twice and may want them back as an optional mode.

- **`serve` mode** — `sqldoc serve file.db` hosts the DB over loopback HTTP,
  prints a URL, launches nothing. Token per session, `Host` header must be
  loopback, blobs never sent. Enables Linux/Windows/remote viewing.
  *Source: sqldoc `cmd/sqldoc`, `internal/server/server.go`, sqlitewebpage
  `cmd/sqldoc-serve`.*
- **Open a database by URL / remote SQLite** — Sqliter's whole Flight3 layer:
  fetch paginated rows from a server, render remote datasets as local tables.
- **Banquet-link protocol** — a URL scheme addressing a dataset (and a subset:
  table, filter) with a **clickable breadcrumb bar** showing the full path of
  what's displayed, each segment navigable.
  *Source: Sqliter `banquet_bar.dart`, `CLIENT_DESIGN_DOC.md` §3.3,
  `UpdatesFeb20.md` §3.*
- **Sync remote DB for offline** — download + cache, "Cached Datasets" manager.
  *Source: Sqliter `flight_service.dart`, README "Sync & Offline".*
- **Filesystem-as-database** — point at a folder, browse it as a table of
  `path / size / mtime / …`; a directory that is a `.db` gets opened, one that
  isn't gets crawled.
  *Source: mksqlite filesystem crawler, Sqliter desktop-mode folder handling.*

---

## Tier 5 — UX polish notes worth keeping

- Breadcrumb / path bar showing the full location of the displayed table, not
  just a filename. (Sqliter)
- Tunable gap between traffic lights and the leading toolbar item; customizable
  title bar. (Sqliter `UpdatesFeb20.md` §2, `banquet_bar.dart`)
- Strip framework cruft (`<>`) from headers — n/a for SwiftUI but the lesson
  (own your header rendering) applies. (Sqliter `UpdatesFeb20.md` §4)
- Emoji as table/branding names — the doc's `_style.title` can be `🍊 Field Data`.
- "Gallery is the default view for a document of a few small lookup tables"
  heuristic — sqlswift has the config knobs (`galleryMaxTableRowEstimate`,
  `galleryMinTables`) but confirm the auto-open logic matches sqldoc's
  `defaultView()` (`galleryMinRows = 50`, `galleryCap = 12`).
- Double scalar-subquery for `min/max(rowid)` — already done, but the lesson
  ("one aggregate or SQLite scans the whole table") is worth a code comment
  wherever min/max is used.
