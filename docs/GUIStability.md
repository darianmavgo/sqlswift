# GUI stability under big data

How database viewers and editors keep a large table from freezing or crashing
the UI, ranked, then turned into a design checklist for sqlswift.

**Basis for the ranking.** This is an engineering judgement drawn from how
DBeaver, DataGrip, pgAdmin, SSMS, MySQL Workbench, TablePlus, Beekeeper Studio
and DB Browser for SQLite behave, not a measured survey. Ranking is by how much
damage is done when the technique is missing. Tool defaults quoted below are
from memory and change between versions.

## The top 5

### 1. Bounded fetch: never materialise the whole result

Every mainstream tool refuses to pull an unbounded result set into memory. The
grid asks for a window and the rest stays in the database.

- DBeaver fetches 200 rows per segment and loads the next on scroll.
- DataGrip pages at 500 rows.
- SSMS offers "Select Top 1000 Rows" rather than "open table".
- MySQL Workbench appends `LIMIT 1000` to ad-hoc queries.
- pgAdmin loads results in 1000-row batches on demand.

This is where **pagination** lives. The form varies (pages, infinite scroll,
keyset seek, server cursor with a fetch size) but the invariant is the same:
memory and time per interaction are bounded by the window, not by the table.

### 2. Virtualised rendering

Only the visible rows and columns get views. A grid holding 100 000 loaded rows
still lays out about 40 of them, recycling cells as it scrolls (`NSTableView`,
`LazyVStack`, AG Grid, Glide Data Grid, SlickGrid). Without this, a bounded
fetch still dies in layout. Column virtualisation matters as much as row
virtualisation for wide tables, and is the half most often forgotten.

### 3. Queries off the UI thread, cancellable, latest wins

This is where **worker threads** live. Moving the query off the main thread is
the minimum. The parts that prevent real bugs are the other two:

- **Cancellation.** A cancel button or a timeout that actually interrupts the
  statement (`sqlite3_interrupt`, `pg_cancel_backend`, `KILL QUERY`).
- **Stale-result discard.** A generation token or request id so a slow, older
  response cannot overwrite a newer one after the user has moved on.

### 4. Cell-size caps and lazy large values

One 50 MB JSON or BLOB cell can freeze a grid that handles a million small rows.
Tools clip what the grid shows and load the full value only on demand.

- SSMS caps grid text per cell (65 535 chars by default).
- DBeaver has a max LOB length and opens big values in a separate panel.
- DataGrip and TablePlus show a BLOB placeholder with its size.

The strong form clips in SQL (`substr(col, 1, n)`, `length(col)`), so the big
value never leaves the database. The weak form reads the whole value and clips
before display, which protects layout but not memory.

### 5. Deferred and throttled secondary work

The rows are rarely what hangs the app. The extras are: `COUNT(*)` for the
scrollbar, column auto-sizing, search-as-you-type, filter result counts, summary
stats. Mature tools make each of these estimate-first, time-budgeted, debounced,
or opt-in. pgAdmin and DBeaver show an estimated or "200+" row count until asked
for an exact one. DataGrip computes exact counts only on click.

## Where worker threads and pagination landed

Both are in the top 5, so no rebuttal is needed, but each comes with a caveat.

- **Pagination is #1, as part of bounded fetch.** `LIMIT/OFFSET` pagination on
  its own is a weak version: it bounds memory but not time, since offset cost
  grows with depth. Keyset seek is what keeps page 40 000 as fast as page 1.
- **Worker threads are #3, not #1.** A background thread keeps the UI
  responsive while the app runs out of memory. Threads treat the symptom
  (blocked main thread) and bounded fetch treats the cause (too much data).
  Threads without cancellation and stale-result discard also introduce their own
  bugs: wrong page shown, runaway queries piling up behind a lock.

Just outside the top 5: streaming exports to disk rather than building them in
memory, and bounding undo/edit buffers in editors.

---

## Checklist for sqlswift

Status as of 2026-11-10 (branch `sqlswiftedit`), after the work this checklist
drove. `[x]` in place and tested, `[~]` partial by design, `[ ]` open.

### 1. Bounded fetch

- [x] Every rows request has a hard cap (`window.max_rows`, `window.default_rows`,
      `window.all_rows_cap`, `query.row_cap`). None is hardcoded.
- [x] A step to a neighbouring page seeks from rows already on screen
      (`TableViewModel.adjacentSeek` → `Doc.seekQuery`): forward, backward and
      last page, with or without filters and sort, NULL sort values included.
      The pager moves by rewriting the Banquet URL slice, so the choice is made
      in `loadPage`, the one place every page turn passes through.
- [x] One query may hold at most `query.result_max_bytes` of text (256 MB);
      past that it stops with `.resultTooLarge` instead of exhausting memory.
- [~] Still counted by `OFFSET`, on purpose: a jump to an arbitrary ordinal in
      a sorted or filtered set, a sort anchor the page holds only clipped,
      views, and filtered WITHOUT ROWID tables. There is no key to seek on.
      The time budget and Cancel bound the cost.

