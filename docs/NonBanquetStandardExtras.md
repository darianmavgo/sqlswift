# Non-Banquet-standard extras

Features in sqlswift that **no Banquet standard document states**. This is a
list only: **nothing has been removed or changed.** The "If removed" column is a
note for later, so any one of these can be dropped without a hunt.

Line numbers are a snapshot from 2026-11-07 and will drift; search for the
symbol. Paths are under `Sources/` unless noted.

## Baseline

"The standards" are the six docs in the local banquet repo
(`~/Documents/view_sqlite/banquet/docs/`), plus the Go reference `banquet.go`:

`banquet-url-syntax.md`, `banquet-db-list-style.md`, `banquet-query-style.md`,
`banquet-grid-style.md`, `banquet-table-list-style.md`, `banquet-bar-style.md`.

- `docs/BanquetSwift.md` is sqlswift's own plan, not a standard. A feature only
  described there counts as an extra.
- The standards link `collections.md`, but it is not in the repo, and there is no
  `conformance/` directory.
- **Extra** = no standard states it. **Reserved, undefined** = a standard names
  the thing (e.g. the query keys `limit`, `offset`) but defines no behavior.
- Difficulty: **Easy** = one symbol or file. **Medium** = 2-3 files.
  **Hard** = parser + view models + tests, entangled.

## Generic removal steps (for later)

1. Delete the code named in the row (and any `@State`/helper only it used).
2. Delete or edit the tests named in the row.
3. `make test`, then `make ui-test`; if you touched a keybinding row in
   `config/seed.sql`, also `make config generate` and `make config-check`.
4. Update `docs/omnibox-comparison.md` and this file.

---

## A. Bar extras

`BanquetBarView.swift` = `SQLDocApp/Views/Components/BanquetBarView.swift`.
`runner` = `Tests/SQLDocTestsRunner/main.swift`. `ui case` = an entry in
`Tests/SQLDocAppTests/banquet-ui-cases.json`.

| ID | Extra | Where | Tests | Diff. | If removed |
|---|---|---|---|---|---|
| A1 | `@tables` `@open` `@recent` `@history` keywords | `BanquetSuggester.swift`: `keywords` :68, `keywordSuggestions` :127, the `hasPrefix("@")` branch :83 | runner "BanquetSuggester: @keywords" :849; ui cases "omnibox: @tables lists tables…", "omnibox: @ alone offers the keywords", and both `ui` omnibox cases; "browsing suggestions never changes the grid" uses `suggest @tables tele` (edit that step) | Easy | delete the three symbols; drop/edit those tests |
| A2 | Separate open-document and recent-file suggestion rows (the bar standard has one "Database" kind) | `BanquetSuggester.swift` `openDocs`/`recents` context + rows; `AppViewModel.banquetSuggestContext` :804 | runner "BanquetSuggester: ranking, tables, columns, dedupe" :818 | Easy | remove the fields, or merge into one kind |
| A3 | Shift+fn+Delete forgets a history row; "⇧⌦ remove" hint | `BanquetBarView.swift` `removePressed` :408; `BanquetHistory.remove` :43 (`SQLDocCore/Session/BanquetHistory.swift`) | runner "BanquetHistory: record, dedupe, cap, remove, persistence" :869 (the `remove` lines) | Easy | delete both; trim that test |
| A4 | Inline error (red border + message) instead of the modal alert | `BanquetBarView.swift` `inlineError` :175, `errorForText` :177 (+ uses :226, :345), error branch of `floatingPanel`, capture block in `submit` | none | Easy | delete those; the modal alert in `MainView.swift` takes over again |
| A5 | **Keys** ⌘[ / ⌘] for back and forward. The feature is standard (rule 9); the keys are not (standard: Alt+←/→ or Ctrl+[ / Ctrl+]) | `SQLDocApp.swift` `Button("Back")` :120 and Forward; rows `nav-back`/`nav-forward` in `config/seed.sql` | none for the keys (ui cases drive `back`/`forward` verbs) | Easy | delete the two buttons and two seed rows, then `make config generate` |
| A6 | ↓ on an untouched bar opens recent history; word-start/substring ranking; column completion keeps the `+`/`-` marker | `BanquetSuggester.swift` `match` :197, `columnRows` :172; `BanquetBarView.swift` `moveHighlight` :393 | runner :818; ui cases "omnibox: plain text suggests matching table first", "omnibox: column completion keeps the sort marker" | Easy | simplify those functions; edit tests |
| A7 | Paste & go (⇧⌘V) | `AppViewModel.pasteFromClipboard` :445, `banquetBarPendingPaste` :204; `BanquetBarView.swift` `applyPaste` :309; menu item in `SQLDocApp.swift` | none | Medium | delete all four |
| A8 | Newline flattening in the field | `BanquetBarView.swift` `flattenNewlines` :301 | none | Easy | delete it and its call in `onChange(of: text)` |
| A9 | Row-count/timing pill, copy-URL button, DEV badge | `BanquetBarView.swift` `TableTelemetryPillView` :569, `copyURLButton` :524, `devBadge` :548; `AppViewModel.copyBanquetURL` :763; ⌘⌥C menu item | none | Easy | delete the views, the function, the menu item |
| A10 | 300 ms live-apply while typing (bar standard: evaluate on submit) | `BanquetBarView.swift` `scheduleLiveApply` :272, `liveApply` :282, their `onChange` hook | `ui` cases "bar: typed edit live-applies" and "bar: typed bare ?col>value applies and normalizes on blur" would fail → drop them. "half-typed table name is ignored", "half-typed sort column is ignored" and "blur reverts…" still pass | Easy | delete both functions + hook; blur-revert is separate and stays |
| A11 | Folder-relative input (prefixes `currentFolderPath`) and a file/directory shortcut that bypasses the parser | `BanquetBarView.swift` `submit` (the `currentFolderPath + "/"` block :331); `AppViewModel.openBanquet` :845 (shortcut) | runner "FolderScanner: Resolves stripped leading slash…" :740 covers `resolveLocalPath` | Medium | delete both blocks. **Careful:** `FolderScanner.resolveLocalPath` :76 relies on the parser's leading-`/` stripping |
| A12 | Second history record 400 ms later for files that open asynchronously | trailing `Task` in `BanquetBarView.swift` `submit` | none | Easy | delete the `Task` |
| A13 | Dev verbs `suggest`, `go`, `back`, `forward`, `navreset` (`#if DEBUG`) | `SQLDocApp/Utilities/UICommands.swift` :65-74 and neighbours; `AppViewModel.resetNavigation`/`setSuggestionsSnapshot`; `scripts/ui-e2e.py` RESET list; `Tests/SQLDocAppTests/BanquetUITests.swift` (`resetNavigation()` call) | all 9 headless `omnibox:`/`nav:` ui cases use them | Easy | delete the verbs and those cases together |
| A14 | `x-banquet:` / `banquet:` URL scheme | `SQLDocApp.swift` `.onOpenURL` :15 | none | Easy | delete the handler |

