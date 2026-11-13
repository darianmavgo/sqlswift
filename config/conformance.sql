-- Banquet conformance ledger: the single source of truth for which Banquet rule
-- sqlswift implements, how well, what proves it and how to demonstrate it.
--
--   make conformance-db      builds docs/conformance/conformance.db from this file
--   make conformance-check   fails if a proof or shot points at something that is gone
--
-- Every page, slide and clip under docs/conformance/ is generated from these rows.
-- Not read by ConfigGen. Edit a row here when Banquet behaviour changes.

PRAGMA foreign_keys = ON;

CREATE TABLE standards (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  file        TEXT NOT NULL,   -- path from the repo root; banquet/ is a separate checkout
  banquet_rev TEXT             -- banquet commit the audit was made against; NULL = lives in this repo
);

CREATE TABLE rules (
  id           TEXT PRIMARY KEY,                 -- bar-2, grid-3a, url-5
  standard     TEXT NOT NULL REFERENCES standards(id),
  num          INTEGER,                          -- the number printed in the standard; NULL = unnumbered text
  level        TEXT NOT NULL CHECK (level IN ('MUST','SHOULD','recommended')),
  title        TEXT NOT NULL,
  text         TEXT NOT NULL,                    -- one-sentence summary of the rule, not a copy
  status       TEXT NOT NULL CHECK (status IN ('conforms','differs','missing','n/a')),
  note         TEXT,                             -- how sqlswift differs, or what is unverified
  how_to       TEXT,                             -- one plain sentence for a user
  demo_url     TEXT,                             -- Banquet URL that shows it, relative to the repo root
  confirmed_on TEXT                              -- date the owner looked at the shot and agreed; NULL = not yet
);

CREATE TABLE extras (
  id      TEXT PRIMARY KEY,                      -- A1, G5, Q6, E1
  area    TEXT NOT NULL CHECK (area IN ('bar','grammar','query','edit')),
  title   TEXT NOT NULL,
  symbols TEXT,                                  -- names to search for; no line numbers
  note    TEXT
);

CREATE TABLE proofs (
  rule_id TEXT NOT NULL REFERENCES rules(id),
  kind    TEXT NOT NULL CHECK (kind IN ('ui-case','runner','manual')),
  ref     TEXT NOT NULL,                         -- case name, runner test title, or what to look at
  PRIMARY KEY (rule_id, kind, ref)
);

CREATE TABLE shots (
  id        TEXT PRIMARY KEY,                    -- also the PNG / clip file name
  rule_id   TEXT NOT NULL REFERENCES rules(id),
  kind      TEXT NOT NULL CHECK (kind IN ('still','clip')),
  steps     TEXT NOT NULL,                       -- UICommands.swift vocabulary, one per line; {DB} = a copy of testdata/sample.db, {DBDIR} = its folder
  caption   TEXT NOT NULL,
  narration TEXT
);

CREATE TABLE _style (key TEXT PRIMARY KEY, value TEXT);

CREATE VIEW scorecard AS
SELECT s.id AS standard, s.title,
       count(r.id)                      AS rules,
       sum(r.status = 'conforms')       AS conforms,
       sum(r.status = 'differs')        AS differs,
       sum(r.status = 'missing')        AS missing,
       sum(r.status = 'conforms' AND NOT EXISTS (
             SELECT 1 FROM proofs p WHERE p.rule_id = r.id AND p.kind <> 'manual')) AS unproven,
       sum(r.confirmed_on IS NULL)      AS unconfirmed
FROM standards s LEFT JOIN rules r ON r.standard = s.id
GROUP BY s.id ORDER BY s.rowid;

CREATE VIEW gaps AS
SELECT id, level, status, title, note FROM rules
WHERE status IN ('differs','missing') ORDER BY status DESC, id;

-- Conforming rules with no automated test behind them.
CREATE VIEW unproven AS
SELECT r.id, r.level, r.title,
       (SELECT group_concat(ref, '; ') FROM proofs p WHERE p.rule_id = r.id) AS manual_evidence
FROM rules r
WHERE r.status = 'conforms'
  AND NOT EXISTS (SELECT 1 FROM proofs p WHERE p.rule_id = r.id AND p.kind <> 'manual')
ORDER BY r.id;

