# sqlswift — presentation, speed & search/sort recommendations

Scan of `Sources/SQLDocApp` + `Sources/SQLDocCore` as of `4ca316e`. Grouped by the
five goals: cleaner presentation, less wasted space, better text cells, faster
first paint, faster/clearer search & sort. Each item cites `file:line`.

---

## Top 5 (do these first)

1. **Get first load, sort, and match-jump off the main thread.** `TableViewModel.init`
   runs the whole first load synchronously (columns, count, width loop, the first
   `SELECT`, then a full cell re-measure) and it's kicked off from inside a SwiftUI
   `body` computed property. Construct the VM cheaply, paint the existing skeleton,
   run the query in a `Task`. Same treatment for `sortBy` and `jumpToMatch`.
2. **Precompute cell display strings when the `Page` is built.** `SQLiteValue.displayText`
   calls `NumberFormatter.localizedString` per integer cell, per render; `CellView`
   reads it in `body` and `measureColumnsFromPage` reads it again. Build the strings
   once in `RowReader.rows`, truncate text to `BehaviorConfig.textCellDisplayMaxChars`
   there, and have `CellView` render a ready string.
3. **Collapse per-cell chrome.** Every cell carries a border `Rectangle` overlay +
   three gestures + a `.contextMenu`; every row adds another border + `.contextMenu`.
   That's thousands of nodes per page. Draw gridlines once (a `Canvas`/background
   layer), use one selection-driven context menu, one tap gesture. Seriously
   consider an `NSTableView`-backed grid — free column reuse, virtualization,
   selection.
4. **Freeze column widths after first measurement** and **remove the duplicate row-count
   bar.** Widths are re-measured and overwritten on every `loadPage`, so paging/
   sorting visibly reflows the grid. The top pagination band duplicates the status
   bar and eats a full row of vertical space.
5. **Search/sort hardening:** debounce find input (180 ms, config already exists);
   enforce `findMatchCap`; drop the row payload from `FindMatch`; run all find work
   on the `bg` connection; keyset-paginate the sorted path with a `, rowid`
   tiebreaker.

---

## Presentation & wasted space

- **Duplicate "Rows X–Y of Z" readout.** `VirtualizedGridView.swift:183` and
  `StatusBarView.swift:23` render the same string. Keep one (status bar).
- **The top pagination band is ~33 pt of wasted height** for what is scrolling
  (`VirtualizedGridView.swift:161-219`). Either move to continuous keyset scrolling
  (append the next window as the viewport nears the end — kills the bar and the
  "Next 100 / Previous 100" mental model), or shrink to two icon buttons + jump-to-
  ends folded into the status bar.
- **The design-token palette is 95% dead.** `DesignTokens.swift` defines
  `page/ground/ink/dim/rule/ruleStrong/head/skeleton/markBg`, `rowStripeMix/hitMix/
  cursorMix`, radii; `AppTheme.color(for:isDark:)` resolves them. The grid instead
  uses `Color(NSColor.controlBackgroundColor).opacity(0.15/0.3/0.6…)`
  (`VirtualizedGridView.swift:62,120,217`; `GridHeaderView.swift:27,59`). Those
  translucent fills look muddy and shift with whatever's behind them. Inject the
  resolved theme once via `Environment` and use the tokens for header fill,
  gridlines, zebra stripe, selection/find tints, gutter.
- **No horizontal column virtualization.** All N columns render off-screen
  (`VirtualizedGridView.swift:72`, `GridHeaderView.swift:31`). `LazyHStack` helps;
  windowing to the visible x-range (or NSTableView) fixes it.
- **Horizontal scrollbar is always shown** (`showsIndicators: true`,
  `VirtualizedGridView.swift:37`) even when columns fit. Let it auto-hide.
- **Gutter is a fixed 60 pt** (`VirtualizedGridView.swift:8`); ordinals aren't
  grouped or width-checked (`Text("\(rowOrdinal)")`, line 58). `DesignToken.gutterMinWidth`
  (64) is ignored. Size the gutter to the last ordinal's digit count; format with
  thousands separators.
