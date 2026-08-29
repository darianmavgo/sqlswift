-- sqldoc.db — seed data
-- ======================
-- Run after schema.sql. Values are the canonical, cross-platform choice.
-- Where the Go viewer and the Swift app currently disagree, the row here is
-- the value BOTH should converge on; genuine, intentional divergence goes in
-- the `override` table with a reason.

BEGIN;

-- ---------------------------------------------------------------------------
INSERT INTO meta(key,value) VALUES
  ('schema_version','1'),
  ('updated','2026-08-29'),
  ('spec','docs/build-config.md'),
  ('note','Build-time only. Never opened at runtime. Regenerate binaries with `make config`.');

INSERT INTO platform(id,label) VALUES
  ('all','All platforms'),
  ('web','Go / browser viewer'),
  ('mac','Swift / macOS app'),
  ('cli','Command line (both)');

-- ---------------------------------------------------------------------------
-- COLOUR TOKENS  (light value / dark value; NULL dark => same in both)
INSERT INTO token(name,category,value_light,value_dark,unit,platform,overridable,description,sort_order) VALUES
  ('toolbar',        'color','#323639', NULL,      '', 'all', 0, 'Top chrome bar background',                     10),
  ('toolbar-fg',     'color','#e8eaed', NULL,      '', 'all', 0, 'Text/icons on the toolbar',                     11),
  ('toolbar-dim',    'color','#9aa0a6', NULL,      '', 'all', 0, 'Secondary text on the toolbar (row meta)',      12),
  ('toolbar-sep',    'color','#5f6368', NULL,      '', 'all', 0, 'Vertical divider inside the toolbar',           13),
  ('page',           'color','#ffffff','#202124',  '', 'all', 0, 'Sheet / document surface',                      20),
  ('ground',         'color','#d6d9dc','#16171a',  '', 'all', 0, 'Area behind the sheet; window background',       21),
  ('ink',            'color','#202124','#e8eaed',  '', 'all', 0, 'Primary text',                                  22),
  ('dim',            'color','#5f6368','#9aa0a6',  '', 'all', 0, 'Secondary text (headers, NULL, gutter)',         23),
  ('rule',           'color','#e3e5e8','#35373b',  '', 'all', 0, 'Hairline grid lines',                           24),
  ('rule-strong',    'color','#c8cbcf','#4a4d52',  '', 'all', 0, 'Emphasised borders (header underline, panels)',  25),
  ('head',           'color','#f5f6f7','#292a2d',  '', 'all', 0, 'Column header + gutter + status bar fill',        26),
  ('skeleton',       'color','#eceef0','#2a2c2f',  '', 'all', 0, 'Loading placeholder bars',                       27),
  ('accent',         'color','#2563eb', NULL,      '', 'all', 1, 'Primary accent colour', 30),
  ('mark-bg',        'color','#ffd54f', NULL,      '', 'all', 0, 'Find-match highlight background',                 31),
  ('mark-fg',        'color','#202124', NULL,      '', 'all', 0, 'Find-match highlight text',                       32),
  ('status-ok',      'color','#1e8e3e', NULL,      '', 'all', 0, 'Fast query timing badge',                        33),
  ('status-warn',    'color','#e37400', NULL,      '', 'all', 0, 'Slow query timing badge',                        34),
  ('status-error',   'color','#d93025', NULL,      '', 'all', 0, 'Error text',                                     35);