CREATE VIEW unconfirmed AS
SELECT id, status, title, demo_url FROM rules WHERE confirmed_on IS NULL ORDER BY id;

INSERT INTO _style VALUES
  ('title',  'Banquet conformance: sqlswift'),
  ('rules.columns', 'id,status,level,title,note');

-- ---------------------------------------------------------------- standards

INSERT INTO standards VALUES
  ('url',       'Banquet URL Syntax',               'banquet/standards/banquet-url-syntax.md',        '32838bf'),
  ('bar',       'Banquet Bar Style',                'banquet/standards/banquet-bar-style.md',         '32838bf'),
  ('grid',      'Banquet Grid Style',               'banquet/standards/banquet-grid-style.md',        '32838bf'),
  ('query',     'Banquet Query Style',              'banquet/standards/banquet-query-style.md',       '32838bf'),
  ('dblist',    'Banquet Collections & DB List Style', 'banquet/standards/banquet-db-list-style.md',  '32838bf'),
  ('tablelist', 'Banquet Table List Style',         'banquet/standards/banquet-table-list-style.md',  '32838bf'),
  ('edit',      'Banquet Edit Style (sqlswift, experimental)', 'docs/BanquetEditStyle.md',            NULL);

-- -------------------------------------------------------------------- rules
-- (id, standard, num, level, title, text, status, note, how_to, demo_url, confirmed_on)

INSERT INTO rules VALUES
('url-1','url',1,'MUST','Explicit notation',
 'dataset;table;column with semicolons is parsed without guessing.',
 'conforms',NULL,
 'Separate file, table and column with semicolons when a path is ambiguous.',
 'testdata/sample.db;telemetry;device_id',NULL),
('url-2','url',2,'MUST','Familiar syntax',
 'dataset/table/column with slashes; the dataset ends at the segment with a known file extension.',
 'conforms','Also accepts .sqlite3 .tsv .xls (extra G3).',
 'Type a path the way you would in Finder: file, then table, then columns.',
 'testdata/sample.db/telemetry/device_id,temperature',NULL),
('url-3','url',3,'MUST','Inferred defaults',
 'No columns means SELECT *; a one-table file may omit the table name.',
 'conforms','No slice means all rows up to window.all_rows_cap (extra Q6). Table guessing for one-table files has no test of its own.',
 'Name just the table to see every column.',
 'testdata/sample.db/telemetry',NULL),
('url-4','url',4,'MUST','Slice notation',
 '[start:end] in the path becomes OFFSET start, LIMIT end-start.',
 'conforms','Open bounds [a:] and [:b] also accepted (extra G6).',
 'Add [0:100] to see the first hundred rows.',
 'testdata/sample.db/telemetry[0:100]',NULL),
('url-5','url',5,'MUST','Sort',
 '+col sorts ascending, -col descending; orderby= does the same in the query string.',
 'conforms','A marker also names a shown column, and a hidden sort column moves to ?sort= (extra G5).',
 'Put a minus in front of a column name to sort by it, largest first.',
 'testdata/sample.db/telemetry/-id[0:100]',NULL),
('url-6','url',6,'MUST','Path equality',
 'Column!=Value in a path segment becomes a WHERE condition; where= carries complex filters.',
 'conforms','Also accepts = < > <= >= in the path (extra G4).',
 'Write status!=active after the table to leave those rows out.',
 'testdata/sample.db/devices/status!=active',NULL),
('url-6q','url',NULL,'MUST','Query string defaults to WHERE',
 'Any non-reserved ?parameter with a comparison operator is a WHERE condition; several are ANDed.',
 'conforms','The bar rewrites ?id>6000 as ?where=id > 6000.',
 'Type ?id>6000 after the table to filter without writing where=.',
 'testdata/sample.db/telemetry?id>6000',NULL),
('url-7','url',7,'MUST','Collections',
 'A path with no recognised extension names a container; the host answers with a catalog of the datasets under it.',
 'conforms','See dblist-* for how the catalog itself is built and drawn.',
 'Type a folder path to list every database in it.',
 'testdata/',NULL),

('bar-1','bar',1,'MUST','Editable address bar',
 'The bar is an editable text field at the top of the window.',
 'conforms',NULL,
 'Click the bar or press ⌘L and type.',
 'testdata/sample.db/telemetry',NULL),
