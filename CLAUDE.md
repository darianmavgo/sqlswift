# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this is

`sqlswift` is a **read-only SQLite viewer** for macOS — a native Swift 6 / SwiftUI
rewrite of the original Go `sqldoc`. The product is named **sqldoc** (bundle, CLI,
menu bar); the repo is **sqlswift**.

Two executables, one core:

| Target | Path | Role |
|---|---|---|
| `SQLDocCore` | `Sources/SQLDocCore` | Engine. No UI, no SwiftUI. `import SQLite3` only. |
| `SQLDocCLI` (`sqldoc`) | `Sources/SQLDocCLI` | `info` / `bench` / `export`, and launches the app. |
| `SQLDocApp` | `Sources/SQLDocApp` | SwiftUI app, MVVM. |
| `ConfigGen` | `Sources/ConfigGen` | Build-time only. Reads `sqldoc.db`, writes `Sources/SQLDocCore/Generated/`. |

**Zero third-party dependencies.** `Package.swift` `dependencies` is empty and
stays empty. SQLite is the system library.

## Core principles — do not violate

1. **Read-only unless an edit session is explicitly entered.** Files open read-only
   (immutable where possible) and the viewer connections stay `PRAGMA query_only`.
   The only write path is an opt-in edit session (⌥⌘E): a separate read-write
   connection that issues parameterised single-cell `UPDATE`s from a staged buffer
   in one transaction. Never issue `INSERT` / `DELETE` / `CREATE` / DDL /
   `PRAGMA writable_schema`; the query console is `SELECT`-only and that is enforced.
   See [`docs/BanquetEditStyle.md`](docs/BanquetEditStyle.md).
2. **Constant-time access.** Row navigation is keyset (seek) pagination. Never
   reach for `LIMIT ? OFFSET ?` for scrolling — offset cost grows with depth.
   The only offset paths left are jumps with no row to anchor on (an arbitrary
   ordinal in a sorted or filtered set, views, a clipped sort value); see
   [`docs/GUIStability.md`](docs/GUIStability.md).
   Row-count is estimate-first (`sqlite_stat1` / `max(rowid)`), exact count
   settles on a background task.
3. **Instant first paint.** Opening a document must not block on a full scan.
   Metadata first, first screen of rows via interpolated seek, everything else
   async.
4. **No hardcoded config.** See below.
5. **The main thread never waits on a query.** `Doc` has three connections by
   role: `fg` is for quick metadata only (the UI reads it synchronously),
   `pages` for page loads, summaries, probes and exports, `bg` for counts, find,
   sampling, console and single-cell fetches. Anything that can run long takes
   a `QueryControl` (time budget + `CancelToken`) and never goes on `fg`.
6. **Pages carry clipped text.** A TEXT cell over `text.cell_fetch_max_bytes`
   arrives as `SQLiteValue.textPrefix`. Code that needs the stored value
   (inspect, edit, copy, bind) must fetch it first (`Doc.cellValues`,
   `TableViewModel.resolveFullValues`) and check `isPartial`.

## The config database — read before touching identity/tokens/keybindings

`sqldoc.db` at the repo root is the **single source of truth** for app identity
(name, version, bundle id), design tokens, typography roles, keybindings, SQLite
connect pragmas, the `_style`/`_nav` convention, and behavior limits. It is
consumed **only at build time**. Full detail: [`docs/build-config.md`](docs/build-config.md).

Humans edit two SQL files; the `.db` is regenerated from them:

```
config/schema.sql   table + view definitions
config/seed.sql     every value, each with a description
sqldoc.db           = sqlite3 sqldoc.db < schema.sql < seed.sql   (make config)
```

Codegen writes `Sources/SQLDocCore/Generated/*.swift`:

```
AppIdentity.swift     name, version, bundleId, homepage, wordmark, tagline…
DesignTokens.swift    ColorToken(light/dark), dimensions, durations
BehaviorConfig.swift  typed tunables with range in doc-comments
TypeRoles.swift       typography roles
Keybindings.swift     sqldocKeybindings: [SQLDocKeybinding]
ConnectPragmas.swift  sqldocConnectPragmas: [String]
DocConventions.swift  hiddenTablePrefix, styleKeys, styleKeyAliases
BuildInfo.swift       git revision — stamped by scripts/gen-buildinfo.sh, NOT from the db
```

**To change a value:** edit `config/seed.sql` → `make generate` → rebuild.
Commit `config/*.sql`, `sqldoc.db`, and `Sources/SQLDocCore/Generated/`.
`make config-check` is the CI guard that fails if they drift.

`BuildInfo.swift` is the exception: it is stamped from git on every build, so a
modified copy in the working tree is normal and harmless. `config-check` excludes it.

## Common commands

```sh
make build          # generate + buildinfo + debug build
make release        # release build
make test           # swift run SQLDocTestsRunner (engine/parser)
make ui-test        # swift test: headless Swift Testing over the view models
make ui-e2e         # replay the same Banquet cases in the running dev app (make hot first)
make app            # assemble bin/sqldoc.app + bin/sqldoc (release)
make install        # /Applications/sqldoc.app + ~/.local/bin/sqldoc, then lsclean
make bench          # build + benchmark against testdata/sample.db
make generate       # regenerate Sources/SQLDocCore/Generated/ from sqldoc.db
make config         # rebuild sqldoc.db from config/*.sql
make config-check   # CI guard: fail if generated Swift is stale
make lsclean        # purge duplicate "Open With" Launch Services entries
sh scripts/make_testdata.sh   # regenerate testdata/{sample,benchmark,stress}.db (gitignored; stress.db is ~500 MB)
```