-- LAYOUT / DIMENSION TOKENS  (px)
INSERT INTO token(name,category,value_light,unit,platform,description,sort_order) VALUES
  ('row-height',              'dimension','28','px','all','Data row height at zoom 1 (also the header height)', 100),
  ('toolbar-height',          'dimension','40','px','all','Top chrome bar height',                             101),
  ('status-height',           'dimension','22','px','all','Bottom status bar height',                          102),
  ('gutter-min-width',        'dimension','64','px','all','Row-number gutter minimum width (grows with digits)',103),
  ('col-min-width',           'dimension','56','px','all','Auto-measured column minimum width',                104),
  ('col-max-width',           'dimension','460','px','all','Auto-measured column maximum width',               105),
  ('col-default-width',       'dimension','120','px','all','Column width before measurement lands',            106),
  ('col-autofit-max-width',   'dimension','900','px','all','Ceiling when double-clicking a column edge to fit',107),
  ('col-fill-min-width',      'dimension','48','px','all','A column is never squeezed below this by fit-to-width',108),
  ('cell-pad-x',              'dimension','10','px','all','Horizontal padding inside a cell',                  109),
  ('grip-hit-width',          'dimension','7','px','all','Clickable width of a column-resize grip',            110),
  ('start-max-width',         'dimension','620','px','all','Start page content column max width',              111),
  ('gallery-card-min-width',  'dimension','360','px','all','Gallery mini-table minimum width',                 112),
  ('gallery-card-max-width',  'dimension','540','px','all','Gallery mini-table maximum width',                 113),
  ('gallery-padding',         'dimension','18','px','all','Padding around the gallery grid',                   114),
  ('find-input-width',        'dimension','190','px','all','Find field text input width',                      115),
  ('radius-control',          'dimension','4','px','all','Corner radius: buttons, selects, small chips',       116),
  ('radius-panel',            'dimension','8','px','all','Corner radius: find bar, drop target, busy dialog',  117),
  ('radius-card',             'dimension','8','px','all','Corner radius: gallery cards, recent rows',          118),
  ('window-min-width',        'dimension','700','px','mac','Main window minimum width',                        119),
  ('window-min-height',       'dimension','450','px','mac','Main window minimum height',                       120);

-- CSS-surfaced DURATION + OPACITY + NUMBER TOKENS
INSERT INTO token(name,category,value_light,unit,platform,description,sort_order) VALUES
  ('transition-fast',   'duration','120','ms','all','Generic UI transition (find progress, hovers)',        200),
  ('pulse-period',      'duration','1100','ms','all','Indeterminate busy-bar pulse period',                 201),
  ('row-stripe-mix',    'opacity','0.45','','all','Zebra stripe: fraction of --head mixed over transparent',210),
  ('hit-mix',           'opacity','0.16','','all','Find-hit row tint: fraction of --accent',                211),
  ('cursor-mix',        'opacity','0.30','','all','Current find-match row tint: fraction of --accent',       212),
  ('zoom-default',      'number','1','','all','Initial zoom multiplier',                                     213);