- **Nested unbounded scroll views.** `ScrollView(.horizontal)` → `VStack` →
  `ScrollView(.vertical)` with no explicit inner height (`VirtualizedGridView.swift:37-47`).
  One `ScrollView([.horizontal,.vertical])` with a pinned section header, or an
  `NSScrollView` representable.
- **Skeleton always renders 15 rows** regardless of viewport height, each cell
  running its own `repeatForever` animation (`VirtualizedGridView.swift:225,437`).
  Size to viewport; drive one shared phase.
- **Window is maximized twice** on launch — `AppDelegate.applicationDidFinishLaunching`
  (`SQLDocApp.swift:118`) and `.onAppear` (`SQLDocApp.swift:19`). Can flash. Keep one.

## Text cells

- **Whole string handed to `Text`** regardless of length (`VirtualizedGridView.swift:525-539`);
  `lineLimit(1)` doesn't stop full layout/measurement. `BehaviorConfig.textCellDisplayMaxChars`
  (400) exists for this and is unused — truncate before building `Text` and before
  width measuring.
- **`NumberFormatter` per numeric cell per render** (`SQLiteValue.swift:69`, read at
  `VirtualizedGridView.swift:490,509` and in `measureColumnsFromPage`). Precompute or
  at least cache a `static let` formatter.
- **Four fonts in one row:** text = system 12; int/real = monospaced 12; NULL =
  monospaced 11 italic; blob = monospaced 10 semibold. Use one size, system font,
  and `.monospacedDigit()` (not full `.monospaced` design) on numeric columns so
  digits align without breaking row rhythm. NULL = same font, `dim` colour.
- **Alignment is by column type name** (`Column.swift:18`), so a `VARCHAR` of digit
  strings and a `REAL` of scientific notation get opposite alignment. Align on the
  actual per-cell value type, type as fallback; align headers to match.
- **`.textSelection(.enabled)` on every cell** (`VirtualizedGridView.swift:514,521,531,538`)
  fights the tap/drag gestures and adds per-`Text` cost. Drop it from the grid
  (inspector + "Copy Cell" cover the need); keep it in `DataInspectorView`.
- **Truncated cells have no hover affordance.** Add `.help(fullText)` for cells whose
  content is actually clipped, so users don't have to open the inspector for a
  slightly-too-long value.
- **Highlight scan runs on non-matching cells.** `CellView` does
  `localizedCaseInsensitiveContains` on every cell every render while a find is
  active (`VirtualizedGridView.swift:480,491,510,526`), and `highlightedText`
  re-scans char-by-char. The matching row+column is already known from `FindMatch`
  (`Finder.swift:134`). Pass an `isMatch/isActiveMatch` bool from the row builder;
  only real match cells build an `AttributedString`.

## First paint

- **`TableViewModel.init` does everything synchronously on the main thread**
  (`TableViewModel.swift:47-93`): `doc.columns`, `doc.count`, disk read of saved
  widths, per-column `ColumnWidthCalculator.optimalWidth` loop (NSString metrics),
  `loadPage(offset:0)` (sync `SELECT`), `measureColumnsFromPage` (measures every
  cell). First frame waits on all of it.
- **VM is constructed during `body` evaluation and mutates `@State`.**
  `MainView.currentTableVM` (`MainView.swift:108-117`) writes `tableVMs[key] = vm`
  while `body` runs → "Modifying state during view update". Move to
  `.task(id: selectedTableName)` / `.onChange`.
- **VMs and their workers are never torn down.** `tableVMs` (`MainView.swift:7`) grows
  one entry per table ever visited; each retains a `Page` and live
  `onCountUpdated`/`onHintUpdated` closures (`TableViewModel.swift:73-86`). Evict on
  doc close / LRU.
- **`Doc.open` eagerly opens two connections**, each applying `mmap_size=256MB` +
  `cache_size=64MB` (`Doc.swift:113-114`, `ConnectPragmas.swift`). The `bg` handle
  isn't needed for first paint — open it lazily on the first background task.