('bar-2','bar',2,'MUST','Default focus',
 'The bar is focused on launch and after completing an action.',
 'differs','Focused on launch and with ⌘L. Not refocused after a submit, so the grid keeps arrow keys and ⌘F.',
 'Start typing as soon as the app opens.',
 NULL,NULL),
('bar-3','bar',3,'MUST','Context reflection',
 'The bar always shows the canonical Banquet URL of the current view.',
 'conforms',NULL,
 'Sort or filter in the grid and watch the bar rewrite itself; copy it to share the view.',
 'testdata/sample.db/telemetry/-id',NULL),
('bar-4','bar',4,'MUST','Evaluation on submit',
 'Return evaluates the typed URL, command or relative clause and syncs the bar to the result.',
 'conforms','Valid edits for the open table also apply 300 ms after typing stops (extra A10). The open / cd commands the standard mentions were not checked.',
 'Edit the URL and press Return.',
 NULL,NULL),
('bar-5','bar',5,'MUST','Browser-like model',
 'Address bar on top, content below; no separate bottom prompt.',
 'conforms',NULL,
 NULL,NULL,NULL),
('bar-6','bar',6,'MUST','History with ↑ / ↓',
 '↑ recalls earlier evaluated URLs; ↓ walks forward and ends at the unsubmitted draft.',
 'conforms','↓ on an untouched bar opens the suggestion dropdown instead (extra A6).',
 'Press ↑ in the bar to bring back the last URL you ran.',
 NULL,NULL),
('bar-7','bar',7,'MUST','Tab completion',
 'Tab completes a partial table or column name from the open schema.',
 'conforms',NULL,
 'Type the start of a table name and press Tab.',
 NULL,NULL),
('bar-8','bar',8,'MUST','Suggestion dropdown',
 'Typing opens a ranked dropdown of tables, columns, history and databases; ↑/↓ move, Tab completes, Return runs, Esc closes.',
 'conforms','Extra kinds: open documents, recent files and @keywords (extras A1, A2).',
 'Type a few letters and pick from the list under the bar.',
 NULL,NULL),
('bar-9','bar',9,'MUST','Back / forward',
 'Alt+← / Alt+→ (or Ctrl+[ / Ctrl+]) walk the session stack; a new visit after going back drops forward history.',
 'differs','The behaviour is implemented; the keys are ⌘[ and ⌘] (extra A5).',
 'Press ⌘[ to go back to the previous view, ⌘] to go forward.',
 NULL,NULL),

('grid-1','grid',1,'MUST','One-line cells',
 'Rows are one line high; text past about 120 characters is cut with an ellipsis and newlines become spaces.',
 'differs','Newlines are flattened, but the cut is at text.cell_display_max_chars = 400, not 120.',
 'Long text is shortened in the grid; open the inspector to read all of it.',
 'testdata/sample.db/events',NULL),
('grid-2','grid',2,'MUST','BLOB placeholder',
 'Binary values are never printed raw; they show as <BLOB: n bytes>.',
 'conforms',NULL,
 'Binary columns show their size instead of garbage.',
 'testdata/sample.db/telemetry/id,raw_payload[0:100]',NULL),
('grid-3a','grid',3,'recommended','Value translation',
 'Values are formatted for reading (dates from epochs, thousands separators); the raw value stays reachable.',
 'conforms','The standard numbers two rules "3"; this is the first. Booleans show as true/false. Display raw turns formatting off.',
 'Switch the display to raw to see values exactly as stored.',
 'testdata/sample.db/telemetry',NULL),
('grid-3b','grid',3,'recommended','Group-header separation',
 'With a grouping column, the group cell is tinted and repeated prefixes are blanked.',
 'missing','The standard numbers two rules "3"; this is the second. No group-header rendering exists.',
 NULL,NULL,NULL),
('grid-4','grid',4,'recommended','Zero rows',
 'An empty result shows "No results found", not a bare grid.',
 'conforms','A table that is empty with no filter says "This table is empty."',
 NULL,
 'testdata/sample.db/devices/status=NOPE',NULL),
('grid-5','grid',NULL,'SHOULD','URL visible',
 'The SQL or Banquet URL behind the grid is visible in the bar.',
 'conforms',NULL,NULL,NULL,NULL),

