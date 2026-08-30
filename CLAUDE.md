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

1. **Read-only, always.** Never issue `INSERT` / `UPDATE` / `DELETE` / `CREATE` /
   `PRAGMA writable_schema` against a user's database. The query console is
   `SELECT`-only and that is enforced. Files are opened immutable where possible.
2. **Constant-time access.** Row navigation is keyset (seek) pagination. Never
   reach for `LIMIT ? OFFSET ?` for scrolling — offset cost grows with depth.
   Row-count is estimate-first (`sqlite_stat1` / `max(rowid)`), exact count
   settles on a background task.
3. **Instant first paint.** Opening a document must not block on a full scan.
   Metadata first, first screen of rows via interpolated seek, everything else
   async.
4. **No hardcoded config.** See below.

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
make test           # swift run SQLDocTestsRunner
make app            # assemble bin/sqldoc.app + bin/sqldoc (release)
make install        # /Applications/sqldoc.app + ~/.local/bin/sqldoc, then lsclean
make bench          # build + benchmark against testdata/sample.db
make generate       # regenerate Sources/SQLDocCore/Generated/ from sqldoc.db
make config         # rebuild sqldoc.db from config/*.sql
make config-check   # CI guard: fail if generated Swift is stale
make lsclean        # purge duplicate "Open With" Launch Services entries
sh scripts/make_testdata.sh   # regenerate testdata/{sample,benchmark}.db (gitignored)
```

There is no full Xcode here (Command Line Tools only), so `swift build --arch x
--arch y` universal builds fail. Build each arch separately and `lipo` them:

```sh
swift build -c release --arch arm64
swift build -c release --arch x86_64
lipo -create -output sqldoc .build/{arm64,x86_64}-apple-macosx/release/sqldoc
```

## Layout

```
Sources/SQLDocCore/
  Engine/     Doc, RowReader, Counter, Finder, ColumnSampler,
              SchemaInspector, Exporter, FileImporter
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
docs/             build-config.md, FEATURE_BACKLOG.md, CLEANUP_RECOMMENDATIONS.md
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
