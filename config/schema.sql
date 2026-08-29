-- sqldoc.db — authoritative build-time configuration
-- ==================================================
-- Single source of truth for every style token, layout dimension, engine
-- tunable, keybinding and SQLite pragma used by ANY sqldoc frontend:
--
--   * the Go / browser viewer  (github.com/darianmavgo/sqldoc)
--   * the Swift / macOS app     (this repo, sqlswift)
--   * the CLI on both
--
-- It is consumed ONLY at build time, by codegen (see docs/build-config.md).
-- It is never shipped in a binary and never opened at runtime. A document's
-- own `_style` / `_nav` tables still override a small, explicitly-marked
-- subset at runtime (see `token.overridable` and the `doc_convention` table).
--
-- Rebuild the binary from this file:
--     sqlite3 sqldoc.db < config/schema.sql && sqlite3 sqldoc.db < config/seed.sql
-- or:  make config

PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS meta;
DROP TABLE IF EXISTS platform;
DROP TABLE IF EXISTS token;
DROP TABLE IF EXISTS setting;
DROP TABLE IF EXISTS setting_enum;
DROP TABLE IF EXISTS override;
DROP TABLE IF EXISTS type_role;
DROP TABLE IF EXISTS keybinding;
DROP TABLE IF EXISTS connect_pragma;
DROP TABLE IF EXISTS doc_convention;
DROP TABLE IF EXISTS identity;
DROP TABLE IF EXISTS icon_target;