('query-0','query',0,'recommended','Hide empty columns',
 'All-null columns are not shown in trim.',
 'conforms',NULL,NULL,NULL,NULL),
('query-1','query',1,'recommended','Primary key first',
 'The primary key leads, in key order.',
 'conforms',NULL,NULL,NULL,NULL),
('query-2','query',2,'recommended','Name-like columns next',
 'Columns named like name / label / description follow the key.',
 'conforms',NULL,NULL,NULL,NULL),
('query-3','query',3,'recommended','No row-number column',
 'A row-number column is dropped as redundant with the key.',
 'conforms',NULL,NULL,NULL,NULL),
('query-4','query',4,'recommended','Grouping columns',
 'A never-null column with fewer than 10 distinct values is a grouping column.',
 'differs','Threshold is 12 (QueryStyle.lowCardinalityMax), 25 for category-named columns.',
 NULL,NULL,NULL),
('query-5','query',5,'recommended','Hide technical columns',
 'created_at, updated_at, version, uuid and audit columns are hidden unless a _style hint names them.',
 'conforms',NULL,NULL,NULL,NULL),
('query-6','query',6,'recommended','Order of the rest',
 'Status / type, then dates, then numbers, then long text.',
 'conforms',NULL,NULL,NULL,NULL),
('query-7','query',7,'recommended','Drop near-duplicates',
 'Two columns holding the same value in every sampled row collapse to one.',
 'conforms',NULL,NULL,NULL,NULL),
('query-8','query',8,'recommended','Column cap',
 'No cap normally; past about 40 surviving columns trim keeps the first 40. Raw is never capped.',
 'conforms','Trim is applied automatically only to tables over 14 columns (extra Q5).',
 'Wide tables open trimmed; switch to raw to see every column.',
 NULL,NULL),
('query-9','query',9,'recommended','No duplicate rowid',
 'rowid is hidden when an INTEGER PRIMARY KEY already is the rowid, and kept when nothing else names the row.',
 'conforms',NULL,NULL,NULL,NULL),
('query-style','query',NULL,'recommended','_style column hint',
 'A "<table>.columns" row in _style / _head is an authoritative column-order prefix for trim and summary, never raw.',
 'conforms','Parsed in Doc; has no dedicated test.',
 NULL,NULL,NULL),
('query-probe','query',NULL,'recommended','Table sample',
 'The rules read a one-time 2000-row sample, skipped past 60 columns.',
 'differs','Samples 1000 rows (250 for views); the 60-column skip matches.',
 NULL,NULL,NULL),

('dblist-grammar','dblist',NULL,'MUST','Collection grammar',
 'The container runs to the first reserved catalog table (databases, tables) or clause-like segment; the rest is ordinary grammar applied to the catalog.',
 'conforms',NULL,
 'Add -size_bytes after a folder path to sort its databases by size.',
 'testdata/-size_bytes',NULL),
('dblist-depth','dblist',NULL,'MUST','?depth=N',
 '?depth=N bounds how far the host recurses into subfolders.',
 'missing','The parameter is not read.',
 NULL,NULL,NULL),
('dblist-reflect','dblist',NULL,'SHOULD','Reflected URL',
 'The bar shows a trailing slash for a bare container and omits "databases" unless a sort follows.',
 'conforms','Stricter than the standard: "databases" is never written, even before a sort.',
 NULL,'testdata/',NULL),
('dblist-host','dblist',NULL,'MUST','Host responsibilities',
 'Enumerate datasets recursively, keep keys relative to the store root, reject a prefix that escapes it.',
 'differs','FolderScanner enumerates local folders recursively and skips nothing by depth. Root escape is not applicable to a local viewer and was not checked.',
 NULL,NULL,NULL),
('dblist-1','dblist',1,'MUST','Rendered as a table',
 'The database list is a table drawn with Grid Style.',
 'conforms','Table is the default layout; a Cards layout also exists (host chrome).',
 NULL,'testdata/',NULL),
('dblist-2','dblist',2,'MUST','Catalog schema',
 'A databases table (name, location, key, table_count, size, size_bytes, modified, status, open), a tables table and _style.',
 'differs','Shows name, location, table_count, size_bytes, modified. No status, key or open columns, and no tables catalog.',
 NULL,NULL,NULL),