## G. URL grammar extras

`P` = `SQLDocCore/Banquet/BanquetParser.swift`. `Ser` =
`SQLDocCore/Banquet/BanquetSerializer.swift`.

| ID | Extra | Where | Tests | Diff. | If removed |
|---|---|---|---|---|---|
| G1 | Nested URLs; scheme/host/port split; `gs:/x` → `gs://x`; `./` prefix when the first segment has a colon (url-syntax says nothing about scheme URLs) | P: `cleanURL` :12, `parse` :47, `parseDirect` :64 | runner "Banquet: Nested URLs and CleanURL" :478, "BanquetParser: Super ugly nested URL" :580 | Medium | simplify those three; drop both tests |
| G2 | `&` accepted as the query separator when there is no `?` | P: `parseDirect`, the `else if let ampIdx` branch :77 | none by name; check the two tests above before removing | Easy | delete the `else if` branch |
| G3 | Extra extensions `.sqlite3` `.tsv` `.xls`, and the `test.html` exclusion (standard list: `.db .sqlite .csv .xlsx .json .zip .txt .html`; same in `banquet.go`) | P: `knownExtensions` :7, uses :134 and :258 | none | Easy | edit the array and :258. **Careful:** `AppViewModel.applyBanquet` :870 separately accepts `.sqlite3`; `BanquetComposer.inferTable` :82 omits it |
| G4 | `<` `>` `<=` `>=` and `=` in the path; percent-decoding of values; `=` counted as clause-like in `isClauseLike`. Standard: only `Column!=Value` in the path | P: `splitComparison` :346, `parsePathConditions` :401, `isClauseLike` :278, decoding :412/:425/:442/:560 | runner "Banquet: Familiar slash-delimited parsing & slice notation" :390 (path-condition assertions ~:421-434); ui case "regression: +id>6000 in path must not become a column" | Hard | shares code with sort markers (G5); do after, or together |
| G5 | A sort marker also names a shown column; the serializer moves a hidden sort column to `?sort=&order=`. Declared an sqlswift rule in `BanquetSwift.md`; the standard is silent | P: `parseSelect` :361, `parseOrderBy` :472; Ser: `canonicalString` :7; `AppViewModel.banquet(for:)` :605 | runner :390 and :448; ui cases "sort marker keeps its column in the projection", "sort marker alone is sort-only", "sorting by a projected-out column uses ?sort=", "grid: hiding the sorted column moves sort to ?sort=" | Hard | revert parser + serializer + `banquet(for:)` together |
| G6 | Open bounds in slices: `[a:]`, `[:b]` (standard defines only `[start:end]`) | P: `parseSlice` :496; the `[off:]` form in Ser | none | Easy | require both bounds in `parseSlice` and the serializer |
| G7 | `filter` as an alias of `where` (the key is reserved but undefined) | P: `parseWhere` :461-466 | runner :581/:587 (ugly-nested test uses `filter`) | Easy | delete the alias branch |

