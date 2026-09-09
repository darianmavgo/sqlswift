# BanquetSwift — a Form 2 plan for the Banquet Bar

How sqlswift implements the Banquet Bar (the address/breadcrumb bar for
[Banquet](https://github.com/darianmavgo/banquet) URLs) *without* linking the Go
reference parser or the `banquet.js` port — kept in sync with the standard
through a shared spec and a conformance corpus, not shared runtime code.

"Form 2" refers to the two ways to keep native implementations in sync:

- **Form 1** — one shared core library (Rust/Go/C) called over FFI from each
  front end (Signal's `libsignal`, Firefox + UniFFI, Dropbox + Djinni).
- **Form 2** — three idiomatic hand-written implementations held together by a
  written spec + a language-neutral conformance test corpus + code generation.

sqlswift's whole thesis is "zero dependencies, pure Swift 6, system
libsqlite3." The Banquet parser is a few hundred lines of string handling, and
the hard engine (SQLite) is already shared everywhere as libsqlite3 / wa-sqlite.
So Form 2 fits: a hand-written Swift parser that must pass the same fixtures as
every other implementation.

## The precedent

This is exactly how the **WHATWG URL Standard** is kept consistent across
independently written browser parsers:
[`urltestdata.json`](https://github.com/web-platform-tests/wpt/blob/master/url/resources/urltestdata.json)
is a flat file of `{input, base, expected fields}` cases that every browser runs.
CommonMark does it with `spec.json` (`{markdown, html}` pairs); JSONPath
(RFC 9535) shipped a `cts.json` compliance suite for the same reason — many
implementations, one behavior. Banquet is a URL dialect and should be specified
the same way.

## 1. What the `banquet` repo has to publish

The `banquet/docs` folder defines the normative behavior and conventions. The 5 key standards are:

- **[banquet-url-syntax.md](https://github.com/darianmavgo/banquet/blob/main/docs/banquet-url-syntax.md)**: The core grammar, distinguishing explicit `;` and familiar `/` syntax, alongside sort/slice/filter behaviors and Collections.
- **[banquet-query-style.md](https://github.com/darianmavgo/banquet/blob/main/docs/banquet-query-style.md)**: Rules for "Trim View" column ordering (PKs first, grouping columns, hide technical columns, etc.).
- **[banquet-grid-style.md](https://github.com/darianmavgo/banquet/blob/main/docs/banquet-grid-style.md)**: How columns/rows are drawn (soft-wrapping, translation, group separation).
- **[banquet-db-list-style.md](https://github.com/darianmavgo/banquet/blob/main/docs/banquet-db-list-style.md)**: Synthetic catalogs for Collections and folders.
- **[banquet-table-list-style.md](https://github.com/darianmavgo/banquet/blob/main/docs/banquet-table-list-style.md)**: Inline expanding for "Tiny Tables" (< 20 rows).

## 2. The conformance corpus — `banquet/conformance/`

```
conformance/
  parse/*.json       { "input": "history.db/backtest_details_all/-Open[0:25]",
                       "expect": { "dataset": "history.db",
                                   "table": "backtest_details_all",
                                   "sort": [{"col":"Open","dir":"desc"}],
                                   "slice": {"start":0,"end":25} } }
  serialize/*.json   { "model": {...}, "expect": "history.db/mytable/-Open[0:25]" }
  errors/*.json      { "input": "mytable/[0:", "error": "unterminated-slice" }
```

Plus round-trip invariants: `parse(serialize(m)) == m`,
`serialize(parse(s)) == canonical(s)`. The Go reference parser is the fixture
generator and CI guard; JS and Swift are pure consumers.

## 3. What sqlswift builds

Inside `SQLDocCore` (pure Swift, zero deps — the thesis holds, because this is a
hand-written parser, not a linked library):

```
Sources/SQLDocCore/Banquet/
  Banquet.swift            // the value type — mirrors the JSON Schema
  BanquetParser.swift      // Banquet.parse(_:) throws -> Banquet
  BanquetSerializer.swift  // banquet.canonicalString
  CollectionCatalog.swift  // Handles synthetic `databases`/`tables` cataloging for IsCollection
  QueryStyle.swift         // Implements Trim View column ordering logic

Tests/SQLDocCoreTests/
  BanquetConformanceTests.swift   // iterates Tests/Fixtures/banquet/**/*.json
  Fixtures/banquet/               // vendored corpus, pinned to a banquet tag
```

`BanquetConformanceTests` loads every fixture file and asserts — one XCTest that
fails if the Swift parser drifts from the standard. `make conformance` runs it in
CI; `make conformance-update` re-vendors the corpus from a pinned `banquet`
release (git submodule or a `curl` in the Makefile).

## 4. Wiring it into the actual bar

The bar itself is 100% native and shared with nobody:

- **`BanquetBarView`** — an editable field that also renders breadcrumb
  segments, macOS path-bar style. Segments come from the *parsed model*
  (`dataset / table / -Open[0:25]`), not string splitting; clicking one
  truncates the query there.
- **Parse-in:** type or paste a Banquet string → `Banquet.parse` → a
  `QueryIntent` the view model applies: open the doc if `dataset` changed,
  select `table`, push `sort`/`where`/`select`/`slice` onto the grid (mapped
  onto sqlswift's keyset pagination — that mapping is sqlswift's own business).
- **Collections Handling**: If `IsCollection` is true, the `CollectionCatalog` generates an in-memory catalog database for the current directory level. The grid renders `databases` and `tables` following the `banquet-db-list-style.md`.
- **Tiny Tables**: For tables with fewer than 20 rows, `TableListView` expands the content inline.
- **Reflect-out:** any grid interaction (sort a header, filter, hide a column)
  updates the view model's `Banquet` value → `canonicalString` → bar text
  updates → copy button / `⌘C` yields the shareable URL. Suppressed when the
  incoming URL already carried clauses — same rule sqlite-mavgo uses.
- **Entry points:** `sqldoc "history.db/mytable/-Open"` on the CLI, an
  `x-banquet:` URL scheme via `application(_:open:)`, drag a Banquet URL onto
  the window.

## 5. Codegen tie-in

The reserved sigils (`+ - ; [ ] ! ?`) and the pinned spec version go in a table
in `sqldoc.db`; `make generate` emits them as a Swift enum so they're defined
once, not hardcoded in both the parser and the breadcrumb renderer. And add a
short **"Banquet Bar behavior"** section to the spec repo — when to reflect,
breadcrumb-truncation semantics, what a segment click does — so the two bars
behave identically even though the view code is entirely separate.

## Provenance

Sibling to `sqldoc`'s `RefactorSwift.html` / `FinishPort.html` and
sqlite-mavgo's `RefactorSqlDoc.html`. The Flutter port (`sqliteplutogrid`) had a
`banquet_bar.dart` and tried Form 1 — compiling the Go `banquet` lib and loading
it over `dart:ffi`; the git log records how that ended (`removed ffi. using
banquet lib exported to dart`). This doc is the Form 2 alternative.