('dblist-3','dblist',3,'MUST','Rows navigable via open',
 'Each row opens its dataset through its open path.',
 'differs','Rows open the database when clicked, but there is no open column carrying a Banquet path.',
 'Click a database in the list to open it.',
 NULL,NULL),
('dblist-4','dblist',4,'recommended','Catalog is a real database',
 'The catalog is an in-memory SQLite database opened in trim, so every clause applies; an empty container is 0 rows, not an error.',
 'differs','The list is a native SwiftUI view fed by FolderScanner. Sort applies; where, select and slice do not. CollectionCatalog.generate is an unused stub.',
 NULL,NULL,NULL),

('tablelist-1','tablelist',1,'MUST','Rendered as tables',
 'The table list reuses Grid Style.',
 'conforms',NULL,
 'Type <file>/tables to see every table at once.',
 'testdata/sample.db/tables',NULL),
('tablelist-2','tablelist',2,'MUST','Tiny table',
 'A tiny table has under 20 rows.',
 'conforms',NULL,NULL,NULL,NULL),
('tablelist-3','tablelist',3,'MUST','One grid per table',
 'A stack of independent grids, never one meta-grid.',
 'conforms',NULL,NULL,NULL,NULL),
('tablelist-4','tablelist',4,'MUST','First 20 rows',
 'Each grid shows the table''s real rows, the first 20.',
 'conforms','Raw column order, as SELECT * would give.',
 NULL,NULL,NULL),
('tablelist-5','tablelist',5,'MUST','Order',
 'Tiny first, then Large, then Empty; by row count descending inside each.',
 'conforms',NULL,NULL,NULL,NULL),
('tablelist-6','tablelist',6,'MUST','Empty tables',
 'An empty table shows exactly one placeholder row, (Empty).',
 'conforms',NULL,NULL,NULL,NULL),
('tablelist-7','tablelist',7,'MUST','Headers',
 'Each grid is preceded by === Table: name (N rows, M columns) ===.',
 'conforms','Large tables show an estimated count with ~ until the exact count settles.',
 NULL,NULL,NULL),

('edit-1','edit',1,'MUST','Opt-in session',
 'Files open read-only; edit mode never starts from a URL, a paste or a drop.',
 'conforms',NULL,
 'Press ⌥⌘E to start editing.',
 NULL,NULL),
('edit-2','edit',2,'MUST','URL neutrality',
 'Edit mode does not change the Banquet URL.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-3','edit',3,'MUST','Visible state',
 'An EDIT badge shows while editing, with the pending count when above zero.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-4','edit',4,'MUST','Eligibility',
 'Only base tables with a rowid are editable; BLOB cells and the rowid are not.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-5','edit',5,'MUST','Cell editing',
 'Double-click or Return opens an inline editor on the raw value; Return stages and moves down, Tab right, Esc cancels.',
 'conforms',NULL,
 'Double-click a cell, type, press Return.',
 NULL,NULL),
('edit-6','edit',6,'MUST','Typing and NULL',
 'Input is coerced by column affinity; unparseable input is rejected; NULL is set explicitly; NOT NULL refuses NULL.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-7','edit',7,'MUST','Staged buffer',
 'Edits are held in memory by (table, rowid, column) and shown tinted; editing back to the original drops the entry.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-8','edit',8,'MUST','Commit / Revert',
 'Commit writes everything in one transaction and rolls back whole on any failure; Revert discards the buffer.',
 'conforms',NULL,
 'Press ⌘S to write your changes, or Revert to throw them away.',
 NULL,NULL),
('edit-9','edit',9,'MUST','Optimistic concurrency',
 'Each UPDATE checks the original value; a row changed underneath aborts the commit and names the cell.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-10','edit',10,'MUST','Undo / Redo',
 'Undo and redo walk the staged buffer, not the database.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-11','edit',11,'MUST','Navigation while dirty',
 'Sorting, filtering and paging keep pending edits; closing or leaving with edits asks Commit / Discard / Cancel.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-12','edit',12,'MUST','After commit',
 'The page reloads, caches invalidate, and the write is not reported as an external change.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-13','edit',13,'MUST','Guarantees retained',
 'Outside a session no write path exists; inside, only parameterised UPDATE / INSERT / DELETE from the buffer.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-14','edit',14,'MUST','Row operations',
 'New and deleted rows live in the buffer with cell edits and share its undo stack; commit order is updates, deletes, inserts.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-15','edit',15,'MUST','Pending SQL',
 'The exact statements a commit would run can be previewed.',
 'conforms',NULL,NULL,NULL,NULL),