### 2. Virtualised rendering

- [x] Rows and columns are both windowed (`VirtualizedGridView.rowWindow`,
      `columnWindow`): only those near the viewport get views, with
      `window.overscan_rows` / `window.overscan_px` of margin. The header and
      the stripe/rule backdrop are windowed the same way.
- [x] Per-page derived values (bar bounds) are cached per page
      (`TableViewModel.pageDerived`), not recomputed on each render.
- [~] The query console's result grid is a plain `Grid` of the first 2,000
      rows, not windowed. A result with many columns is slow to lay out.
- [~] Building one cell is still expensive (about 0.3 ms in a debug build), so
      replacing the whole window on a 500-column table stalls for about half a
      second. Not measured in a release build.

### 3. Off-main, cancellable, latest wins

- [x] Every row-returning call goes through one stepping loop that honours a
      `QueryControl`: time budget, `CancelToken`, both via
      `sqlite3_progress_handler` (`SQLiteConnection.run`).
- [x] A newer page load cancels the one in flight, so superseded queries stop
      instead of queueing (`TableViewModel.beginLoad`).
- [x] Page loads stop after `query.page_budget_ms`, console queries after
      `query.console_budget_ms`, each with a plain message.
- [x] Cancel in the status bar once a load passes `query.cancel_offer_ms`, and
      in the query console while a statement runs. Closing the console cancels.
- [x] Three connections by role (`Doc`): `fg` for quick metadata the UI reads
      synchronously, `pages` for page loads, summaries, probes and exports,
      `bg` for counts, find, sampling, console and single-cell fetches. A long
      read can no longer make a main-thread metadata call wait.
- [x] Per-table row estimates are cached, so the sidebar issues no SQL on
      re-render.

### 4. Cell-size caps and lazy large values

- [x] BLOBs are never read for the grid; only their size.
- [x] TEXT over `text.cell_fetch_max_bytes` (4 KB) arrives as
      `SQLiteValue.textPrefix` on pages that have real rowids. Inspect, copy,
      edit and Set NULL fetch the stored value by rowid first
      (`Doc.cellValues`, `TableViewModel.resolveFullValues`).
- [x] `EditSession.commit` refuses a clipped original or new value outright.
- [x] The inspector loads values up to `inspector.text_max_bytes` by itself,
      offers Load all / Save for larger ones, and lays out at most
      `inspector.text_render_max_chars` with no JSON parsing above that.
- [x] The column-width sampler reads only the head of each value.
- [~] Pages with no row key (views, WITHOUT ROWID, ad-hoc queries) cannot
      re-fetch a cell, so they keep each cell whole up to
      `inspector.text_max_bytes`. The result byte budget is their backstop.
- [~] SQLite still reads a clipped value in full to hand over its head. The
      saving is in what Swift copies and retains, not in I/O.
- [~] Console results are cut at the grid cap and flagged; Copy as TSV carries
      the cut values, each ending in "…".

### 5. Deferred and throttled secondary work

- [x] Estimate-first counts, debounced and chunked find, sampled column
      widths, capped gallery, open deadline: unchanged, already in place.
- [x] Count and probe budgets come from the config database
      (`count.filtered_budget_ms`, `count.exact_budget_ms`,
      `count.exact_view_budget_ms`, `schema.probe_budget_ms`).
- [~] Count and width results are still polled rather than pushed. Timer
      churn, not a stability risk.

### Measurements

Dev app, debug build, `testdata/stress.db` (`scripts/make_testdata.sh`).
Memory is process RSS, which includes SQLite's memory-mapped file pages.
Stalls are from the main-thread monitor in `UILog` (`[perf]` lines in
`bin/ui.log`).

| Case | Before | After |
|---|---|---|
| 50,000-row page: memory after scrolling to the end | 810 MB, growing with distance | flat |
| 50,000-row page: stall per 10,000-row scroll jump | 1.1–1.4 s | under 0.2 s |
| 50,000-row page: stall when the page arrives | 1.1 s | none logged |
| 500 columns: switch to raw view | 15.8 s freeze, 2.4 GB | 0.6 s, 424 MB |
| 500 columns: stall per scroll jump | not usable | 0.5–0.6 s |
| 2M rows, sorted jump to row 1,900,000, three in a row | each ran to completion | only the last ran (2.6 s) |
| Cancel on that load | not possible | stopped in 4 ms |
| 200 rows of 2.3 MB text: first page | whole values retained | 376 ms, 4 KB per cell retained |

### How to re-check

- `make test`: budget, cancel, superseded loads, clipped text, result budget,
  seek-versus-offset equivalence (eight filter/sort shapes), connection roles.
- `make ui-test`: pager seeks, superseded loads never land, clipped cell edit.
- `make hot`, then `bin/ui-command.txt`: `scroll <row>`, `inspect <row> <col>`,
  `cancel`, and watch `bin/ui.log` for `[perf] main thread stalled`.