-- ---------------------------------------------------------------------------
-- BEHAVIOUR / ENGINE SETTINGS
INSERT INTO setting(key,value,value_type,unit,min_value,max_value,platform,description,sort_order) VALUES
  -- windowed reads
  ('window.block_rows',              '200','int','rows','20','1000','all','Rows per fetched window during virtualized scroll',            300),
  ('window.max_rows',               '1000','int','rows','100','100000','all','Hard cap on a single rows request',                          301),
  ('window.default_rows',            '100','int','rows','10','1000','all','Rows returned when a request omits a limit',                    302),
  ('window.overscan_rows',             '8','int','rows','0','64','web','Rows rendered above/below the viewport',                          303),
  ('window.max_sizer_px',       '15000000','int','px','1000000',NULL,'web','Scroll element height ceiling before native scrolling drifts', 304),
  ('window.block_cache_limit',        '60','int','windows','4','1000','web','Max fetched windows kept in memory',                          305),
  ('window.block_cache_evict_distance','24','int','windows','2','1000','web','Evict cached windows farther than this from the viewport',   306),
  ('window.prefetch_blocks',           '1','int','windows','0','8','web','Windows to prefetch ahead in the scroll direction',             307),
  -- row count
  ('count.poll_fast_ms',             '120','int','ms','10','5000','all','Count re-poll interval, first few tries',                        320),
  ('count.poll_slow_ms',             '700','int','ms','50','10000','all','Count re-poll interval after the fast tries',                    321),
  ('count.poll_fast_iterations',       '5','int','','1','100','all','How many polls use the fast interval',                              322),
  ('count.poll_max_iterations',      '600','int','','1','100000','all','Give up polling for an exact count after this many tries',        323),
  -- column width sampling
  ('colwidth.sample_anchors',         '24','int','','1','256','all','Index-seek anchor points for the background width sample',           340),
  ('colwidth.sample_rows_per_anchor', '12','int','rows','1','256','all','Rows read forward from each anchor',                             341),
  ('colwidth.sample_text_max_len',   '256','int','chars','16','4096','all','Longest value string retained per column',                    342),
  ('colwidth.measure_row_sample',     '40','int','rows','5','500','web','Rows of the first window sampled for the initial measure',       343),
  ('colwidth.poll_ms',               '300','int','ms','50','5000','all','Interval to poll for the background sample result',              344),
  ('colwidth.poll_max_iterations',    '20','int','','1','1000','all','Stop polling for the sample after this many tries',                 345),
  -- find
  ('find.chunk_rows',             '250000','int','rows','1000',NULL,'all','Rows scanned per find increment',                              360),
  ('find.page_limit',                 '50','int','matches','1','200','all','Matches requested per find call',                             361),
  ('find.page_limit_max',            '200','int','matches','1','1000','all','Server cap on matches per find call',                        362),
  ('find.match_cap',                '5000','int','matches','100','1000000','all','Stop collecting matches once this many are known',       363),
  ('find.debounce_ms',               '180','int','ms','0','2000','all','Delay after last keystroke before a search starts',               364),
  ('find.tick_sleep_ms',              '10','int','ms','0','1000','all','Pause between find increments to keep the UI responsive',         365),
  -- gallery / default view
  ('gallery.enabled',               'true','bool','',NULL,NULL,'all','Offer the multi-table gallery view at all',                         380),
  ('gallery.auto_default',          'true','bool','',NULL,NULL,'all','Open into gallery automatically for small lookup-table documents', 381),
  ('gallery.min_tables',               '3','int','tables','2','100','all','Fewest visible tables for gallery to be the default view',      382),
  ('gallery.max_table_row_estimate',  '50','int','rows','1','100000','all','A table above this many rows disqualifies gallery-as-default', 383),
  ('gallery.check_cap',               '12','int','tables','1','1000','all','Stop checking table sizes for default-view once this many seen',384),
  ('gallery.row_cap',                '200','int','rows','1','10000','all','Rows rendered per table inside the gallery',                    385),
  -- zoom
  ('zoom.min',                       '0.6','float','x','0.1','1','all','Minimum zoom multiplier',                                         400),
  ('zoom.max',                       '3.0','float','x','1','8','all','Maximum zoom multiplier',                                           401),
  ('zoom.step',                      '1.1','float','','1.01','2','all','Zoom step; interpretation set by zoom.step_mode',                  402),
  ('zoom.step_mode',            'multiply','enum','',NULL,NULL,'all','Whether a zoom step multiplies or adds',                            403),
  ('zoom.default',                   '1.0','float','x','0.1','8','all','Zoom on document open and on reset',                              404),
  -- timing badge
  ('timing.slow_threshold_us',     '15000','int','us','0',NULL,'all','Query time at/above which the timing badge turns amber',           420),
  -- opening / session
  ('open.immutable_default',       'false','bool','',NULL,NULL,'all','Default for the immutable (skip-locking) open promise',           440),
  ('open.deadline_ms',             '60000','int','ms','1000',NULL,'all','How long the window waits on a slow open before giving up',       441),
  ('recents.max_stored',              '20','int','','0','500','all','Recent documents retained',                                         442),
  ('recents.max_shown',                '8','int','','0','50','all','Recent documents listed on the start page',                          443),
  ('text.cell_display_max_chars',    '400','int','chars','40','10000','all','Cell text truncated for display beyond this length',          444),
  -- server (web only)
  ('server.port_default',              '0','int','','0','65535','web','TCP port; 0 picks a free one',                                     460),
  ('server.open_browser_default',   'true','bool','',NULL,NULL,'web','Launch the browser after starting the server',                    461);