- **`ColumnWidthCalculator` is `@MainActor`** (`ColumnWidthCalculator.swift:5`) and
  runs in the init loop + every page load. Move measurement to a background actor,
  or rely solely on the background `ColumnSampler` hint and stop re-measuring per
  page.

## Search

- **No debounce.** `FindBarView.swift:26` calls `startFind` on every keystroke;
  `BehaviorConfig.findDebounceMs` (180) unused. Each keystroke cancels + restarts a
  detached task that re-runs `bounds()` + a `LIKE` scan.
- **First find touches the `fg` connection.** `find` → `bounds(for:)` →
  `fg.queryRow` (`Doc.swift:346`) from a detached task, contending with rendering.
  Route all find work through `bg`.
- **`matches` grows unbounded.** `startFind` appends every batch forever
  (`TableViewModel.swift:378`); `findMatchCap` (5000) not enforced. Common
  substrings on big tables accumulate hundreds of thousands of `FindMatch`.
- **`FindMatch` carries the whole row** (`FindResult.swift`, `row: [SQLiteValue]`)
  but the UI uses only `rowID` + `column` (`TableViewModel.swift:423`). Drop the
  payload — large saving on wide tables.
- **Match navigation does sync main-thread queries.** `jumpToMatch` →
  `doc.ordinal(for:rowID:)` can run `COUNT(*) WHERE rowid < ?` (`Doc.swift:366`),
  then `loadPage` runs another sync query + full width re-measure
  (`TableViewModel.swift:426-431`). ⏎-walking matches stutters at every page
  boundary. Make it async; freeze widths during find.
- **Find bar covers the data being searched** — floats top-trailing over the header
  and first rows (`MainView.swift:33-47`). Dock it as a thin strip under the toolbar
  (push content down, Safari-style).
- **Full-scan `CAST(col AS TEXT) LIKE '%needle%'` across every column**
  (`Finder.swift:106-115`), 250k rowids/chunk, then a second Swift substring pass.
  Unavoidable without an index, but: detect a companion FTS5 table and route
  through it; and surface scan progress in words ("scanned 1.2M / 4M rows, 37
  matches"), not just a 2px bar, so a slow search reads as progress.
- **Clarity: no scope.** Can't limit find to one column, toggle case-sensitivity, or
  whole-cell match. A "search column: [All ▾]" menu cuts both scan cost and
  ambiguity. Results don't say which column matched.

## Sort

- **Every sort is a full `ORDER BY … LIMIT ? OFFSET ?` with no index**
  (`RowReader.swift:31-35`); each page re-sorts the table and skips `OFFSET` rows.
  Deep pages degrade linearly. `nextPage()` already bails to offset paging when
  `sortColumn != nil` (`TableViewModel.swift:120`) — replace with keyset:
  `WHERE (col, rowid) > (?, ?) ORDER BY col, rowid LIMIT ?`. For repeat sorts,
  `CREATE INDEX` in `temp` on first use (temp store is already `memory`).
- **Unstable order** — `ORDER BY col` with no tiebreaker (`RowReader.swift:33`), so
  equal-key rows reorder between pages (visible duplicates/gaps while scrolling).
  Always append `, rowid`.
- **No "sorting…" feedback.** `sortBy` (`TableViewModel.swift:156-168`) runs
  `loadPage` synchronously; big tables just freeze. Make async with the skeleton.
- **Sort affordance is undiscoverable.** Header shows an arrow only when active
  (`GridHeaderView.swift:51-55`); the tap cycle (asc → desc → clear) is invisible.
  Show a faint glyph on hover for unsorted columns and a clear 3-state indicator.
- **Sort ignores column semantics** — a `TEXT` column of `"2","10","1"` sorts
  lexically. For `isNumeric` columns offer `ORDER BY CAST(col AS REAL)`; expose
  "sort as text / number" in the header context menu (which already hosts the sort
  items, `GridHeaderView.swift:64-93`).
- **Widths jump on every page/sort.** `measureColumnsFromPage` overwrites all
  non-user-sized widths on every `loadPage` (`TableViewModel.swift:110,223-243`).
  Measure once (first page ∪ background sample), then leave alone until "Reset
  column widths".