('edit-16','edit',16,'MUST','Bar guardrails',
 'Row operations never touch the URL, add no bar controls beyond the badge, and never change keyset paging.',
 'conforms',NULL,NULL,NULL,NULL);

-- ------------------------------------------------------------------- proofs
-- ui-case = name in Tests/SQLDocAppTests/banquet-ui-cases.json
-- runner  = test title in Tests/SQLDocTestsRunner/main.swift
-- manual  = what a person looks at; does not count as proven

INSERT INTO proofs VALUES
('url-1','runner','Banquet: Explicit semicolon parsing'),
('url-2','runner','Banquet: Familiar slash-delimited parsing & slice notation'),
('url-2','ui-case','reordered columns round-trip'),
('url-3','ui-case','plain table (no slice = all rows)'),
('url-4','ui-case','slice notation'),
('url-4','ui-case','all rows: an explicit slice is respected'),
('url-5','ui-case','sort descending'),
('url-5','ui-case','sort marker alone is sort-only'),
('url-6','runner','Banquet: Familiar slash-delimited parsing & slice notation'),
('url-6q','ui-case','where= param'),
('url-6q','ui-case','bare ?col>value defaults to where'),
('url-6q','ui-case','bare ?col=value defaults to where'),
('url-6q','ui-case','two bare params are ANDed'),
('url-7','runner','BanquetParser: Collections'),
('url-7','runner','Banquet: Collection & Database Overview URLs'),

('bar-1','ui-case','bar: typed edit live-applies'),
('bar-2','manual','MainView.onAppear sets isBanquetBarEditing; watch the caret on launch'),
('bar-3','ui-case','grid: sort then bar'),
('bar-3','ui-case','grid: filter shows in bar'),
('bar-3','ui-case','bar: blur reverts unapplied text to the grid URL'),
('bar-4','ui-case','all rows: removing the slice and submitting shows every row'),
('bar-5','manual','window layout'),
('bar-6','runner','BanquetRecall: ↑ older, ↓ newer, back to draft'),
('bar-7','ui-case','omnibox: column completion keeps the sort marker'),
('bar-8','ui-case','omnibox: plain text suggests matching table first'),
('bar-8','ui-case','omnibox: blur closes the dropdown and reverts'),
('bar-8','runner','BanquetSuggester: ranking, tables, columns, dedupe'),
('bar-9','ui-case','nav: back and forward restore URLs'),
('bar-9','ui-case','nav: a new visit after back drops forward history'),
('bar-9','runner','BanquetNavStack: back/forward, truncation, cap'),

('grid-1','manual','SQLiteValue.gridCell flattens newlines and clips at Page.cellTextMaxChars'),
('grid-2','manual','shot grid-blob'),
('grid-3a','manual','CellFormat.swift; compare display raw with the default'),
('grid-4','manual','shot grid-empty'),
('grid-5','ui-case','grid: sort then bar'),

('query-0','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-1','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-2','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-3','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-5','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-6','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-7','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-8','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-9','runner','QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage'),
('query-style','manual','Doc.swift reads "<table>.columns" from _style'),

('dblist-grammar','runner','BanquetParser: Collections'),
('dblist-reflect','runner','Banquet: Collection & Database Overview URLs'),
('dblist-host','runner','FolderScanner: Resolves stripped leading slash & scans nested SQLite files'),
('dblist-1','manual','shot dblist'),

('tablelist-1','manual','shot table-list'),
('tablelist-2','runner','TableList: ordering, header, empty placeholder'),
('tablelist-3','manual','shot table-list'),
('tablelist-4','manual','shot table-list'),
('tablelist-5','runner','TableList: ordering, header, empty placeholder'),
('tablelist-6','runner','TableList: ordering, header, empty placeholder'),
('tablelist-7','runner','TableList: ordering, header, empty placeholder'),

