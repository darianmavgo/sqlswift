# Build-time configuration: `sqldoc.db`

`sqldoc.db` (repo root) is the **single source of truth** for every style token,
layout dimension, engine tunable, keyboard shortcut and SQLite pragma used by
any sqldoc frontend — the Go/browser viewer, the Swift/macOS app, and the CLI on
both. It is consumed **only at build time**, by codegen. It is never linked into
a binary and never opened at runtime.

At runtime a document may still override a small, explicitly-marked subset
(accent colour, theme, title) through its own `_style` / `_nav` tables — see
[Runtime interplay](#runtime-interplay). Everything else is frozen at build time.

---

## 1. What's inside

| table | holds | codegen emits |
|---|---|---|
| `meta` | schema version + provenance | header comment on every generated file |
| `platform` | `all` / `web` / `mac` / `cli` | — (scoping) |
| `token` | colours (light+dark), dimensions, durations, opacities | CSS custom properties; `DesignToken` Swift enum |
| `setting` | engine/behaviour tunables, with type + min/max + unit | `window.__SQLDOC_CFG__` JS object; `config.gen.go` consts; `BehaviorConfig` Swift enum |
| `setting_enum` | allowed values for `enum` settings | Swift `enum` cases / TS union |
| `override` | deliberate per-platform divergence, **with a reason** | the platform's value wins in that platform's output |
| `type_role` | named typography roles (size / weight / family / zoom-scaling) | CSS font rules; `Font` per role in Swift |
| `keybinding` | canonical shortcuts (`mod` = ⌘ on mac, Ctrl on web) | JS keydown map; SwiftUI `.keyboardShortcut` list |
| `connect_pragma` | PRAGMAs applied to every read-only handle | `connectPragmas` (Go); `applyPragmas()` body (Swift) |
| `doc_convention` | the `_style`/`_nav` contract + key aliases | the `switch` in `loadStyle()` on both ports |
| `identity` | app name, version, bundle id, doc-type registration, window titles, theme-color | `Info.plist`, web `<head>` + manifest, CLI `--version`, `.desktop` |
| `icon_target` | every derived icon file + sizes + consumer | `make icons` scales the web set from `config/assets/icon-master.png` |

Three views do the platform resolution for you:

```sql
SELECT * FROM v_token_resolved   WHERE platform = 'web';   -- light+dark, overrides applied
SELECT * FROM v_setting_resolved WHERE platform = 'mac';   -- one value per key, overrides applied
SELECT * FROM v_identity         WHERE platform = 'mac';   -- name/version/bundle-id, platform rows win
```

## 2. Source-of-truth workflow

The **binary `sqldoc.db` is the artifact codegen reads**, but humans edit the
two SQL files and rebuild:

```
config/schema.sql   table + view definitions      (reviewable, diffable)
config/seed.sql      every value, with description  (reviewable, diffable)
sqldoc.db            generated: sqlite3 sqldoc.db < schema.sql < seed.sql
```

Make targets (implemented):

| target | does |
|---|---|
| `make config` | rebuild `sqldoc.db` from `config/schema.sql` + `config/seed.sql` |
| `make generate` | run `ConfigGen` → `Sources/SQLDocCore/Generated/*.swift` + `.build/Info.plist` |
| `make icons` | run `scripts/gen-icons.sh` → web favicon/manifest set from `icon-master.png` (the .icns is committed) |
| `make build` / `release` / `test` | depend on `generate` — **this is how `sqldoc.db` enters the build** |
| `make app` | copies the generated `Info.plist` + `AppIcon.icns` into `bin/sqldoc.app` |
| `make config-check` | `make generate` then `git diff --exit-code` on db + config + generated |

`ConfigGen` (`Sources/ConfigGen`) is an `executableTarget` that depends on
nothing in the package, so `swift run ConfigGen` never needs the files it
writes to exist first. `make generate` is gated by a `.build/configgen.stamp`
so it only re-runs when `sqldoc.db` or the generator changes.

Commit `sqldoc.db`, `config/assets/` (the `.icns` + `icon-master.png`), and
`Sources/SQLDocCore/Generated/`.
`config-check` in CI guarantees they never drift from the SQL. (Requires a git
repo — run `git init` in `sqlswift` first.)

The Go side is the same shape: `//go:generate go run ./cmd/configgen` +
`make generate` (not yet built — see §4).

## 3. Injection — Swift / macOS

Executable target `ConfigGen` (`Sources/ConfigGen/main.swift`), `Foundation` +
`SQLite3` only. It reads `sqldoc.db` and writes `Sources/SQLDocCore/Generated/`
— **built and wired** (`make generate`):

```
DesignTokens.swift    enum DesignToken   { ColorToken(light/dark), CGFloat dims, Duration }
BehaviorConfig.swift  enum BehaviorConfig { every setting, typed, with range in doc-comment }
TypeRoles.swift       enum TypeRoles      { [SQLDocTypeRole] + role(_:) lookup }
Keybindings.swift     let sqldocKeybindings: [SQLDocKeybinding]
ConnectPragmas.swift  let sqldocConnectPragmas: [String]
DocConventions.swift  enum DocConventions { hiddenTablePrefix, styleKeys, styleKeyAliases }
AppIdentity.swift     enum AppIdentity   { name, version, bundleId, wordmark, … }
```

Actual generated shape (colours are `ColorToken(light:"#…", dark:"#…")` — the
UI layer maps them to `Color` via `AppTheme`; Core stays SwiftUI-free):

```swift
public enum DesignToken {
    public static let page       = ColorToken(light: "#ffffff", dark: "#202124")
    public static let accent     = ColorToken(light: "#2563eb", dark: "#2563eb")
    public static let rowHeight:      CGFloat = 26            // ← override(token,row-height,mac)
    public static let transitionFast = Duration.milliseconds(120)
    public static let accentHex      = "#2563eb"
}

public enum BehaviorConfig {
    public static let windowBlockRows       = 100   // ← override(setting,window.block_rows,mac)
    public static let findChunkRows         = 250000
    public static let colwidthSampleAnchors = 24
    public static let zoomMax               = 2.0   // ← override
    public static let zoomStepMode          = "add" // ← override
}
```

Migrate the scattered literals onto these:

| today | becomes | status |
|---|---|---|
| `applyPragmas()` literal array (SQLiteConnection.swift) | `sqldocConnectPragmas` | **done** |
| `let version = "0.3.0"` (SQLDocCLI/main.swift) | `AppIdentity.version` | **done** |
| `Doc.sampleAnchors = 24` (ColumnSampler.swift) | `BehaviorConfig.colwidthSampleAnchors` | todo |
| `Doc.findChunk = 250_000` (Finder.swift) | `BehaviorConfig.findChunkRows` | todo |
| `Style(accent: "#2563eb", …)` (Style.swift) | `DesignToken.accentHex` | todo |
| `26 * appVM.zoomScale` (VirtualizedGridView) | `DesignToken.rowHeight * appVM.zoomScale` | todo |
| `zoomScale = min(2.0, …)` (AppViewModel) | `BehaviorConfig.zoomMax` + `zoomStepMode` | todo |
| `gutterWidth = 60` (Grid views) | `DesignToken.gutterMinWidth` | todo |
| `loadStyle()` alias `switch` (Doc.swift) | `DocConventions.styleKeyAliases` | todo |
| gallery `.keyboardShortcut("g", …)` (SQLDocApp.swift) | `sqldocKeybindings` — resolves the ⌘G collision, §5 | todo |
| inline `Info.plist` echo (Makefile) | `.build/Info.plist` from `ConfigGen --plist` | **done** |

**Now**: `make generate` writes committed files; gated by `.build/configgen.stamp`.
**Later**: wrap `ConfigGen` in a SwiftPM build-tool plugin on `SQLDocCore` so
regen is automatic and `Generated/` leaves git.

## 4. Injection — Go / web

**New command** `cmd/configgen/main.go` (uses the `modernc.org/sqlite` driver
already vendored). `//go:generate go run ./cmd/configgen -db ../../sqldoc.db` in
a small `internal/gen.go`. It writes:

```
internal/ui/tokens.gen.css     :root{…}  :root[data-theme="dark"]{…}  @media(prefers-color-scheme:dark){…}
internal/ui/config.gen.js      window.__SQLDOC_CFG__ = { block:200, overscan:8, … }
internal/doc/config.gen.go     package doc — const/var block + connectPragmas
```

`internal/ui/tokens.gen.css` replaces the hand-maintained `:root` blocks at the
top of `app.css` (structural CSS stays hand-written). `ui.go` inlines both:

```go
//go:embed app.css app.js tokens.gen.css config.gen.js
var assets embed.FS
// Shell(): {{TOKENS_CSS}}+{{CSS}} into <style>, {{CONFIG_JS}} as a <script> before app.js
```

`app.js` drops its private constants and reads the injected object:

```js
const CFG = window.__SQLDOC_CFG__;          // was: const BLOCK = 200; const OVERSCAN = 8; …
const BLOCK = CFG.window_block_rows;
const OVERSCAN = CFG.window_overscan_rows;
```

`internal/doc/config.gen.go` replaces the literals in `open.go`
(`connectPragmas`, `idleGrace`), `find.go` (`findChunk`, limits), `colwidths.go`
(`sampleAnchors`, `sampleRowsPerAnchor`), `rows.go` (`maxLimit`), and
`server.go` (`galleryMinRows`, `galleryCap`, min-tables).

## 5. App identity & icon

Name, version, bundle id, document-type registration and every icon file are
config too — held in the `identity` and `icon_target` tables and one master
SVG. Resolve a platform's identity with:

```sql
SELECT key, value FROM v_identity WHERE platform = 'mac';   -- 'all' rows, platform rows win
```

### 5.1 Where identity strings land

| surface | fed from |
|---|---|
| macOS `CFBundleName` / menu bar | `identity.name` |
| macOS `CFBundleDisplayName` / Dock / Finder | `identity.display_name` |
| macOS `CFBundleIdentifier` | `identity.bundle_id` (`.viewer` for the nested Go window) |
| `CFBundleShortVersionString` / `CFBundleVersion` | `identity.version` / `identity.build` |
| `LSMinimumSystemVersion` | `identity.macos_min_version` (web = 11.0, mac = 14.0) |
| `LSApplicationCategoryType`, `NSHumanReadableCopyright` | `identity.category`, `identity.copyright` |
| `CFBundleDocumentTypes` / `UTExportedTypeDeclarations` | `identity.doc_type_name` · `doc_uti` · `doc_extensions` · `doc_handler_rank` |
| browser tab / window title | `identity.window_title_format` = `{document} — {app}` |
| start-page heading + sub-line | `identity.wordmark` + `identity.tagline.start` |
| `<meta name="theme-color">`, PWA `manifest.webmanifest` | `identity.theme_color` · `background_color` · `name` · `tagline` · `homepage` |
| `<meta name="application-name">`, `apple-mobile-web-app-title` | `identity.name` |
| CLI `--version`, start-page footer | `identity.version` + `identity.version_line_format` |
| Linux `sqldoc.desktop` `Name` / `Comment` / `MimeType` | `identity.name` · `tagline` · `doc_extensions` |
| error dialogs ("sqldoc could not open a window") | `identity.name` |

### 5.2 Injecting it

**Swift** — `ConfigGen` emits:
* `Sources/SQLDocCore/Generated/AppIdentity.generated.swift` —
  `enum AppIdentity { static let name, version, bundleID, wordmark, taglineStart, windowTitleFormat, homepage }`.
  Replaces `let version = "0.3.0"` in `SQLDocCLI/main.swift`, the `"sqldoc"`
  literal in `StartPageView`, and the `" — sqldoc"` suffix wherever a title is
  built.
* `build/Info.plist` — fully rendered from `v_identity WHERE platform='mac'`
  plus the document-type block. The `Makefile` `app:` target stops `echo`-ing
  the plist and just `cp build/Info.plist …`. `Package.swift`'s
  `platforms: [.macOS(.v14)]` floor stays hand-set but must equal
  `identity.macos_min_version` for `mac` — `config-check` asserts it.

**Go** — `configgen` emits:
* `internal/buildinfo/identity.gen.go` — `const Name, Version, BundleID, …`;
  `cmd/sqldoc` and the launcher's error alerts read it.
* `packaging/macos/Info.plist` + `Viewer-Info.plist` — rendered from templates
  (`*.plist.tmpl`) with `{{.Name}} {{.Version}} {{.BundleID}} …`. Kills the
  `0.2.0` / `0.3.0` and `com.mavgo` / `com.darian` splits.
* `internal/ui/head.gen.html` — `<title>`, `<link rel="icon" sizes="32x32" href="/favicon-32.png">`,
  `<link rel="mask-icon">`, `apple-touch-icon`, `<meta name="theme-color">`,
  `<meta name="application-name">`, `<link rel="manifest" href="/manifest.webmanifest">`.
  `ui.go` gains a `{{HEAD_EXTRA}}` slot; the start-page `<h1>sqldoc</h1>` becomes
  `{{WORDMARK}}`.
* `internal/server` serves `/favicon.ico`, `/favicon-32.png`, `/apple-touch-icon.png`,
  `/manifest.webmanifest` (rendered from `identity`) and the two PNGs — all from
  `embed.FS`.

### 5.3 The icon

The mark is the **tangerine** icon from the sqldoc (Go) repo — a photo on a
charcoal rounded square, not vector. Two committed assets, both from
`sqldoc/packaging/macos/sqldoc.icns`:

| asset | how | feeds |
|---|---|---|
| `config/assets/AppIcon.icns` | verbatim copy of `sqldoc.icns` | macOS `CFBundleIconFile`; `make app` copies it into the bundle |
| `config/assets/icon-master.png` | its 1024px face (`iconutil --convert iconset`) | `make icons` renders the web raster set from this |

`make icons` → `scripts/gen-icons.sh` reads `icon_target` and scales
`icon-master.png` (via `sips` or ImageMagick) into the sqldoc web set —
`favicon.ico`, `favicon-32.png`, `apple-touch-icon.png`, `icon-192/512.png`
(needs `--sqldoc ../sqldoc`). The `.icns` files are not regenerated: `sqldoc.icns`
is upstream, `AppIcon.icns` is its copy. To change the icon, replace
`sqldoc.icns` upstream and re-copy both assets.

## 6. Drift this exercise found

Reconciled in `seed.sql`; the `override` rows are the remaining debt to pay
down (delete each row once both platforms match the canonical value):

| concern | web today | mac today | canonical | status |
|---|---|---|---|---|
| data row height | 28 px | 26 px | **28** | `override(token,row-height,mac,26)` |
| zoom range | 0.6–3.0 | 0.7–2.0 | **0.6–3.0** | `override(setting,zoom.max,mac,2.0)` |
| zoom step | ×1.1 | +0.1 | **×1.1** | `override(setting,zoom.step_mode,mac,add)` |
| rows per fetch | 200 (windowed) | 100 (paginated) | **200** | `override(setting,window.block_rows,mac,100)` — architectural, not cosmetic |
| gallery default view | auto-detected | manual toggle only | **auto** | mac needs `defaultView()` port (`gallery.auto_*` settings) |
| ⌘G | next find match | toggle gallery | **⌘G next match · ⌘⇧G prev match · ⌘⌥G gallery** | keybinding table resolves it |
| version string | `0.2.0` (plist) | `0.3.0` (CLI + Makefile) | **`identity.version`** | one row |
| bundle id | `com.mavgo.sqldoc` | `com.darian.sqldoc` | **`com.mavgo.sqldoc`** | `identity.bundle_id` |
| doc type name | "SQLite database" | "SQLite Database" | **"SQLite database"** | `identity.doc_type_name` |
| `LSHandlerRank` | `Owner` | `Alternate` | keep both | `identity.doc_handler_rank` per platform |
| app icon | tangerine `sqldoc.icns` | none | **share `sqldoc.icns`** (copied to `config/assets/AppIcon.icns`) | `identity.icon.*` |
| favicon / theme-color / manifest | none | n/a | **generated** from `icon-master.png` + `identity` | `identity` + `icon_target` |
| accent default | `#2563eb` | `#2563eb` | match ✓ | — |
| connect pragmas | 5, via DSN/exec | same 5, via exec | match ✓ | now generated from one list |
| `_style` key aliases | 6 | 6 | match ✓ | now generated |
| column min/default width | 56 / measured | 100 / 120 | **56 / 120** | mac clamps to be re-derived from tokens |

## 7. Runtime interplay

`sqldoc.db` sets **defaults and bounds**. A document's `_style` table still wins
at runtime for exactly the keys `doc_convention` marks — and only tokens with
`token.overridable = 1` (currently just `accent`; `theme` swaps the whole
light/dark token set; `title` is not a token). Codegen emits both the default
value and the "this one is overridable" flag, so the runtime override path
stays a 3-key whitelist rather than "anything in `_style`".

## 8. Rollout

1. Land `config/*.sql` + `sqldoc.db` + `config/assets/{AppIcon.icns,icon-master.png}` + this doc. *(done)*
2. Swift `ConfigGen` + `Sources/SQLDocCore/Generated/`; `make generate` wired into `build`/`release`/`test`. *(done)*
3. `make generate` also renders `.build/Info.plist`; `make app` consumes it + `AppIcon.icns`. *(done)*
4. First consumers moved onto generated config: `applyPragmas()` → `sqldocConnectPragmas`, CLI `version` → `AppIdentity.version`. *(done)*
5. Migrate the rest of the `SQLDocCore` / `SQLDocApp` literals to `BehaviorConfig` / `DesignToken` / `TypeRoles` / `DocConventions` (see §3 table).
6. Go `configgen` + `tokens.gen.css` / `config.gen.js` / `config.gen.go` + plist templates + `head.gen.html` + served favicon/manifest.
7. `git init` in `sqlswift`; `make config-check` in CI for both repos.
8. Burn down the `override` table and the identity drift.
9. (opt) SwiftPM plugin + `go:generate` fully automated; drop generated files from git.
