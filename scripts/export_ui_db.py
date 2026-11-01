#!/usr/bin/env python3
"""
export_ui_db.py — Introspects SqlSwift UI codebase and exports all UI components,
subviews, design tokens, icons, keybindings, and hierarchy into a rich SQLite database `ui.db`.
"""

import os
import re
import sqlite3
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SQLSWIFT_DIR = REPO_ROOT / "sqlswift"
APP_DIR = SQLSWIFT_DIR / "Sources" / "SQLDocApp"
CORE_DIR = SQLSWIFT_DIR / "Sources" / "SQLDocCore"
OUTPUT_DB = REPO_ROOT / "ui.db"

def categorize_component(name: str, file_name: str) -> tuple[str, str, bool]:
    """Returns (category, summary, is_container)"""
    file_lower = file_name.lower()
    name_lower = name.lower()

    if "banquetbar" in file_lower or "token" in name_lower or "telemetry" in name_lower or "segment" in name_lower or "observer" in name_lower or "badge" in name_lower:
        if name == "BanquetBarView":
            return ("Navigation / Banquet Bar", "Unified Browser/Xcode-style title bar combining breadcrumbs, slice notation, filters, sort, and editable URL", True)
        if "token" in name_lower or "param" in name_lower:
            return ("Navigation / Banquet Bar", f"Interactive Banquet bar token chip ({name})", False)
        if "telemetry" in name_lower:
            return ("Status & Telemetry", f"Telemetry indicator pill for {name}", False)
        if "observer" in name_lower:
            return ("Navigation / Banquet Bar", f"Event & state change observer ({name}) for reactive Banquet sync", False)
        return ("Navigation / Banquet Bar", f"Title bar component: {name}", False)

    if "virtualizedgrid" in file_lower or "gridheader" in file_lower:
        if name == "VirtualizedGridView":
            return ("Data Grid", "High-performance lazy-scrolling data table grid with sticky headers and keyset paging", True)
        if name == "CellView":
            return ("Data Grid", "Individual interactive table cell with smart formatting, NULL/BLOB badge, and context actions", False)
        if name == "GridHeaderView":
            return ("Data Grid", "Sticky column header with sort indicators, drag resizing, and column options menu", False)
        if name == "QuickChartStripView":
            return ("Data Grid", "Inline mini histogram / bar chart strip for numeric columns", False)
        if name == "SkeletonBlock":
            return ("Feedback & Overlays", "Pulsing skeleton loader row for pending page loads", False)
        if name == "GridBackdrop":
            return ("Data Grid", "Alternating row backgrounds and vertical gridlines", False)
        return ("Data Grid", f"Grid subcomponent: {name}", False)

    if "sidebar" in file_lower:
        return ("Sidebar & Explorer", "Collapsible navigator sidebar showing tables, views, row counts, and file tree", True)

    if "datainspector" in file_lower:
        return ("Inspector & Sheets", "Cell data inspector with text, JSON, numeric, and hex/blob breakdown", False)

    if "findbar" in file_lower:
        return ("Filter & Search", "In-table find bar with match counter, next/prev navigation, and column scope", True)

    if "queryconsole" in file_lower:
        if name == "QueryConsoleView":
            return ("SQL Console", "Integrated SQL query scratchpad with syntax highlighting, history, and results", True)
        if name == "ResultGridView":
            return ("SQL Console", "Virtualized result table for ad-hoc SQL query execution", True)
        return ("SQL Console", f"SQL console component: {name}", False)

    if "schemasheet" in file_lower:
        return ("Inspector & Sheets", "Sheet modal displaying table DDL schema, column types, FKs, and SQLite indexes", True)

    if "jumptorow" in file_lower:
        return ("Modals & Jump", "Keyboard modal dialog (⌘J) for fast row seeking by offset, keyset rowid, or percentage", True)

    if "startpage" in file_lower:
        if name == "InlineDatabasePeekView":
            return ("Start & Catalog", "Peek preview card for a database in the folder catalog", False)
        return ("Start & Catalog", "Welcome dashboard with recent databases, sample picker, and folder database catalog", True)

    if "statusbar" in file_lower:
        return ("Status & Telemetry", "Bottom status bar with row counters, query execution timing, and zoom controls", True)

    if "busyoverlay" in file_lower:
        return ("Feedback & Overlays", "Non-blocking frosted glass loading overlay with spinner and cancel query button", False)

    if "mainview" in file_lower:
        return ("Window & Layout", "Top-level application window container coordinating title bar, sidebar, grid, and inspectors", True)

    return ("Other", f"UI Component: {name}", False)