('edit-1','ui-case','edit: sessions never start from a URL'),
('edit-1','runner','EditSession: eligibility and immutable refusal; read connection stays query_only'),
('edit-2','ui-case','edit: entering edit mode leaves the bar URL unchanged'),
('edit-3','ui-case','edit: a staged cell edit is pending and the URL is unchanged'),
('edit-4','runner','EditSession: eligibility and immutable refusal; read connection stays query_only'),
('edit-5','manual','double-click a cell in an edit session'),
('edit-6','ui-case','edit: a value that does not parse is not staged'),
('edit-6','ui-case','edit: NOT NULL columns refuse NULL'),
('edit-6','runner','CellCoercion: affinity, bad input, NULL rules'),
('edit-7','runner','EditBuffer: stage, no-op drop, undo/redo, revert'),
('edit-8','runner','EditSession: commit persists, conflict rolls back everything'),
('edit-8','ui-case','edit: revert discards everything'),
('edit-9','runner','EditSession: commit persists, conflict rolls back everything'),
('edit-10','ui-case','edit: undo and redo walk the buffer'),
('edit-11','ui-case','edit: edits survive sorting (keyed by rowid)'),
('edit-12','manual','commit, then check no "changed on disk" banner appears'),
('edit-13','runner','EditSession: eligibility and immutable refusal; read connection stays query_only'),
('edit-14','runner','EditBuffer: new rows, deletes, grouped undo/redo, batch'),
('edit-14','runner','EditSession: insert + delete + update commit in one transaction, preview matches'),
('edit-15','runner','EditSession: insert + delete + update commit in one transaction, preview matches'),
('edit-16','manual','banquet-ui-cases.json stays green with pending row operations');

-- -------------------------------------------------------------------- shots
-- Recipes are replayed against the dev app by ConformanceGen (the shoot step, not built yet).

INSERT INTO shots VALUES
('url-familiar','url-2','still','url {DB}/telemetry/device_id,temperature[0:100]',
 'A path, a table and two columns: nothing else to learn.',
 'A Banquet URL reads like a file path. File, table, columns.'),
('url-slice','url-4','still','url {DB}/telemetry[10:20]',
 'Python-style slice: rows 10 to 20.',
 'Square brackets pick the rows, the way a Python slice does.'),
('url-sort','url-5','clip','url {DB}/telemetry[0:100]
url {DB}/telemetry/-temperature[0:100]',
 'A minus sign sorts descending.',
 'Put a minus in front of a column and the table sorts by it, largest first.'),
('url-query-where','url-6q','clip','url {DB}/telemetry
url {DB}/telemetry?id>6000',
 'Anything after ? is a filter.',
 'Add a question mark and a condition. No where keyword needed.'),
('url-collection','url-7','still','url {DBDIR}/',
 'A folder is a URL too: every database under it.',
 'Point it at a folder and you get a catalog of every database inside.'),
('bar-reflect','bar-3','clip','url {DB}/telemetry[0:100]
sort temperature desc
filter id > 6000',
 'The bar rewrites itself as you click.',
 'Sort and filter with the mouse. The bar keeps up, so the view is always a link you can copy.'),
('bar-suggest','bar-8','still','url {DB}/telemetry
type dev',
 'Typing "dev" offers the devices table.',
 'Start typing and the bar suggests tables, columns and places you have been.'),
('bar-back','bar-9','clip','navreset
go {DB}/devices
go {DB}/events
back',
 'Back returns to the previous view.',
 'Back and forward work like a browser.'),
('grid-blob','grid-2','still','url {DB}/telemetry/id,raw_payload[0:100]',
 'Binary data shows its size, never garbage.',NULL),
('grid-empty','grid-4','still','url {DB}/devices/status=NOPE',
 'No match says so, and keeps the headers.',NULL),
('query-trim','query-1','still','url {DB}/telemetry
display trim',
 'Trim: key first, noise hidden.',
 'Trim view puts the key first and hides columns you rarely need.'),
('query-raw','query-8','still','url {DB}/telemetry
display raw',
 'Raw: every column, as stored.',NULL),
('table-list','tablelist-1','still','url {DB}/tables',
 'Every table at a glance: small ones in full, large ones by their first 20 rows.',
 'Ask for tables and you see the whole database on one page.'),
('edit-session','edit-3','clip','url {DB}/devices
edit on
set 0 model Renamed',
 'Editing is opt-in, staged, and never changes the URL.',
 'Editing is a deliberate mode. Changes are staged and tinted until you commit.');

