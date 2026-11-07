# Chrome's omnibox vs. the Banquet bar

What Chrome's address bar (the omnibox) does on macOS, what the Banquet bar had,
and what was added. Chrome facts come from Google's own pages; anything they do
not state is marked **unconfirmed** rather than guessed.

Sources:
[Chrome keyboard shortcuts](https://support.google.com/chrome/answer/157179),
[Search the web in Chrome](https://support.google.com/chrome/answer/95440),
[Search your tabs, bookmarks and history in the address bar](https://blog.google/products/chrome/search-your-tabs-bookmarks-and-history-in-the-chrome-address-bar/) (Dec 2022).

## Chrome omnibox on macOS

### Keyboard (Mac table of the shortcuts page)

| Keys | Does |
|---|---|
| ⌘L | Jump to the address bar |
| Ctrl+F5 | Move focus to the address bar |
| Return | Search with the default engine / go to the URL |
| Ctrl+Return | Add `www.` and `.com` to a site name and open it in the current tab (the page prints Ctrl, not ⌘) |
| Ctrl+Shift+Return | Same, in a new window |
| ⌘+Return | Open the typed address in a new background tab |
| ↓ then Shift+fn+Delete | Remove the highlighted suggestion (Forward Delete / fn-Delete on laptops) |
| ⌘⇧Delete | Open Delete Browsing Data |
| ⌘Y, ⌘, | Open History, Settings in a new tab |

Windows/Linux only: Ctrl+K / Ctrl+E (search from anywhere), Alt+D / F6 (focus the bar),
Alt+Return (search in a new tab), Shift+Delete (remove a suggestion).

**Unconfirmed** (not on any of the pages above): what Esc does inside the omnibox,
⌘Delete, inline-autocomplete keys, paste-and-go, calculator / unit answers,
"switch to tab" rows, action chips. Some third-party lists give ⌘⌥F as "search from
anywhere"; Google's page says nothing about what it does.

### Not keyboard

- Default-engine search with suggestions from web/app activity; suggestions can be deleted.
- Site-search keywords `@tabs`, `@bookmarks`, `@history`: type the keyword, a space,
  then a query; matches appear in the dropdown (desktop, Chrome 108+). Your own keywords
  live at `chrome://settings/searchEngines`.
- "Ask Google about this page" and AI Mode buttons (need Google as the default engine).

## The Banquet bar before and after

| Omnibox feature | Before | Now |
|---|---|---|
| ⌘L focus | ✓ (⌘L, and `/` or `?` on the grid) | unchanged |
| Return applies, Esc reverts | ✓ | Esc closes the dropdown or error first, then reverts |
| Paste & go | ✓ ⇧⌘V | unchanged |
| Suggestion dropdown | – | ✓ ↑/↓ highlight, Tab fills, Return accepts/submits, click accepts |
| Suggestion sources | – | tables, columns, open documents, recent files, URL history |
| Remove a history suggestion | – | ✓ Shift+fn+Delete on a highlighted history row (Shift+Delete also works) |
| `@`-keywords | – | ✓ `@tables`, `@open`, `@recent`, `@history`, each with an optional filter |
| Back / forward | – | ✓ ⌘[ and ⌘] (Edit menu, beside Find), over submitted URLs |
| Inline error | modal alert | ✓ red border + message under the bar for bar-typed input; other errors still alert |
| Inline (ghost-text) completion | – | not done: a SwiftUI `TextField` can't draw ghost text; needs an `NSTextField` wrapper |
| ⌘+Return / Ctrl+Return | – | not applicable: no tabs, and no `.com` guessing |
| Search engine, AI Mode, Lens | – | not applicable to a local viewer |

### How it works

- `SQLDocCore/Banquet/BanquetSuggester.swift`: pure function from the typed text plus
  already-loaded state (tables, columns, open docs, recents, history) to ranked rows.
  Prefix matches beat word-start matches beat substrings; ties keep recency order.
  It never queries a database, so suggestions can't violate read-only.
- `SQLDocCore/Session/BanquetHistory.swift`: submitted canonical URLs, most recent first,
  de-duplicated, persisted in UserDefaults. `BanquetNavStack` is the back/forward stack.
- Keywords are resolved in the suggester only; `BanquetParser` and the URL grammar are
  unchanged. Highlighting a row never rewrites the text, so the 300 ms live-apply
  isn't triggered by browsing suggestions.
- The dropdown shows only for text you changed. On an untouched bar, ↓ opens it with
  recent history.
- Limits live in `config/seed.sql`: `omnibox.history_max` (200), `omnibox.suggestions_max` (8),
  `omnibox.nav_stack_max` (100).
- Back/forward and history record URLs submitted in the bar (and a late-settling second
  URL when a file opens asynchronously). Clicking in the sidebar or grid doesn't add
  entries.

### Known gaps

- `sqldocKeybindings` (generated from `seed.sql`) still has no consumer. ⌘[ and ⌘] have
  seed rows **and** hardcoded `.keyboardShortcut` wiring in `SQLDocApp.swift`, like the
  other shortcuts. The pre-existing drift (⌘G, ⇧Return, the gallery toggle) is untouched.
- The key-handling paths (↑/↓/Tab/Esc/Shift+fn+Delete in the field, and ⌘[ ⌘]) are
  covered by the pure-logic tests and by ui-e2e's `suggest`, `go`, `back` and `forward`
  dev verbs, but a synthetic key press isn't part of the suite.

### Tests

- `make test`: `BanquetSuggester`, `BanquetHistory`, `BanquetNavStack` cases.
- `make ui-test` / `make ui-e2e`: `omnibox:` and `nav:` cases in
  `Tests/SQLDocAppTests/banquet-ui-cases.json`. The command file trims trailing spaces,
  so keyword cases use a filter word (`@tables tele`) rather than `@tables `.
