# Banquet Implementation Log

Running log of work making sqlswift obey the standards in `banquet/docs/*.md`:
problems hit, assumptions made, and fixes. Newest entries at the bottom.
Plan: `~/.claude/plans/partitioned-enchanting-eich.md`.

## 2026-11-06 — Steps 1–3 (quick fixes)

- **Fix:** `banquetURLString` no longer appends `/databases` (bare folder → `<folder>/`, sorted → `<folder>/-size_bytes`). User rule: never emit `databases`, stricter than the standard (which allows it before a sort).
- **Problem:** I first trimmed the trailing slash off the parser's collection `dataSetPath`. `SQLDocTestsRunner` failed (`local/Documents/Income/` expected). **Fix:** reverted; the Go reference keeps the slash and `resolveLocalPath` tolerates it.
- **Fix:** BLOB cells render `<BLOB: N bytes>` (was `◼ 1.0 KB`).
- **Fix:** zero rows after a filter shows "No results found"; truly empty unfiltered table keeps "This table is empty."
- **Fix:** `trimColumnCap` 20 → 40.
- **Deferred (assumption):** `Page.cellTextMaxChars` is 400 from the config DB (`sqldoc.db`), the standard says ~120. Needs a config edit + `make generate`, so not done yet.
- **Deferred (assumption):** `lowCardinalityMax` stays 12 (standard: <10) because summary mode tunes it alongside a 25 limit for categorical columns.
- **Deferred (assumption):** no unknown-column hint in `BanquetBarView.liveApply`; it runs while typing, so a popup would nag. Enter still reports errors via `openBanquet`.

## 2026-11-07 — Discovered concurrent work; re-audit

- **Problem:** my first audit said the Bar had no history, completion, dropdown or back/forward. A parallel editor (another session, uncommitted + new commits) has since added `BanquetSuggester`, `BanquetHistory`, back/forward verbs, the dropdown overlay, and `docs/NonBanquetStandardExtras.md` (whose Appendix lists remaining gaps). My earlier grep returned nothing because those files did not exist yet at the time.
- **Assumption:** `NonBanquetStandardExtras.md` Appendix is the current gap list. Remaining after re-audit: bar-2 default focus, bar-6 ↑/↓ recall, bar-9 Alt+←/→ keys, `?depth=N`, in-memory catalog (`CollectionCatalog` stub), table-list. I will NOT remove any "extra" listed there — it is a list only and the user hasn't asked for removals.
- **Rule for myself:** the working tree has other people's uncommitted edits. Only touch lines I need; never `git checkout`/`stash`/reset; re-read a file immediately before editing it.

## 2026-11-07 — Bar rules 2 and 6

- **Fix (bar-2):** `MainView.onAppear` sets `isBanquetBarEditing = true` so the bar is focused on launch.
- **Assumption (bar-2):** NOT refocusing after every submit. `submit()` deliberately blurs so the grid gets arrow-key/⌘F navigation; refocusing would break that. Launch focus + ⌘L only. Revisit if the user wants the strict reading ("completing an action").
- **Fix (bar-6):** ↑ on a quiet bar walks `BanquetHistory.entries` (newest first); ↓ walks forward and past the newest returns to the saved draft. ↓ on an untouched bar still opens the dropdown (existing omnibox behaviour); once recalling, ↓ means "newer". Recall writes `text` but is flagged via `recalledText` so it neither live-applies nor opens suggestions; any real edit or blur clears recall state.
- **Problem:** osascript cannot send keystrokes to the dev app (`error 1002`, no Accessibility grant), so the ↑/↓ key path can't be driven from the shell. **Fix:** moved the logic to a pure `BanquetRecall` struct (`SQLDocCore/Session/BanquetHistory.swift`, unit-tested in `SQLDocTestsRunner`), held in `AppViewModel.barRecall`, and added a DEBUG `recall up|down` verb in `UICommands.swift` that uses the same `recallStep`. Verified live: ↑ walked telemetry → events → devices and stopped at the oldest; ↓ walked back.
- **Problem:** `go <url>` records the URL read immediately after `openBanquet`, before table switching settles, so `go .../devices` recorded the *old* table and history collapsed to one entry. **Workaround for tests:** `table <name>` first, then `go <url>`. (Not fixed in app code; real Enter-submit path records after the bar re-syncs.)
- **Problem:** `size 100` in a test sequence re-opens the bar URL and resets bar text, hiding recall results. Don't interleave it.
- **Fix:** first ↑ skips a history entry equal to the text already in the bar (it's the page you're on).

## 2026-11-07 — Table List (banquet-table-list-style.md)

- **Fix:** new `SQLDocCore/Banquet/TableList.swift` (`TableListBuilder`, `TableListSection`, `TableListCategory`) + `SQLDocApp/Views/TableListView.swift`. One independent grid per table under `=== Table: name (N rows, M columns) ===`; first 20 rows; Tiny (1–19) → Large (20+) → Empty, each by row count desc; empty tables get one `(Empty)` row. Wired via `AppViewModel.isTableListVisible`, set in `applyBanquet` step 3 (`<db>/tables`), cleared on table selection; bar shows `<db>/tables`.
- **Assumption:** reading only the first 20 rows via `Doc.rows(window:)` decides the category: fewer than 20 rows back = exact count (tiny/empty); a full page = large, with the count from the O(1) `Doc.count` estimate (shown with `~` while inexact). Keeps the constant-time principle; standard shows exact counts, so large tables may show `3,152~`.
- **Assumption:** `<db>` alone (bare database URL) still opens the first table (existing behaviour, via the file shortcut in `openBanquet`). Only `<db>/tables` shows the list. The standard doesn't say which URL form lists tables; `tables` is the reserved catalog name, so I used it. Tell me if bare `<db>` should list instead.
- **Assumption:** raw column order (`SELECT *`), not trim ordering, as the standard literally says `SELECT * FROM table LIMIT 20`.
- **Problem:** the hot-reload build is fine but no Accessibility/Screen Recording to view the window; verified via `ui.log` ("table list tables=[devices, events, telemetry]") and `ui-state.json`, plus a unit test of ordering/header/placeholder. The `sample.db` counts (devices 5, events 5, telemetry 10000) match the expected tiny/tiny/large order.
- **Problem (mine):** a full-screen `screencapture` grabbed an unrelated Chrome window (private browsing context). Deleted the file immediately; will not use full-screen capture again — rely on state files.
- **Not verified visually:** the SwiftUI layout of `TableListView` (grid widths, horizontal scroll) has not been eyeballed.