INSERT INTO setting_enum(setting_key,value,label,ordinal) VALUES
  ('zoom.step_mode','multiply','Multiply by step',0),
  ('zoom.step_mode','add','Add step',1);

-- ---------------------------------------------------------------------------
-- INTENTIONAL / HISTORICAL PLATFORM DIVERGENCE
-- (each row is a debt to pay down; delete it when the platforms converge)
INSERT INTO override(kind,ref,platform,value,reason) VALUES
  ('setting','window.block_rows','mac','100',
   'Swift VirtualizedGridView is button-paginated today, not a windowed scroller. Drop this row when it scrolls like the web grid.'),
  ('setting','zoom.step_mode','mac','add',
   'Swift AppViewModel currently does zoomScale += 0.1. Align to multiply, then delete.'),
  ('setting','zoom.max','mac','2.0',
   'Swift clamps zoom to 2.0. Raise to 3.0 to match web, then delete.'),
  ('token','row-height','mac','26',
   'Swift grid uses 26px rows. Adopt 28 for parity, then delete.');

-- ---------------------------------------------------------------------------
-- TYPOGRAPHY ROLES
INSERT INTO type_role(role,font_family,size_px,weight,line_height,tracking_px,scales_with_zoom,platform,description) VALUES
  ('body',            'system',13,400,1.40, 0.0,0,'all','Base UI font'),
  ('grid-cell',       'system',13,400,1.40, 0.0,1,'all','Text cell in the data grid'),
  ('grid-cell-mono',  'mono',  12,400,1.40, 0.0,1,'all','Numeric / blob cell in the data grid'),
  ('grid-header',     'system',13,600,1.40, 0.0,1,'all','Column header label'),
  ('grid-gutter',     'mono',  12,400,1.40, 0.0,1,'all','Row-number gutter'),
  ('column-type',     'system',11,400,1.40, 0.0,1,'all','Type annotation beside a column name'),
  ('status',          'system',11,400,1.40, 0.0,0,'all','Bottom status bar text'),
  ('recent-path',     'system',12,400,1.40, 0.0,0,'all','Path shown in a recent-files row'),
  ('title',           'system',30,600,1.10,-0.4,0,'all','Start page wordmark / big headings'),
  ('tagline',         'system',14,400,1.40, 0.0,0,'all','Start page tagline'),
  ('section-label',   'system',11,600,1.40, 0.8,0,'all','Uppercase section label (e.g. RECENT); render upper-cased'),
  ('error',           'mono',  12,400,1.40, 0.0,0,'all','Error overlay body');

