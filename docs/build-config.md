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
| `icon_target` | every derived icon file + sizes + consumer | `make icons` renders each from `config/assets/icon.svg` |

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

```make
# Makefile
config:            ## rebuild sqldoc.db from config/*.sql
	rm -f sqldoc.db
	sqlite3 sqldoc.db < config/schema.sql
	sqlite3 sqldoc.db < config/seed.sql

generate: config   ## regenerate all platform config from sqldoc.db
	swift run ConfigGen            # Swift side (this repo)
	# cd ../sqldoc && go generate ./...   # Go side

config-check: generate  ## CI: fail if generated files are stale
	git diff --exit-code
```

Commit `sqldoc.db` **and** the generated files. `config-check` in CI guarantees
they never drift from the SQL.

## 3. Injection — Swift / macOS

**New executable target** `ConfigGen` (`Sources/ConfigGen/main.swift`), depends
only on `Foundation` + `SQLite3` (already a system lib here). It reads
`sqldoc.db` and writes into `Sources/SQLDocCore/Generated/`:

```
DesignTokens.generated.swift    enum DesignToken  { colours, dimensions, durations }
BehaviorConfig.generated.swift  enum BehaviorConfig { every setting, typed }
TypeRoles.generated.swift       enum TypeRole -> Font
Keybindings.generated.swift     struct AppShortcuts { KeyboardShortcut per action }
ConnectPragmas.generated.swift  let connectPragmas: [String]
DocConventions.generated.swift  styleKeyAlias: [String:String], hiddenPrefix
```

Shape of the generated token enum (colours resolve light/dark at runtime via a
tiny hand-written `Color(light:dark:)` helper in core, *not* generated):

```swift
public enum DesignToken {
    public static let page       = Color(light: 0xFFFFFF, dark: 0x202124)
    public static let ink        = Color(light: 0x202124, dark: 0xE8EAED)
    public static let accent     = Color(light: 0x2563EB, dark: 0x2563EB)   // overridable
    public static let rowHeight:      CGFloat = 26      // ← override(token,row-height,mac)
    public static let toolbarHeight:  CGFloat = 40
    public static let colMinWidth:    CGFloat = 56
    public static let transitionFast: Duration = .milliseconds(120)
}

public enum BehaviorConfig {
    public static let windowBlockRows            = 100   // ← override(setting,window.block_rows,mac)
    public static let findChunkRows:      Int64  = 250_000
    public static let colwidthSampleAnchors      = 24
    public static let colwidthSampleRowsPerAnchor = 12
    public static let galleryMinTables           = 3
    public static let galleryMaxTableRowEstimate = 50
    public static let zoomMin                    = 0.6
    public static let zoomMax                    = 2.0   // ← override
    public static let zoomStepMode               = ZoomStepMode.add   // ← override
}
```

Then delete the scattered literals and point the code at the enum:

| today | becomes |
|---|---|
| `Doc.sampleAnchors = 24` (ColumnSampler.swift) | `BehaviorConfig.colwidthSampleAnchors` |
| `Doc.findChunk = 250_000` (Finder.swift) | `BehaviorConfig.findChunkRows` |
| `Style(accent: "#2563eb", theme: "auto")` (Style.swift) | `Style(accent: DesignToken.accentHex, theme: "auto")` |
| `26 * appVM.zoomScale` (VirtualizedGridView) | `DesignToken.rowHeight * appVM.zoomScale` |
| `zoomScale = min(2.0, …)` (AppViewModel) | clamp to `BehaviorConfig.zoomMax`, step per `zoomStepMode` |
| `gutterWidth = 60` | `DesignToken.gutterMinWidth` |
| `applyPragmas()` literal array (SQLiteConnection) | `connectPragmas` (generated) |
| `loadStyle()` `switch key` aliases (Doc.swift) | `DocConventions.styleKeyAlias` |
| `.keyboardShortcut("g", modifiers: .command)` for gallery (SQLDocApp.swift) | generated — resolves the ⌘G collision, see §5 |

**Phase 1** (recommended first): `ConfigGen` writes committed files; run via
`make generate`. Works in Xcode with zero plugin friction.
**Phase 2**: wrap `ConfigGen` in a SwiftPM build-tool plugin attached to
`SQLDocCore` so regen is automatic and the `Generated/` dir leaves git.

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
* `internal/ui/head.gen.html` — `<title>`, `<link rel="icon" href="/icon.svg">`,
  `<link rel="mask-icon">`, `apple-touch-icon`, `<meta name="theme-color">`,
  `<meta name="application-name">`, `<link rel="manifest" href="/manifest.webmanifest">`.
  `ui.go` gains a `{{HEAD_EXTRA}}` slot; the start-page `<h1>sqldoc</h1>` becomes
  `{{WORDMARK}}`.
* `internal/server` serves `/favicon.ico`, `/icon.svg`, `/apple-touch-icon.png`,
  `/manifest.webmanifest` (rendered from `identity`) and the two PNGs — all from
  `embed.FS`.

### 5.3 The icon

One master, `config/assets/icon.svg` (1024²). `make icons` runs
`scripts/gen-icons.sh`, which reads the `icon_target` table and renders each
row from the master:

| output | repo | what it feeds |
|---|---|---|
| `config/assets/AppIcon.icns` + `Sources/SQLDocApp/Resources/AppIcon.icns` | sqlswift | SwiftUI `CFBundleIconFile` |
| `packaging/macos/sqldoc.icns` | sqldoc | Go bundle + nested viewer |
| `internal/ui/assets/icon.svg` · `favicon.ico` · `apple-touch-icon.png` · `icon-192.png` · `icon-512.png` | sqldoc | web favicon / manifest |

Rasteriser: `rsvg-convert`, `resvg`, or `sips`; `.icns` via `iconutil`. Commit
the generated icons (they change rarely); `config-check` flags them stale.
A separate `config/assets/icon-document.svg` (optional) drives the `.db`
file-type icon; without it the app icon is reused.

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
| app icon | `sqldoc.icns` present | none | **one master SVG → all** | `icon_target` |
| favicon / theme-color / manifest | none | n/a | **generated** | `identity` + `icon_target` |
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

1. Land `config/*.sql` + `sqldoc.db` + `config/assets/icon.svg` + this doc. *(done)*
2. Swift `ConfigGen` + committed `Generated/`; migrate `SQLDocCore` literals.
3. Migrate `SQLDocApp` view literals to `DesignToken` / `TypeRole`; wire `AppIdentity` + generated `Info.plist`.
4. `make icons`; commit the rendered `.icns` and web icon set.
5. Go `configgen` + `tokens.gen.css` / `config.gen.js` / `config.gen.go` + plist templates + `head.gen.html` + served favicon/manifest.
6. `make config-check` in CI for both repos.
7. Burn down the `override` table and the identity drift.
8. (opt) SwiftPM plugin + `go:generate` fully automated; drop generated files from git.