-- ---------------------------------------------------------------------------
-- meta: schema version + provenance. Read by codegen to stamp generated files.
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- platform: the build targets a row of config can be scoped to.
CREATE TABLE platform (
  id    TEXT PRIMARY KEY,   -- 'all' | 'web' | 'mac' | 'cli'
  label TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- token: design tokens. Colours, dimensions, durations, opacities, raw font
-- metrics. `name` is kebab-case and maps to `--name` in CSS and
-- `DesignToken.name` (camelCased) in Swift.
CREATE TABLE token (
  name        TEXT PRIMARY KEY,
  category    TEXT NOT NULL              -- color | dimension | duration | opacity | number | font-size | font-weight
              CHECK (category IN ('color','dimension','duration','opacity','number','font-size','font-weight')),
  value_light TEXT NOT NULL,             -- canonical value; for non-colour tokens this is the only value
  value_dark  TEXT,                      -- colour only; NULL => identical in dark mode
  unit        TEXT NOT NULL DEFAULT '',  -- 'px' | 'ms' | '' ...
  platform    TEXT NOT NULL DEFAULT 'all' REFERENCES platform(id),
  overridable INTEGER NOT NULL DEFAULT 0 -- 1 => a document's _style may replace this at runtime
              CHECK (overridable IN (0,1)),
  description TEXT NOT NULL DEFAULT '',
  sort_order  INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- setting: behaviour / engine tunables that are not visual tokens.
CREATE TABLE setting (
  key         TEXT PRIMARY KEY,          -- dot.namespaced, e.g. 'window.block_rows'
  value       TEXT NOT NULL,
  value_type  TEXT NOT NULL
              CHECK (value_type IN ('int','float','bool','string','enum','duration')),
  unit        TEXT NOT NULL DEFAULT '',
  min_value   TEXT,                       -- inclusive; NULL => unbounded
  max_value   TEXT,
  platform    TEXT NOT NULL DEFAULT 'all' REFERENCES platform(id),
  description TEXT NOT NULL DEFAULT '',
  sort_order  INTEGER NOT NULL DEFAULT 0
);

-- allowed values for value_type = 'enum' settings.
CREATE TABLE setting_enum (
  setting_key TEXT NOT NULL REFERENCES setting(key),
  value       TEXT NOT NULL,
  label       TEXT NOT NULL,
  ordinal     INTEGER NOT NULL,
  PRIMARY KEY (setting_key, value)
);

-- ---------------------------------------------------------------------------
-- override: a per-platform replacement value for one token or setting. Codegen
-- for platform P uses override.value when (kind, ref, P) exists, else the base.
-- This is where deliberate platform divergence is recorded and justified,
-- instead of drifting silently in two codebases.
CREATE TABLE override (
  kind      TEXT NOT NULL CHECK (kind IN ('token','setting')),
  ref       TEXT NOT NULL,               -- token.name or setting.key
  platform  TEXT NOT NULL REFERENCES platform(id),
  value     TEXT NOT NULL,
  reason    TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (kind, ref, platform)
);

-- ---------------------------------------------------------------------------
-- type_role: named typographic roles, one level up from raw font-size tokens.
-- Codegen emits a Font/CSS rule per role.
CREATE TABLE type_role (
  role             TEXT PRIMARY KEY,      -- body | grid-cell | grid-cell-mono | grid-header | status | title | tagline
  font_family      TEXT NOT NULL DEFAULT 'system'  CHECK (font_family IN ('system','mono')),
  size_px          REAL NOT NULL,
  weight           INTEGER NOT NULL DEFAULT 400,
  line_height      REAL NOT NULL DEFAULT 1.4,
  tracking_px      REAL NOT NULL DEFAULT 0,
  scales_with_zoom INTEGER NOT NULL DEFAULT 1 CHECK (scales_with_zoom IN (0,1)),
  platform         TEXT NOT NULL DEFAULT 'all' REFERENCES platform(id),
  description      TEXT NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------------------
-- keybinding: canonical shortcuts. `chord` is a portable spelling that codegen
-- translates: 'mod' => Cmd (mac) / Ctrl (web).
CREATE TABLE keybinding (
  action    TEXT PRIMARY KEY,
  chord     TEXT NOT NULL,                -- 'mod+f', 'shift+enter', 'pagedown', 'mod+shift+g'
  context   TEXT NOT NULL DEFAULT 'global' CHECK (context IN ('global','table','find','gallery')),
  label     TEXT NOT NULL,
  platform  TEXT NOT NULL DEFAULT 'all' REFERENCES platform(id)
);

-- ---------------------------------------------------------------------------
-- connect_pragma: PRAGMAs applied to every read-only connection sqldoc opens.
CREATE TABLE connect_pragma (
  name       TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  platform   TEXT NOT NULL DEFAULT 'all' REFERENCES platform(id),
  rationale  TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- doc_convention: the contract a document uses to describe itself. Codegen
-- emits the key-alias switch in loadStyle() and the hidden-table rule from
-- here, so the two ports cannot disagree about what `_style` accepts.
CREATE TABLE doc_convention (
  name        TEXT PRIMARY KEY,          -- '_style.accent', '_nav', 'hidden-prefix' ...
  kind        TEXT NOT NULL CHECK (kind IN ('meta-table','style-key','style-key-alias','nav-column','rule')),
  canonical   TEXT NOT NULL DEFAULT '',  -- for aliases: the canonical key they map to
  detail      TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------------------
-- identity: what the application is CALLED and how it identifies itself, on
-- every surface — macOS bundle, browser tab + PWA manifest, CLI, .desktop
-- entry, window titles, error dialogs. One row per (key, platform); a
-- platform-specific row shadows the 'all' row for that platform.
CREATE TABLE identity (
  key         TEXT NOT NULL,
  platform    TEXT NOT NULL DEFAULT 'all' REFERENCES platform(id),
  value       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (key, platform)
);

-- icon_target: every derived icon file, rendered from a single master asset by
-- `make icons` (scripts/gen-icons.sh). The master itself is identity key
-- 'icon.master'. `sizes` is a CSV of pixel sizes to bake in (empty = vector or
-- format-native). `consumer` says who references the output.
CREATE TABLE icon_target (
  path        TEXT PRIMARY KEY,        -- output path, relative to the repo that consumes it
  repo        TEXT NOT NULL,           -- 'sqlswift' | 'sqldoc'
  format      TEXT NOT NULL CHECK (format IN ('icns','iconset','png','ico','svg')),
  sizes       TEXT NOT NULL DEFAULT '',
  platform    TEXT NOT NULL REFERENCES platform(id),
  consumer    TEXT NOT NULL DEFAULT ''  -- CFBundleIconFile | favicon | apple-touch-icon | manifest | document-icon
              ,
  description TEXT NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------------------
-- Convenience views for codegen / inspection.
CREATE VIEW v_identity AS
  SELECT p.id AS platform, i.key,
         COALESCE(spec.value, base.value) AS value,
         COALESCE(spec.description, base.description) AS description
  FROM platform p
  JOIN (SELECT DISTINCT key FROM identity) i
  LEFT JOIN identity base ON base.key = i.key AND base.platform = 'all'
  LEFT JOIN identity spec ON spec.key = i.key AND spec.platform = p.id
  WHERE p.id <> 'all' AND COALESCE(spec.value, base.value) IS NOT NULL;

CREATE VIEW v_token_resolved AS
  SELECT t.name, t.category, t.unit, t.overridable, t.description, t.sort_order,
         p.id AS platform,
         COALESCE(o.value, t.value_light) AS value_light,
         CASE WHEN t.category = 'color'
              THEN COALESCE(o.value, t.value_dark, t.value_light) END AS value_dark
  FROM token t
  CROSS JOIN platform p
  LEFT JOIN override o ON o.kind='token' AND o.ref=t.name AND o.platform=p.id
  WHERE p.id <> 'all' AND t.platform IN ('all', p.id);

CREATE VIEW v_setting_resolved AS
  SELECT s.key, s.value_type, s.unit, s.min_value, s.max_value, s.description,
         p.id AS platform,
         COALESCE(o.value, s.value) AS value
  FROM setting s
  CROSS JOIN platform p
  LEFT JOIN override o ON o.kind='setting' AND o.ref=s.key AND o.platform=p.id
  WHERE p.id <> 'all' AND s.platform IN ('all', p.id);