-- ------------------------------------------------------------------- extras
-- Things sqlswift does that no Banquet standard states. From docs/NonBanquetStandardExtras.md.

INSERT INTO extras VALUES
('A1','bar','@tables @open @recent @history keywords','BanquetSuggester.keywords, keywordSuggestions',NULL),
('A2','bar','Separate open-document and recent-file suggestion rows','BanquetSuggester openDocs / recents; AppViewModel.banquetSuggestContext','The standard has one Database kind.'),
('A3','bar','Shift+fn+Delete forgets a history row','BanquetBarView.removePressed; BanquetHistory.remove',NULL),
('A4','bar','Inline error (red border + message) instead of a modal alert','BanquetBarView.inlineError, errorForText',NULL),
('A5','bar','⌘[ / ⌘] for back and forward','nav-back, nav-forward in config/seed.sql','The feature is standard (bar-9); the keys are not.'),
('A6','bar','↓ on an untouched bar opens history; word-start ranking; completion keeps the +/- marker','BanquetSuggester.match, columnRows; BanquetBarView.moveHighlight',NULL),
('A7','bar','Paste & go (⇧⌘V)','AppViewModel.pasteFromClipboard; BanquetBarView.applyPaste',NULL),
('A8','bar','Newline flattening in the field','BanquetBarView.flattenNewlines',NULL),
('A9','bar','Row-count / timing pill, copy-URL button, DEV badge','TableTelemetryPillView, copyURLButton, devBadge',NULL),
('A10','bar','300 ms live-apply while typing','BanquetBarView.scheduleLiveApply, liveApply','The standard evaluates on submit.'),
('A11','bar','Folder-relative input and a file/directory shortcut that bypasses the parser','BanquetBarView.submit; AppViewModel.openBanquet',NULL),
('A12','bar','Second history record 400 ms later for files that open asynchronously','trailing Task in BanquetBarView.submit',NULL),
('A13','bar','Dev verbs suggest, go, back, forward, navreset (DEBUG only)','UICommands.swift',NULL),
('A14','bar','x-banquet: / banquet: URL scheme','SQLDocApp .onOpenURL',NULL),
('G1','grammar','Nested URLs; scheme/host/port split; gs:/x to gs://x','BanquetParser.cleanURL, parse, parseDirect',NULL),
('G2','grammar','& accepted as the query separator when there is no ?','BanquetParser.parseDirect',NULL),
('G3','grammar','Extra extensions .sqlite3 .tsv .xls','BanquetParser.knownExtensions',NULL),
('G4','grammar','< > <= >= and = in the path; percent-decoding of values','BanquetParser.splitComparison, parsePathConditions, isClauseLike','The standard has only Column!=Value in the path.'),
('G5','grammar','A sort marker also names a shown column; a hidden sort column moves to ?sort=&order=','BanquetParser.parseSelect, parseOrderBy; BanquetSerializer.canonicalString','Declared in docs/BanquetSwift.md; the standard is silent.'),
('G6','grammar','Open slice bounds [a:] and [:b]','BanquetParser.parseSlice',NULL),
('G7','grammar','filter as an alias of where','BanquetParser.parseWhere','The key is reserved but undefined.'),
('Q1','query','GROUP BY inferred from col(inside) in the path','BanquetParser sqlFunctionNames',NULL),
('Q2','query','Embedded SELECT parsing in the bar','BanquetParser.parseEmbeddedSQLStatement, splitPrefixAndSQL',NULL),
('Q3','query','Query keys limit, offset, groupby, having','BanquetParser.standardQueryParamKeys; TableViewModel.applyBanquet','Reserved by url-syntax, behaviour undefined.'),
('Q4','query','Raw-SQL execution path','TableViewModel.isCustomBanquetQuery, runCustomBanquetLoad; BanquetComposer.compose',NULL),
('Q5','query','Auto-trim over 14 columns; the summary display kind and ?display=summary','TableViewModel; QueryStyle.summaryPage','query-style names summary but gives no rules for it.'),
('Q6','query','No slice means all rows, up to window.all_rows_cap','TableViewModel.showAllRows, allRowsCap; Doc.maxLimit','url-syntax defines no default limit.'),
('E1','edit','Edit mode as a whole','Editor.swift; EditViewModel; EditCellField','No upstream standard covers writing; specified in docs/BanquetEditStyle.md.');