def main():
    print(f"Creating UI SQLite Database at: {OUTPUT_DB}")
    if OUTPUT_DB.exists():
        OUTPUT_DB.unlink()

    conn = sqlite3.connect(OUTPUT_DB)
    cur = conn.cursor()

    cur.executescript("""
    PRAGMA foreign_keys = ON;

    CREATE TABLE ui_component (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        category TEXT NOT NULL,
        access_level TEXT NOT NULL,
        file_path TEXT NOT NULL,
        line_number INTEGER NOT NULL,
        parent_component TEXT,
        is_container INTEGER NOT NULL DEFAULT 0,
        summary TEXT NOT NULL,
        state_properties TEXT,
        source_snippet TEXT
    );

    CREATE TABLE ui_subview (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        component_name TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL, -- 'computed_property' or 'method'
        return_type TEXT NOT NULL DEFAULT 'some View',
        file_path TEXT NOT NULL,
        line_number INTEGER NOT NULL,
        summary TEXT,
        source_snippet TEXT,
        FOREIGN KEY(component_name) REFERENCES ui_component(name) ON DELETE CASCADE
    );

    CREATE TABLE ui_icon (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        symbol_name TEXT NOT NULL,
        component_name TEXT NOT NULL,
        usage_context TEXT,
        help_tooltip TEXT,
        file_path TEXT,
        line_number INTEGER,
        FOREIGN KEY(component_name) REFERENCES ui_component(name) ON DELETE CASCADE
    );

    CREATE TABLE ui_keybinding (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        shortcut TEXT NOT NULL,
        action TEXT NOT NULL,
        target_component TEXT,
        context TEXT,
        description TEXT
    );

    CREATE TABLE ui_design_token (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        name TEXT NOT NULL UNIQUE,
        value_light TEXT,
        value_dark TEXT,
        swift_type TEXT NOT NULL,
        summary TEXT
    );

    CREATE TABLE ui_hierarchy (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_component TEXT NOT NULL,
        child_component TEXT NOT NULL,
        relationship_role TEXT,
        display_condition TEXT,
        FOREIGN KEY(parent_component) REFERENCES ui_component(name),
        FOREIGN KEY(child_component) REFERENCES ui_component(name)
    );
    """)

    # 1. Parse all View structs in SQLDocApp
    swift_files = sorted(list(APP_DIR.rglob("*.swift")))
    components_found = []

    for fpath in swift_files:
        rel_path = str(fpath.relative_to(REPO_ROOT))
        content = fpath.read_text(encoding="utf-8")
        lines = content.splitlines()

        # Find structs conforming to View
        struct_pattern = re.compile(r'^(public\s+|private\s+|internal\s+|fileprivate\s+)?struct\s+([A-Za-z0-9_]+)\s*:\s*View\b', re.MULTILINE)

        for match in struct_pattern.finditer(content):
            access = (match.group(1) or "internal").strip()
            name = match.group(2)
            start_pos = match.start()
            line_no = content[:start_pos].count('\n') + 1

            # Determine parent component if it's a private subview in the same file
            # Primary component in file is usually the first public/internal struct with View or file name
            cat, summary, is_cont = categorize_component(name, fpath.name)

            # Find state properties
            # Extract struct body
            brace_idx = content.find('{', match.end())
            snippet = ""
            state_vars = []
            if brace_idx != -1:
                depth = 1
                curr = brace_idx + 1
                while curr < len(content) and depth > 0:
                    if content[curr] == '{':
                        depth += 1
                    elif content[curr] == '}':
                        depth -= 1
                    curr += 1
                struct_body = content[brace_idx:curr]
                # Keep snippet reasonable length (< 4000 chars)
                snippet = match.group(0) + " " + struct_body[:3500]
                if len(struct_body) > 3500:
                    snippet += "\n    // ... (truncated for brevity) ...\n}"

                # Extract state properties
                for prop_match in re.finditer(r'@(State|Binding|ObservedObject|FocusState|EnvironmentObject|Published)\s+(?:private\s+|public\s+)?var\s+([A-Za-z0-9_]+)\s*:\s*([^=\n{]+)', struct_body):
                    state_vars.append({
                        "wrapper": prop_match.group(1),
                        "name": prop_match.group(2),
                        "type": prop_match.group(3).strip()
                    })

            # Determine parent component
            parent = None
            if access == "private":
                # Find preceding public/internal struct
                for c_name, c_file, c_access in components_found:
                    if c_file == rel_path and c_access in ("public", "internal"):
                        parent = c_name
                        break

            cur.execute("""
            INSERT OR REPLACE INTO ui_component 
            (name, category, access_level, file_path, line_number, parent_component, is_container, summary, state_properties, source_snippet)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (name, cat, access, rel_path, line_no, parent, 1 if is_cont else 0, summary, json.dumps(state_vars) if state_vars else None, snippet))
            components_found.append((name, rel_path, access))

            # 2. Extract Subviews inside this component
            # Find @ViewBuilder private var ...: some View
            subview_pattern = re.compile(r'(@ViewBuilder\s+)?(private\s+|public\s+|internal\s+)?(var|func)\s+([A-Za-z0-9_]+)(?:\((.*?)\))?\s*(?:->\s*([^{]+))?\s*\{', re.MULTILINE)
            if brace_idx != -1:
                for sv in subview_pattern.finditer(struct_body):
                    kind_word = sv.group(3)
                    sv_name = sv.group(4)
                    ret_type = (sv.group(6) or "").strip()
                    if "some View" not in ret_type and "some View" not in (sv.group(0)):
                        continue
                    if sv_name in ("body",):
                        continue

                    kind = "method" if kind_word == "func" else "computed_property"
                    sv_line = line_no + struct_body[:sv.start()].count('\n')
                    sv_snippet = sv.group(0)[:500]

                    cur.execute("""
                    INSERT INTO ui_subview (component_name, name, kind, return_type, file_path, line_number, summary, source_snippet)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, (name, sv_name, kind, "some View", rel_path, sv_line, f"View segment '{sv_name}' of {name}", sv_snippet))

            # 3. Extract SF Symbols used in this struct
            for icon_match in re.finditer(r'systemName:\s*"([^"]+)"', struct_body):
                sym = icon_match.group(1)
                icon_line = line_no + struct_body[:icon_match.start()].count('\n')

                # Look around for .help(...)
                window_txt = struct_body[max(0, icon_match.start() - 100):min(len(struct_body), icon_match.end() + 250)]
                help_match = re.search(r'\.help\("([^"]+)"\)', window_txt)
                tooltip = help_match.group(1) if help_match else None

                cur.execute("""
                INSERT INTO ui_icon (symbol_name, component_name, usage_context, help_tooltip, file_path, line_number)
                VALUES (?, ?, ?, ?, ?, ?)
                """, (sym, name, f"Rendered in {name}", tooltip, rel_path, icon_line))

    # 4. Extract Design Tokens from DesignTokens.swift
    design_tokens_file = CORE_DIR / "Generated" / "DesignTokens.swift"
    if design_tokens_file.exists():
        dt_content = design_tokens_file.read_text(encoding="utf-8")
        # ColorToken(light: "#...", dark: "#...")
        for col_match in re.finditer(r'///\s*(.*?)\n\s*public static let\s+([A-Za-z0-9_]+)\s*=\s*ColorToken\(light:\s*"([^"]+)",\s*dark:\s*"([^"]+)"\)', dt_content):
            doc = col_match.group(1).strip()
            name = col_match.group(2)
            light = col_match.group(3)
            dark = col_match.group(4)
            cur.execute("""
            INSERT OR REPLACE INTO ui_design_token (category, name, value_light, value_dark, swift_type, summary)
            VALUES (?, ?, ?, ?, ?, ?)
            """, ("Color", name, light, dark, "ColorToken", doc))

        # Dimensions & Numbers: public static let colMinWidth: CGFloat = 56
        for num_match in re.finditer(r'///\s*(.*?)\n\s*public static let\s+([A-Za-z0-9_]+)\s*:\s*([A-Za-z0-9_]+)\s*=\s*([0-9.]+)', dt_content):
            doc = num_match.group(1).strip()
            name = num_match.group(2)
            stype = num_match.group(3)
            val = num_match.group(4)
            cat = "Dimension" if "width" in name.lower() or "height" in name.lower() or "padding" in name.lower() else "Metric"
            cur.execute("""
            INSERT OR REPLACE INTO ui_design_token (category, name, value_light, value_dark, swift_type, summary)
            VALUES (?, ?, ?, ?, ?, ?)
            """, (cat, name, val, val, stype, doc))

    # 5. Extract Keybindings
    keybindings_data = [
        ("⌘L or /", "Focus Banquet Address Bar", "BanquetBarView", "banquet_bar", "Focuses and selects the unified Banquet URL address bar"),
        ("⌘⌥C", "Copy Banquet URL", "BanquetBarView", "banquet_bar", "Copies canonical Banquet URL with path, projection, sort, slice, and query params"),
        ("⌘F", "Find in Table", "FindBarView", "table", "Opens in-table find bar for streaming substring matching"),
        ("⌥⌘S", "Toggle Sidebar", "TableSidebarView", "global", "Expands or collapses left navigator sidebar"),
        ("⇧⌘K", "SQL Console", "QueryConsoleView", "table", "Opens ad-hoc SQL query console scratchpad"),
        ("⌘I", "Inspect Table DDL", "SchemaSheetView", "table", "Opens sheet modal displaying full table DDL, column types, FKs, and indexes"),
        ("⌘J", "Jump to Row", "JumpToRowView", "table", "Opens jump-to-row modal dialog by row offset, rowid, or percentage"),
        ("⌘E", "Export CSV", "VirtualizedGridView", "table", "Exports current table or filtered results to CSV"),
        ("⌘W", "Close Database", "MainView", "global", "Closes active database and returns to folder / start catalog"),
        ("⌘O", "Open Database", "StartPageView", "global", "Prompts native macOS open dialog for SQLite files"),
        ("⌘+", "Zoom In", "VirtualizedGridView", "table", "Scales table font size and row height"),
        ("⌘-", "Zoom Out", "VirtualizedGridView", "table", "Reduces table font size and row height"),
        ("⌘0", "Actual Size (Zoom 1.0)", "VirtualizedGridView", "table", "Resets zoom level to 100%"),
        ("Esc", "Revert / Close", "BanquetBarView", "global", "Cancels address bar edit, closes find bar, or dismisses sheets"),
        ("Return", "Submit Banquet URL", "BanquetBarView", "banquet_bar", "Executes edited Banquet URL, slice, or pasted SQL"),
        ("PageDown", "Next Slice", "TableQueryTokensView", "table", "Steps forward to next pagination slice [offset : offset + limit]"),
        ("PageUp", "Previous Slice", "TableQueryTokensView", "table", "Steps back to previous pagination slice"),
        ("Home", "First Slice [0:limit]", "TableQueryTokensView", "table", "Jumps to initial slice of the table"),
        ("End", "Last Slice", "TableQueryTokensView", "table", "Jumps to final slice of the table")
    ]

    for sc, act, comp, ctx, desc in keybindings_data:
        cur.execute("""
        INSERT INTO ui_keybinding (shortcut, action, target_component, context, description)
        VALUES (?, ?, ?, ?, ?)
        """, (sc, act, comp, ctx, desc))

    # 6. Establish Component Hierarchy
    hierarchy_data = [
        ("MainView", "BanquetBarView", "header_toolbar", "Always visible in unified title bar"),
        ("MainView", "TableSidebarView", "sidebar", "When appVM.showSidebar is true"),
        ("MainView", "VirtualizedGridView", "content_body", "When a table is active and not in folder browser mode"),
        ("MainView", "StartPageView", "content_body", "When in folder browser or no database is loaded"),
        ("MainView", "FindBarView", "docked_bar", "When appVM.isFindBarVisible is true"),
        ("MainView", "DataInspectorView", "modal_sheet", "When appVM.inspectingCell is non-nil"),
        ("MainView", "StatusBarView", "footer_bar", "Visible at bottom of window when a table is active"),
        ("MainView", "SchemaSheetView", "modal_sheet", "When appVM.showSchemaSheet is true (⌘I)"),
        ("MainView", "QueryConsoleView", "modal_sheet", "When appVM.showQueryConsole is true (⇧⌘K)"),
        ("MainView", "JumpToRowView", "modal_dialog", "When appVM.showJumpToRow is true (⌘J)"),
        ("MainView", "BusyOverlayView", "overlay", "When appVM.isBusy is true"),

        ("BanquetBarView", "DatabaseTokenMenu", "breadcrumb_menu", "When a database entry is active"),
        ("BanquetBarView", "TableTokenMenu", "dropdown_menu", "When a table is selected"),
        ("BanquetBarView", "TableQueryTokensView", "subcomponent", "When table query parameters exist"),
        ("BanquetBarView", "TableTelemetryPillView", "telemetry_pill", "In active table mode"),
        ("BanquetBarView", "NavigationChangeObserver", "observer", "Observes AppViewModel navigation changes"),
        ("BanquetBarView", "TableChangeObserver", "observer", "Observes TableViewModel query & slice changes"),
        ("BanquetBarView", "EditingChangeObserver", "observer", "Observes Banquet address bar focus & paste state"),

        ("TableQueryTokensView", "CustomQueryParamTokenView", "token_chip", "For each custom query param (e.g. ?hmm-calmdown-qqq)"),

        ("VirtualizedGridView", "GridHeaderView", "sticky_header", "Top row of virtualized table"),
        ("VirtualizedGridView", "CellView", "grid_cell", "For each visible cell in keyset page"),
        ("VirtualizedGridView", "GridBackdrop", "background", "Zebra row fills and column vertical lines"),
        ("VirtualizedGridView", "SkeletonBlock", "placeholder", "During async keyset loading"),
        ("VirtualizedGridView", "QuickChartStripView", "chart_strip", "When tableVM.showQuickChart is true"),

        ("QueryConsoleView", "ResultGridView", "result_grid", "When a console query returns rows"),
        ("StartPageView", "InlineDatabasePeekView", "folder_item", "For each expanded sqlite db in folder")
    ]

    for parent, child, role, cond in hierarchy_data:
        cur.execute("""
        INSERT INTO ui_hierarchy (parent_component, child_component, relationship_role, display_condition)
        VALUES (?, ?, ?, ?)
        """, (parent, child, role, cond))

    # 7. Create Views for Easy Querying in SqlSwift
    cur.executescript("""
    CREATE VIEW v_components_by_category AS
    SELECT 
        category,
        COUNT(*) AS component_count,
        GROUP_CONCAT(name, ', ') AS components
    FROM ui_component
    GROUP BY category
    ORDER BY component_count DESC;

    CREATE VIEW v_component_overview AS
    SELECT 
        c.name AS component,
        c.category,
        c.access_level,
        c.file_path,
        c.line_number,
        COUNT(DISTINCT s.id) AS subview_count,
        COUNT(DISTINCT i.id) AS icon_count,
        c.summary
    FROM ui_component c
    LEFT JOIN ui_subview s ON s.component_name = c.name
    LEFT JOIN ui_icon i ON i.component_name = c.name
    GROUP BY c.id
    ORDER BY c.category, c.name;

    CREATE VIEW v_icons_frequency AS
    SELECT 
        symbol_name,
        COUNT(*) AS times_used,
        GROUP_CONCAT(DISTINCT component_name) AS used_in_components
    FROM ui_icon
    GROUP BY symbol_name
    ORDER BY times_used DESC;

    CREATE VIEW v_full_ui_hierarchy AS
    SELECT 
        h.parent_component,
        h.relationship_role,
        h.child_component,
        c.category AS child_category,
        h.display_condition,
        c.summary AS child_summary
    FROM ui_hierarchy h
    JOIN ui_component c ON c.name = h.child_component
    ORDER BY h.parent_component, h.child_component;
    """)

    conn.commit()

    # Print summary
    comp_count = cur.execute("SELECT COUNT(*) FROM ui_component").fetchone()[0]
    subv_count = cur.execute("SELECT COUNT(*) FROM ui_subview").fetchone()[0]
    icon_count = cur.execute("SELECT COUNT(*) FROM ui_icon").fetchone()[0]
    token_count = cur.execute("SELECT COUNT(*) FROM ui_design_token").fetchone()[0]
    key_count = cur.execute("SELECT COUNT(*) FROM ui_keybinding").fetchone()[0]
    hier_count = cur.execute("SELECT COUNT(*) FROM ui_hierarchy").fetchone()[0]

    print(f"✓ Created {OUTPUT_DB}")
    print(f"  • UI Components: {comp_count}")
    print(f"  • UI Subviews / Builders: {subv_count}")
    print(f"  • SF Symbols / Icons: {icon_count}")
    print(f"  • Design Tokens: {token_count}")
    print(f"  • Keybindings: {key_count}")
    print(f"  • Hierarchy Links: {hier_count}")

    conn.close()

if __name__ == "__main__":
    main()