-- ---------------------------------------------------------------------------
-- KEYBINDINGS  ('mod' => Cmd on mac, Ctrl on web)
INSERT INTO keybinding(action,chord,context,label,platform) VALUES
  ('open-database',    'mod+o',        'global','Open a database',            'all'),
  ('close-database',   'mod+w',        'global','Close the current database', 'all'),
  ('find',             'mod+f',        'table', 'Find in table',              'all'),
  ('find-next',        'enter',        'find',  'Next match',                 'all'),
  ('find-prev',        'shift+enter',  'find',  'Previous match',             'all'),
  ('find-next-doc',    'mod+g',        'table', 'Next match (bar closed)',    'all'),
  ('find-prev-doc',    'mod+shift+g',  'table', 'Previous match (bar closed)','all'),
  ('find-close',       'escape',       'find',  'Close the find bar',         'all'),
  ('gallery-toggle',   'mod+alt+g',    'global','Toggle the gallery view',    'all'),
  ('zoom-in',          'mod+plus',     'table', 'Zoom in',                    'all'),
  ('zoom-out',         'mod+minus',    'table', 'Zoom out',                   'all'),
  ('zoom-reset',       'mod+0',        'table', 'Actual size',                'all'),
  ('export-csv',       'mod+e',        'table', 'Export table as CSV',        'all'),
  ('row-down',         'arrowdown',    'table', 'Move down one row',          'all'),
  ('row-up',           'arrowup',      'table', 'Move up one row',            'all'),
  ('page-down',        'pagedown',     'table', 'Move down one screen',       'all'),
  ('page-up',          'pageup',       'table', 'Move up one screen',         'all'),
  ('page-down-space',  'space',        'table', 'Move down one screen',       'web'),
  ('page-up-space',    'shift+space',  'table', 'Move up one screen',         'web'),
  ('doc-home',         'home',         'table', 'Jump to first row',          'all'),
  ('doc-end',          'end',          'table', 'Jump to last row',           'all');

-- ---------------------------------------------------------------------------
-- CONNECTION PRAGMAS  (applied to every read-only handle)
INSERT INTO connect_pragma(name,value,platform,rationale,sort_order) VALUES
  ('query_only',   '1',         'all','Hard guarantee this process never writes',                 0),
  ('cache_size',   '-65536',    'all','64 MiB page cache (negative = KiB)',                        1),
  ('mmap_size',    '268435456', 'all','256 MiB memory-mapped I/O, avoids read() syscalls',         2),
  ('temp_store',   '2',         'all','Keep temp b-trees in memory',                               3),
  ('busy_timeout', '5000',      'all','Wait up to 5s on a locked database rather than erroring',   4);

-- ---------------------------------------------------------------------------
-- SELF-DESCRIBING DOCUMENT CONTRACT
INSERT INTO doc_convention(name,kind,canonical,detail,description) VALUES
  ('_style','meta-table','','key TEXT, value TEXT','Optional key/value table a document uses to set presentation'),
  ('_head', 'meta-table','','key TEXT, value TEXT','Accepted alias for _style'),
  ('_nav',  'meta-table','','table_name TEXT, label TEXT, position INTEGER, hidden INTEGER','Optional table to rename, reorder and hide tables'),
  ('title', 'style-key','title','string','Window / document title'),
  ('accent','style-key','accent','#rrggbb','Overrides the --accent token for this document'),
  ('theme', 'style-key','theme','auto | light | dark','Forces a colour scheme for this document'),
  ('accent_color','style-key-alias','accent','','Alias accepted for the accent key'),
  ('accentcolor', 'style-key-alias','accent','','Alias accepted for the accent key'),
  ('dark_mode',   'style-key-alias','theme','','Alias accepted for the theme key'),
  ('darkmode',    'style-key-alias','theme','','Alias accepted for the theme key'),
  ('color_scheme','style-key-alias','theme','','Alias accepted for the theme key'),
  ('hidden-prefix','rule','_','Any table whose name begins with "_" is hidden from the viewer',''),
  ('humanize','rule','','snake_case -> Title Case; tokens that are already ALL-CAPS are kept as acronyms','How a table name becomes a display label when _nav gives none');