## Q. Query-engine extras

| ID | Extra | Where | Tests | Diff. | If removed |
|---|---|---|---|---|---|
| Q1 | GROUP BY inferred from `col(inside)` in the path | P: inference with `sqlFunctionNames` :522 | runner "BanquetParser: GroupBy from path" :569 | Medium | delete inference + the test; `Banquet.groupBy` stays if Q3 stays |
| Q2 | Embedded `SELECT …` parsing, standalone and after a prefix; `select`/`with`/`pragma`/`explain` detection in the bar | P: `parseEmbeddedSQLStatement` :673, `splitPrefixAndSQL` :646; `BanquetBarView.swift` `submit` :324 | runner "Banquet: Pasted SQL & aggregate expressions in Banquet URL" :773 | Medium | delete both parser functions and the `isStandaloneSQL` check |
| Q3 | Query keys `limit`, `offset`, `groupby`, `having` (reserved by url-syntax, behavior undefined) | P: `standardQueryParamKeys` :566, handling ~:208-212, `parseDirect`; Ser; `TableViewModel.applyBanquet` :714 | runner :374 (`limit=50`), :390, :478, "BanquetComposer: SQL Construction" :494; ui case "limit via query param" | Medium | remove handling in all three places and those assertions |
| Q4 | Raw-SQL execution path | `TableViewModel.isCustomBanquetQuery` :335, `runCustomBanquetLoad` :590; `SQLDocCore/Banquet/BanquetComposer.swift` `compose` :9 | runner "BanquetComposer: SQL Construction" :494 | Hard | only after Q1-Q3 are gone **and** you accept dropping any `where` text `ColumnFilter` cannot parse |
| Q5 | Auto-Trim on tables over 14 columns; the `summary` display kind (query-style names `summary` but gives no rules for it) | `TableViewModel.swift` :193-195 (14-column check); `SQLDocCore/Banquet/QueryStyle.swift` `summaryPage` :452; display-kind menu items in `SQLDocApp.swift` and `StatusBarView.swift` | runner "QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage" :671 | Medium | delete the check, `summaryPage`, the menu items, the summary half of that test |
| Q6 | A URL with no slice means **all rows** (up to `window.all_rows_cap`, 50 000); past the cap the bar shows `[0:cap]`. Page keys move the selection instead of paginating while everything is one page. The engine's per-request clamp now follows the cap (it was a hard 1000, which silently truncated explicit slices such as `[0:5000]`). url-syntax defines no default limit | `TableViewModel`: `showAllRows`, `allRowsCap`, `isShowingAllRows`, `UnslicedPaging`, step 4 of `applyBanquet`; `AppViewModel.banquet(for:)` and `paginate*`; `VirtualizedGridView.handleKeyPress`; `SQLDocCore/Engine/RowReader.swift` `Doc.maxLimit`; `window.all_rows_cap` in `config/seed.sql` | ui cases "plain table (no slice = all rows)" and the `all rows:` group; the bar case "deleting the slice while typing waits for Return" | Medium | delete the state and its three call sites, restore `Doc.maxLimit = 1000`, drop the seed row (`make config generate`), and restore the `[0:100]` default in the cases that were changed |

---

## Appendix: standard says it, sqlswift lacks or differs (information only)

| Standard | Says | sqlswift |
|---|---|---|
| bar-style 2 (MUST) | Bar focused by default on launch | not implemented (focus only via ⌘L, `/`, `?`, paste) |
| bar-style 6 (MUST) | ↑/↓ recall evaluated URLs; ↓ returns to the unsubmitted draft | not implemented: ↑ is ignored, ↓ opens the suggestion dropdown |
| bar-style 9 (MUST) | Back/forward on Alt+←/→ (or Ctrl+[ / Ctrl+]) | ⌘[ / ⌘] (see A5) |
| db-list-style | `?depth=N` bounds collection recursion | not handled |
| db-list-style | In-memory `databases` / `tables` catalogs with required columns (`name`, `location`, `key`, `table_count`, `size`, `size_bytes`, `modified`, `status`, `open`) | `CollectionCatalog.generate` is an unused stub; folders are shown through `FolderScanner` |
| table-list-style | Tiny tables (under 20 rows) shown inline, one grid per table | absent |
| query-style | Trim probe samples 2000 rows | 1000 (`QueryStyle.swift`) |
| `BanquetSwift.md` | Conformance corpus + `make conformance` | absent here; the upstream repo has no `conformance/` either |