There is no full Xcode here (Command Line Tools only), so `swift build --arch x
--arch y` universal builds fail. Build each arch separately and `lipo` them:

```sh
swift build -c release --arch arm64
swift build -c release --arch x86_64
lipo -create -output sqldoc .build/{arm64,x86_64}-apple-macosx/release/sqldoc
```

## UI feedback loop (dev app only)

The dev app (`bin/SqlSwift.app`, run via `make hot`) writes two plain-text files
beside itself via `Sources/SQLDocApp/Utilities/UILog.swift`; debug builds only:

- `bin/ui.log` — timestamped `[category] event  key=value…` lines (nav, bar, grid,
  banquet, error, perf). `[perf] main thread stalled  ms=…` is logged whenever
  the main thread is unresponsive for over 120 ms: check for it after any
  rendering or loading change. Previous run is kept as `ui.log.prev`. `make uilog` tails it.
- `bin/ui-state.json` — debounced snapshot of what the window shows: open doc/table,
  the Banquet URL in the bar, display kind, visible columns, sort, rows loaded,
  last query path/timing. `make uistate` prints it.
- `bin/ui-command.txt` — write one command per line and the dev app runs it, then
  deletes the file (`UICommands.swift`): `url <banquet url>`, `sort <col> [desc]`,
  `filter <col> <op> <value>`, `clearfilters`, `display raw|trim|summary`,
  `hide <col>`, `showall`, `page next|prev|first|last`, `size <n>`, `table <name>`,
  `cancel`, `scroll <row>`, `inspect <row> <col>`.
  Wait ~1.5s, then read `ui-state.json` and compare `banquetURL` with `grid`.

Banquet URL ⇄ grid cases live in `Tests/SQLDocAppTests/banquet-ui-cases.json`, shared by
`make ui-test` and `make ui-e2e`; add a case there when fixing a bar/grid bug.

Claude: after changing UI behavior, run `make hot`, drive the app, then read both
files instead of guessing. Add `UILog.event("cat", "msg", [k: v])` at new
interaction points. Also streams to `log stream --predicate 'subsystem == "com.mavgo.sqlswift"'`.

## Layout

```
Sources/SQLDocCore/
  Engine/     Doc, RowReader, Counter, Finder, ColumnSampler,
              SchemaInspector, Exporter, FileImporter, Editor (edit sessions)
  SQLite/     SQLiteConnection, SQLiteValue, SQLiteError  (thin libsqlite3 wrapper)
  Models/     Column, Schema, Table, Style, Page, FindResult, TableCount…
  Session/    SessionManager, per-document state
  Generated/  codegen output — do not hand-edit
Sources/SQLDocApp/
  Views/          MainView, VirtualizedGridView, GalleryView, QueryConsoleView,
                  SchemaSheetView, StartPageView, JumpToRowView
  Views/Components/  FindBar, FilterBar, DataInspector, TableSidebar, StatusBar…
  ViewModels/     AppViewModel and friends
  Theme/          maps ColorToken → SwiftUI Color (keeps Core SwiftUI-free)
config/           schema.sql, seed.sql, assets/ (AppIcon.icns, icon-master.png)
docs/             build-config.md, BanquetEditStyle.md, FEATURE_BACKLOG.md, CLEANUP_RECOMMENDATIONS.md
scripts/          gen-buildinfo.sh, gen-icons.sh, make_testdata.sh
testdata/         *.db are gitignored — regenerate with the script
```

## Conventions

- Swift 6 language mode, strict concurrency. Core types are `Sendable`; shared
  mutable state is behind `NSLock`/`NSRecursiveLock` with `@unchecked Sendable`.
- The engine layer never imports SwiftUI/AppKit. Color/font tokens cross into the
  UI layer as plain strings, resolved by `Theme/`.
- Tables whose name begins with `_` are metadata: hidden by default, surfaced via
  "Show meta tables". `DocConventions.hiddenTablePrefix`.
- A document's `_style` / `_head` can override only a 3-key whitelist at runtime
  (`accent`, `theme`, `title`); everything else in the config db is frozen.
- Match the surrounding code's comment density and naming. Keep comments about
  *why*, not *what*.

## Release checklist

1. Bump `('version', …)` (and `build`) in `config/seed.sql`; `make config generate`.
2. Commit; the shipped binary picks up the new `BuildInfo` at build time.
3. `swift build -c release` per arch, `lipo`, assemble `bin/sqldoc.app`,
   `codesign --force --deep --sign - bin/sqldoc.app`.
4. Fast-forward `main`, tag `vX.Y.Z`, push both.
5. `gh release create` with the `.dmg`, the app `.zip`, the CLI tarball, a sample
   `.db`, and `SHA256SUMS.txt`.

Builds are signed ad-hoc only (no Developer ID / notarization) — release notes
must tell users the right-click-Open / `xattr -dr com.apple.quarantine` dance.

## Roadmap

`docs/FEATURE_BACKLOG.md` — every planned feature, tagged with which prior
project (`sqldoc`, `sqlitewebpage`, `sqliter`, `wailssqliter`, `mksqlite`) it
came from. `docs/CLEANUP_RECOMMENDATIONS.md` — known debt.