-- ---------------------------------------------------------------------------
-- APPLICATION IDENTITY
-- 'all' rows are canonical; a platform row overrides for that platform only.
INSERT INTO identity(key,platform,value,description) VALUES
  ('name',                'all','sqldoc','Short name: macOS CFBundleName / menu bar, CLI binary, meta[application-name]'),
  ('display_name',        'all','sqldoc','macOS CFBundleDisplayName / Finder / Dock'),
  ('wordmark',            'all','sqldoc','Text shown as the start-page heading'),
  ('tagline',             'all','A read-only viewer for SQLite.','One-liner: .desktop Comment, manifest description, about box'),
  ('tagline.start',       'all','Drop a SQLite database anywhere on this page, or open one.','Longer line under the start-page wordmark'),
  ('version',             'all','0.3.0','Marketing version: CFBundleShortVersionString, `--version`, start-page footer'),
  ('build',               'all','1','CFBundleVersion / build metadata'),
  ('bundle_id',           'all','com.mavgo.sqldoc','Primary macOS + UTI reverse-DNS prefix'),
  ('bundle_id.viewer',    'all','com.mavgo.sqldoc.viewer','Nested native-window bundle (Go sqldoc-view)'),
  ('category',            'all','public.app-category.developer-tools','macOS LSApplicationCategoryType'),
  ('copyright',           'all','(c) 2026 Darian Hickman','NSHumanReadableCopyright'),
  ('homepage',            'all','https://github.com/darianmavgo/sqldoc','About box, manifest, .desktop'),
  ('cli_name',            'all','sqldoc','Installed CLI binary name'),
  ('macos_min_version',   'web','11.0','LSMinimumSystemVersion for the Go bundle (AppKit only)'),
  ('macos_min_version',   'mac','14.0','LSMinimumSystemVersion for the SwiftUI app; also the Package.swift platform floor'),
  ('window_title_format', 'all','{document} — {app}','Window / browser-tab title; {document} = _style.title or filename'),
  ('version_line_format', 'all','{app} {version} · {driver}','Start-page footer / `--version` detail line'),
  ('doc_type_name',       'all','SQLite database','CFBundleTypeName / UTTypeDescription'),
  ('doc_uti',             'all','com.mavgo.sqldoc.sqlite','Exported UTI for the document type'),
  ('doc_extensions',      'all','db,sqlite,sqlite3,db3,s3db,sl3','File extensions the app claims'),
  ('doc_handler_rank',    'web','Owner','LSHandlerRank for the Go bundle'),
  ('doc_handler_rank',    'mac','Alternate','LSHandlerRank for the SwiftUI app (do not seize the type)'),
  ('theme_color',         'all','#323639','Browser chrome colour (meta theme-color / manifest) — tracks the --toolbar token'),
  ('background_color',    'all','#d6d9dc','PWA manifest background_color — tracks the --ground token'),
  -- The mark is the tangerine icon from the sqldoc (Go) repo — a photo, not
  -- vector. AppIcon.icns is committed verbatim (copied from
  -- sqldoc/packaging/macos/sqldoc.icns); icon-master.png is its 1024px face,
  -- used to render the web raster set and as a fallback.
  ('icon.appicns',        'all','config/assets/AppIcon.icns','Pre-rendered macOS icon, committed as-is; `make app` copies it into the bundle'),
  ('icon.master',         'all','config/assets/icon-master.png','1024x1024 PNG master for every rendered (non-.icns) icon size');

-- DERIVED ICON FILES  (rendered by scripts/gen-icons.sh from icon.master).
-- The two .icns files are NOT here: sqldoc/packaging/macos/sqldoc.icns is the
-- upstream source, and config/assets/AppIcon.icns is a verbatim copy of it.
INSERT INTO icon_target(path,repo,format,sizes,platform,consumer,description) VALUES
  ('internal/ui/assets/favicon.ico',          'sqldoc','ico','16,32,48','web','favicon','Legacy favicon, served at /favicon.ico'),
  ('internal/ui/assets/apple-touch-icon.png', 'sqldoc','png','180','web','apple-touch-icon','iOS / iPadOS home-screen icon'),
  ('internal/ui/assets/icon-192.png',         'sqldoc','png','192','web','manifest','PWA manifest icon'),
  ('internal/ui/assets/icon-512.png',         'sqldoc','png','512','web','manifest','PWA manifest icon'),
  ('internal/ui/assets/favicon-32.png',       'sqldoc','png','32','web','favicon','PNG favicon for modern browsers');

COMMIT;
