import Foundation
import CoreGraphics
import SQLDocCore

func runAllTests() async {
    var passed = 0
    var failed = 0

    func test(_ name: String, block: () async throws -> Void) async {
        print("  ▶ Running \(name)...", terminator: " ")
        do {
            try await block()
            print("✓ PASSED")
            passed += 1
        } catch {
            print("✗ FAILED: \(error)")
            failed += 1
        }
    }

    print("\n=======================================================")
    print("           SQLSwift Test Suite (Swift 6.0)")
    print("=======================================================\n")

    // CSV Exporter Tests
    await test("CSVExporter: Export table to CSV format") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("csv_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE products (id INTEGER, name TEXT, price REAL)")
        try conn.exec("INSERT INTO products VALUES (1, 'Widget, Pro', 29.99)")
        try conn.exec("INSERT INTO products VALUES (2, 'Gadget \"Special\"', 49.50)")
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        let csv = try doc.exportCSV(for: "products")
        let lines = csv.split(separator: "\n").map(String.init)

        expectEqual(lines.count, 3)
        expectEqual(lines[0], "id,name,price")
        expectEqual(lines[1], "1,\"Widget, Pro\",29.99")
        expectEqual(lines[2], "2,\"Gadget \"\"Special\"\"\",49.5")
    }

    // Counter Tests
    await test("Counter: O(1) estimate and async exact count") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("counter_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
        try conn.exec("BEGIN TRANSACTION")
        for i in 1...500 {
            try conn.exec("INSERT INTO items VALUES (\(i), 'Item \(i)')")
        }
        try conn.exec("COMMIT")
        try conn.exec("ANALYZE")
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        let est = doc.estimateRows(for: "items")
        expectTrue(est.known)
        expectEqual(est.rows, 500)

        _ = doc.count(for: "items")
        var settled = false
        for _ in 0..<100 {
            let current = doc.count(for: "items")
            if current.exact {
                expectEqual(current.rows, 500)
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expectTrue(settled)
    }

    // Finder Tests
    await test("Finder: Streaming search with prefix and wildcards") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("finder_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE logs (id INTEGER PRIMARY KEY, level TEXT, msg TEXT)")
        try conn.exec("INSERT INTO logs VALUES (1, 'INFO', 'Server started successfully')")
        try conn.exec("INSERT INTO logs VALUES (2, 'WARN', 'Disk space 95% threshold reached')")
        try conn.exec("INSERT INTO logs VALUES (3, 'ERROR', 'Connection failed: timeout')")
        try conn.exec("INSERT INTO logs VALUES (4, 'INFO', 'Periodic health check OK')")
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        let res1 = try doc.find(table: "logs", query: "INFO")
        expectEqual(res1.matches.count, 2)
        expectEqual(res1.matches[0].rowID, 1)
        expectEqual(res1.matches[1].rowID, 4)

        let res2 = try doc.find(table: "logs", query: "95%")
        expectEqual(res2.matches.count, 1)
        expectEqual(res2.matches[0].rowID, 2)

        // Column-scoped: "INFO" appears in `level` for rows 1 & 4; restricting to
        // `msg` finds nothing, and the reported column is the scoped one.
        let scopedMsg = try doc.find(table: "logs", query: "INFO", column: "msg")
        expectEqual(scopedMsg.matches.count, 0)
        let scopedLevel = try doc.find(table: "logs", query: "INFO", column: "level")
        expectEqual(scopedLevel.matches.count, 2)
        expectEqual(scopedLevel.matches[0].column, 1) // columns: id(0), level(1), msg(2)

        // Case-sensitive: "info" (lowercase) matches nothing; "INFO" matches 2.
        expectEqual(try doc.find(table: "logs", query: "info", caseSensitive: true).matches.count, 0)
        expectEqual(try doc.find(table: "logs", query: "INFO", caseSensitive: true).matches.count, 2)
    }

    // Keyset Paging Tests
    await test("KeysetPaging: Fast seek and sliding window navigation") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("keyset_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE sensor_readings (id INTEGER PRIMARY KEY, device_id TEXT, temp REAL, pressure REAL)")
        try conn.exec("BEGIN TRANSACTION")
        for i in 1...1000 {
            try conn.exec("INSERT INTO sensor_readings VALUES (\(i), 'DEV-\(i % 10)', \(20.0 + Double(i % 15)), \(1013.25 + Double(i % 50)))")
        }
        try conn.exec("COMMIT")
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        let page1 = try doc.rows(window: Window(table: "sensor_readings", limit: 100))
        expectEqual(page1.rows.count, 100)
        expectEqual(page1.rowIDs.first, 1)
        expectEqual(page1.rowIDs.last, 100)

        let page2 = try doc.rows(window: Window(table: "sensor_readings", limit: 100, after: 100, useAfter: true, offset: 100))
        expectEqual(page2.rows.count, 100)
        expectEqual(page2.rowIDs.first, 101)
        expectEqual(page2.rowIDs.last, 200)

        let page3 = try doc.rows(window: Window(table: "sensor_readings", limit: 50, offset: 500))
        expectEqual(page3.rows.count, 50)
        expectEqual(page3.rowIDs.first, 501)

        let page4 = try doc.rows(window: Window(table: "sensor_readings", limit: 20, sort: "temp", desc: true))
        expectEqual(page4.rows.count, 20)
    }

    // Sorted keyset paging: stable order + fast forward seek without deep OFFSET
    await test("SortedKeyset: stable order and keyset forward paging") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("sortkey_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, bucket INTEGER, label TEXT)")
        try conn.exec("BEGIN TRANSACTION")
        for i in 1...600 {
            // Many ties on `bucket` so the rowid tiebreaker matters.
            try conn.exec("INSERT INTO t VALUES (\(i), \(i % 5), 'row-\(i)')")
        }
        try conn.exec("COMMIT")
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        // First page, ascending by the heavily-tied column.
        let p1 = try doc.rows(window: Window(table: "t", limit: 50, sort: "bucket", desc: false, sortNumeric: true))
        expectEqual(p1.rows.count, 50)
        expectEqual(p1.path, "sorted-offset")
        // Column order preserved (id, bucket, label): first 50 rows are bucket 0.
        expectEqual(p1.rows.first?[1], .integer(0))

        // Keyset forward: seek past the last row's (bucket, rowid).
        let anchorBucket = p1.rows.last![1]
        let anchorRowID = p1.rowIDs.last!
        let p2 = try doc.rows(window: Window(
            table: "t", limit: 50, after: anchorRowID, useAfter: true,
            offset: 50, sort: "bucket", desc: false, sortNumeric: true,
            afterSortValue: anchorBucket
        ))
        expectEqual(p2.path, "sorted-keyset")
        expectEqual(p2.rows.count, 50)
        // No overlap with page 1 and strictly ordered by (bucket, rowid).
        let p1IDs = Set(p1.rowIDs)
        expectTrue(!p2.rowIDs.contains { p1IDs.contains($0) })

        // Full offset walk vs keyset walk must produce the same rowids.
        var keysetIDs: [Int64] = p1.rowIDs
        var cursorRowID = anchorRowID
        var cursorVal = anchorBucket
        var off: Int64 = 50
        for _ in 0..<11 {
            let pg = try doc.rows(window: Window(
                table: "t", limit: 50, after: cursorRowID, useAfter: true,
                offset: off, sort: "bucket", desc: false, sortNumeric: true,
                afterSortValue: cursorVal
            ))
            if pg.rows.isEmpty { break }
            keysetIDs.append(contentsOf: pg.rowIDs)
            cursorRowID = pg.rowIDs.last!
            cursorVal = pg.rows.last![1]
            off += 50
        }
        expectEqual(keysetIDs.count, 600)
        expectEqual(Set(keysetIDs).count, 600)
    }

    // Schema inspector, ad-hoc query, filters, power-sample, exporters
    await test("Schema+Query: FK/index introspection, read-only query, filters, power2, formats") {
        let tempDir = NSTemporaryDirectory()
        let p = (tempDir as NSString).appendingPathComponent("schema_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: p) }

        let conn = try SQLiteConnection(path: p, readOnly: false)
        try conn.exec("CREATE TABLE dept (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try conn.exec("CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept_id INTEGER REFERENCES dept(id), salary INTEGER)")
        try conn.exec("CREATE INDEX emp_dept ON emp(dept_id)")
        try conn.exec("INSERT INTO dept VALUES (1,'Eng'),(2,'Sales')")
        try conn.exec("BEGIN")
        for i in 1...300 {
            try conn.exec("INSERT INTO emp VALUES (\(i), 'E\(i)', \(i % 2 + 1), \(50000 + i * 10))")
        }
        try conn.exec("COMMIT")
        conn.close()

        let doc = try Doc.open(path: p)
        defer { doc.close() }

        // Schema
        let sch = try doc.tableSchema(for: "emp")
        expectEqual(sch.columns.count, 4)
        expectEqual(sch.foreignKeys.count, 1)
        expectEqual(sch.foreignKeys.first?.table, "dept")
        expectEqual(sch.foreignKeys.first?.toColumn, "id")
        expectTrue(sch.indexes.contains { $0.name == "emp_dept" && $0.columns == ["dept_id"] })
        expectEqual(sch.rowidAlias, "id")
        expectTrue(sch.ddl.contains("CREATE TABLE"))

        // Read-only query
        let qr = try doc.runQuery("SELECT name, salary FROM emp WHERE salary > 51000 ORDER BY salary")
        expectEqual(qr.columns, ["name", "salary"])
        expectTrue(qr.rows.count > 0)
        expectEqual(qr.rows.first?[1].intValue, 51010)

        // Write rejected
        var wrote = true
        do { _ = try doc.runQuery("DELETE FROM emp"); } catch { wrote = false }
        expectTrue(!wrote)

        // Filters
        let filtered = try doc.rows(window: Window(
            table: "emp", limit: 50,
            filters: [ColumnFilter(column: "dept_id", op: .equals, value: "1")]
        ))
        expectEqual(filtered.path, "filtered")
        expectTrue(filtered.rows.allSatisfy { $0[2].intValue == 1 })
        let fc = doc.filteredCount(table: "emp", filters: [ColumnFilter(column: "dept_id", op: .equals, value: "1")])
        expectEqual(fc, 150)

        // Power sample: ordinals 1,2,4,8,... within 300 rows -> 1,2,4,...,256 = 9 rows
        let ps = try doc.rows(window: Window(table: "emp", limit: 100, powerSample: true))
        expectEqual(ps.path, "power2")
        expectEqual(ps.rows.count, 9)
        expectEqual(ps.rowIDs, [1, 2, 4, 8, 16, 32, 64, 128, 256])

        // Exporters
        let md = try doc.export(table: "dept", as: .markdown)
        expectTrue(md.contains("| id | name |"))
        expectTrue(md.contains("| 1 | Eng |"))
        let sql = try doc.export(table: "dept", as: .sql)
        expectTrue(sql.contains("INSERT INTO \"dept\""))
        let json = try doc.export(table: "dept", as: .json)
        expectTrue(json.contains("\"name\": \"Eng\""))
        let htmlOut = try doc.export(table: "dept", as: .html)
        expectTrue(htmlOut.contains("<!doctype html>") && htmlOut.contains("<td"))
    }

    // SQLite Connection Tests
    await test("SQLiteConnection: Read-only handle and data extraction") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, age INTEGER, bio BLOB)")
        try conn.exec("INSERT INTO users (name, age, bio) VALUES ('Alice', 30, X'DEADBEEF')")
        try conn.exec("INSERT INTO users (name, age, bio) VALUES ('Bob', 25, NULL)")
        conn.close()

        let readConn = try SQLiteConnection(path: tempDBPath)
        defer { readConn.close() }

        let rows = try readConn.query("SELECT id, name, age, bio FROM users ORDER BY id")
        expectEqual(rows.count, 2)
        expectEqual(rows[0][1], .text("Alice"))
        expectEqual(rows[0][2], .integer(30))
        expectEqual(rows[0][3], .blob(bytes: 4))
        expectEqual(rows[1][1], .text("Bob"))
        expectEqual(rows[1][2], .integer(25))
        expectEqual(rows[1][3], .null)
    }

    // Style & Nav Tests
    await test("StyleNav: Document metadata conventions and hidden tables") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("style_test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE readings (id INTEGER, val REAL)")
        try conn.exec("CREATE TABLE hidden_data (id INTEGER, secret TEXT)")
        try conn.exec("CREATE TABLE _style (key TEXT, value TEXT)")
        try conn.exec("INSERT INTO _style VALUES ('title', 'Sensor Dashboard'), ('accent', '#10b981'), ('theme', 'dark')")
        try conn.exec("CREATE TABLE _nav (table_name TEXT, label TEXT, position INTEGER, hidden INTEGER)")
        try conn.exec("INSERT INTO _nav VALUES ('readings', 'Live Sensor Readings', 1, 0), ('hidden_data', '', 2, 1)")
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        expectEqual(doc.style.title, "Sensor Dashboard")
        expectEqual(doc.style.accent, "#10b981")
        expectEqual(doc.style.theme, "dark")

        let visible = doc.tables.filter { !$0.hidden }
        expectEqual(visible.count, 1)
        expectEqual(visible[0].name, "readings")
        expectEqual(visible[0].label, "Live Sensor Readings")
    }

    // State Persistence Tests
    await test("StatePersistenceManager: Column widths and settings persistence") {
        let manager = StatePersistenceManager.shared
        let testDB = "test_db_\(UUID().uuidString)"
        let testTable = "users"

        let originalWidths: [String: CGFloat] = [
            "id": 80.0,
            "name": 180.0,
            "email": 240.0
        ]

        manager.saveColumnWidths(dbID: testDB, table: testTable, widths: originalWidths)

        let loaded = manager.loadColumnWidths(dbID: testDB, table: testTable)
        expectNotNil(loaded)
        expectEqual(loaded?["id"], 80.0)
        expectEqual(loaded?["name"], 180.0)
        expectEqual(loaded?["email"], 240.0)

        manager.clearColumnWidths(dbID: testDB, table: testTable)
        let cleared = manager.loadColumnWidths(dbID: testDB, table: testTable)
        expectEqual(cleared, nil)

        manager.themeMode = .dark
        expectEqual(manager.themeMode, .dark)
    }

    // Banquet URL Parsing & Serialization Tests
    await test("Banquet: Explicit semicolon parsing") {
        let b1 = try BanquetParser.parse("data/sales.sqlite;orders;amount")
        expectEqual(b1.dataSetPath, "data/sales.sqlite")
        expectEqual(b1.table, "orders")
        expectEqual(b1.select, ["amount"])

        let b2 = try BanquetParser.parse("database.sqlite;customers;id,name,+age?where=age>18&limit=50")
        expectEqual(b2.dataSetPath, "database.sqlite")
        expectEqual(b2.table, "customers")
        expectEqual(b2.select, ["id", "name", "age"])
        expectEqual(b2.sortColumn, "age")
        expectEqual(b2.isSortDesc, false)
        expectEqual(b2.whereClause, "age>18")
        expectEqual(b2.limit, 50)
    }

    await test("Banquet: Familiar slash-delimited parsing & slice notation") {
        let b = try BanquetParser.parse("history.db/backtest_details_all/-Open[10:35]")
        expectEqual(b.dataSetPath, "history.db")
        expectEqual(b.table, "backtest_details_all")
        expectEqual(b.sortColumn, "Open")
        expectEqual(b.isSortDesc, true)
        expectEqual(b.offset, 10)
        expectEqual(b.limit, 25)

        let bCsv = try BanquetParser.parse("sample.csv/Name,City")
        expectEqual(bCsv.dataSetPath, "sample.csv")
        expectEqual(bCsv.select, ["Name", "City"])

        // Sort marker + other columns: the sorted column is shown, in written position.
        let bSortCols = try BanquetParser.parse("t.db/telemetry/id,+temperature,humidity[0:10]")
        expectEqual(bSortCols.sortColumn, "temperature")
        expectEqual(bSortCols.select, ["id", "temperature", "humidity"])
        // Sort alone stays sort-only.
        expectEqual(try BanquetParser.parse("t.db/telemetry/-id").select, ["*"])
        // Round trip, and the projected-out sort column falls back to ?sort=
        let rt = BanquetSerializer.canonicalString(for: bSortCols)
        expectEqual(try BanquetParser.parse(rt).select, ["id", "temperature", "humidity"])
        let hidden = Banquet(dataSetPath: "t.db", table: "telemetry", select: ["id"], sortColumn: "temperature", isSortDesc: true)
        let hiddenURL = BanquetSerializer.canonicalString(for: hidden)
        expectTrue(hiddenURL.contains("telemetry/id?sort=temperature&order=desc"))
        let hiddenBack = try BanquetParser.parse(hiddenURL)
        expectEqual(hiddenBack.sortColumn, "temperature")
        expectEqual(hiddenBack.isSortDesc, true)
        expectEqual(hiddenBack.select, ["id"])

        // Non-reserved `?` params default to WHERE conditions.
        let bBare = try BanquetParser.parse("t.db/telemetry/id,temperature[0:20]?id>6000")
        expectEqual(bBare.whereClause, "id>6000")
        expectEqual(bBare.extraQueryParams, [])
        let bBare2 = try BanquetParser.parse("t.db/telemetry?device_id=3&id>6000&where=temperature<20&limit=5")
        expectEqual(bBare2.whereClause, "temperature<20 AND device_id = 3 AND id>6000")
        expectEqual(bBare2.limit, 5)
        expectEqual(try BanquetParser.parse("t.db/telemetry?id>6000").whereClause, "id>6000")
        // `display` is not a reserved key: only `display=summary` is a view mode.
        expectEqual(try BanquetParser.parse("t.db/telemetry?display=trim").whereClause, "display = 'trim'")
        expectEqual(try BanquetParser.parse("t.db/telemetry?display=summary").whereClause, nil)
        // Comparison in the path: filters, and a marker keeps just the column name.
        let bCmp = try BanquetParser.parse("t.db/telemetry/+id>6000,temperature,humidity[0:100]")
        expectEqual(bCmp.sortColumn, "id")
        expectEqual(bCmp.isSortDesc, false)
        expectEqual(bCmp.select, ["id", "temperature", "humidity"])
        expectEqual(bCmp.whereClause, "id > 6000")
        let bCmp2 = try BanquetParser.parse("t.db/telemetry/temperature,age<=30,name")
        expectEqual(bCmp2.select, ["temperature", "name"])
        expectEqual(bCmp2.whereClause, "age <= 30")
        expectEqual(bCmp2.sortColumn, nil)
        let bNoOp = try BanquetParser.parse("t.db/telemetry?foo")
        expectEqual(bNoOp.whereClause, nil)
        expectEqual(bNoOp.extraQueryParams, ["foo"])

        let bFilter = try BanquetParser.parse("users.sqlite/members/status!=active")
        expectEqual(bFilter.dataSetPath, "users.sqlite")
        expectEqual(bFilter.table, "members")
        expectEqual(bFilter.whereClause, "status != 'active'")
    }

    await test("Banquet: Canonical serialization and breadcrumbs") {
        let b = Banquet(
            dataSetPath: "history.db",
            table: "orders",
            select: ["id", "total"],
            sortColumn: "total",
            isSortDesc: true,
            whereClause: "status = 'active'",
            limit: 25,
            offset: 50
        )

        let canonical = BanquetSerializer.canonicalString(for: b)
        expectTrue(canonical.contains("history.db/orders/id,-total[50:75]"))
        expectTrue(canonical.contains("where=status%20=%20'active'") || canonical.contains("where=status = 'active'"))

        // Breadcrumb segments
        let segments = b.segments()
        expectEqual(segments.count, 6) // dataset, table, columns, filter, sort, slice
        expectEqual(segments[0].kind, .dataset)
        expectEqual(segments[0].text, "history.db")
        expectEqual(segments[1].kind, .table)
        expectEqual(segments[1].text, "orders")
        expectEqual(segments[2].kind, .columns)
        expectEqual(segments[3].kind, .filter)
        expectEqual(segments[4].kind, .sort)
        expectEqual(segments[5].kind, .slice)
        expectEqual(segments[5].text, "[50:75]")
    }

    await test("Banquet: Nested URLs and CleanURL") {
        let clean = BanquetParser.cleanURL("/http:/darianhickman.com:8080/some/local/path/file.csv;col1,col2")
        expectEqual(clean, "http://darianhickman.com:8080/some/local/path/file.csv;col1,col2")

        let nested = "http://localhost:8080/gs:/my-bucket/database.sqlite;customers;id,name,+age?where=age>18&limit=50"
        let b = try BanquetParser.parse(nested)
        expectEqual(b.scheme, "gs")
        expectEqual(b.host, "my-bucket")
        expectEqual(b.dataSetPath, "database.sqlite")
        expectEqual(b.table, "customers")
        expectEqual(b.sortColumn, "age")
        expectEqual(b.isSortDesc, false)
        expectEqual(b.limit, 50)
    }

    // BanquetComposer Tests
    await test("BanquetComposer: SQL Construction") {
        let tests: [(url: String, expected: String)] = [
            // --- 1. Basic Table Inference ---
            (url: "users.csv", expected: "SELECT * FROM \"tb0\""),
            (url: "data.sqlite", expected: "SELECT * FROM \"sqlite_master\""),
            (url: "data.sqlite;users", expected: "SELECT * FROM \"users\""),

            // --- 2. Column Selection ---
            (url: "data.sqlite;users;id", expected: "SELECT \"id\" FROM \"users\""),
            (url: "data.sqlite;users;id,name,email", expected: "SELECT \"id\", \"name\", \"email\" FROM \"users\""),
            (url: "data.sqlite;users", expected: "SELECT * FROM \"users\""),
            (url: "data.sqlite;users;*", expected: "SELECT * FROM \"users\""),

            // --- 3. Sorting ---
            (url: "data.sqlite;users;+name", expected: "SELECT * FROM \"users\" ORDER BY \"name\" ASC"),
            (url: "data.sqlite;users;-created_at", expected: "SELECT * FROM \"users\" ORDER BY \"created_at\" DESC"),
            (url: "data.sqlite;users;id,+name", expected: "SELECT \"id\", \"name\" FROM \"users\" ORDER BY \"name\" ASC"),
            (url: "data.sqlite;users;id,-age,email", expected: "SELECT \"id\", \"age\", \"email\" FROM \"users\" ORDER BY \"age\" DESC"),

            // --- 4. Slice Notation (Limit/Offset) ---
            (url: "data.sqlite;users[0:10]", expected: "SELECT * FROM \"users\" LIMIT 10 OFFSET 0"),
            (url: "data.sqlite;users[20:30]", expected: "SELECT * FROM \"users\" LIMIT 10 OFFSET 20"),
            (url: "data.sqlite;users;id[5:15],name", expected: "SELECT \"id\", \"name\" FROM \"users\" LIMIT 10 OFFSET 5"),
            (url: "data.sqlite;users;id,name[0:50]", expected: "SELECT \"id\", \"name\" FROM \"users\" LIMIT 50 OFFSET 0"),

            // --- 5. Filtering (WHERE) ---
            (url: "data.sqlite;users?where=age>18", expected: "SELECT * FROM \"users\" WHERE age>18"),
            (url: "data.sqlite;users;status!=active?where=age>18", expected: "SELECT * FROM \"users\" WHERE age>18 AND status != 'active'"),
            (url: "data.sqlite;users;status!=active,role!=admin", expected: "SELECT * FROM \"users\" WHERE status != 'active' AND role != 'admin'"),

            // --- 6. Grouping and Having ---
            (url: "data.sqlite;users?groupby=country", expected: "SELECT * FROM \"users\" GROUP BY \"country\""),
            (url: "data.sqlite;users?groupby=country&having=count(*)>5", expected: "SELECT * FROM \"users\" GROUP BY \"country\" HAVING count(*)>5"),

            // --- 7. Complex Combinations ---
            (url: "data.sqlite;users;id,name,-age?where=active=1&limit=5", expected: "SELECT \"id\", \"name\", \"age\" FROM \"users\" WHERE active=1 ORDER BY \"age\" DESC LIMIT 5"),
            (url: "data.sqlite;users;id,email,+joined[10:20]", expected: "SELECT \"id\", \"email\", \"joined\" FROM \"users\" ORDER BY \"joined\" ASC LIMIT 10 OFFSET 10"),
            (url: "data.sqlite;users;name!=O%27Reilly", expected: "SELECT * FROM \"users\" WHERE name != 'O''Reilly'"),

            // --- 8. Heuristic Path Parsing (No Semicolons) ---
            (url: "file.csv/col1,col2", expected: "SELECT \"col1\", \"col2\" FROM \"tb0\""),
            (url: "db.sqlite/mytable/col1", expected: "SELECT \"col1\" FROM \"mytable\""),
            (url: "db.sqlite/mytable", expected: "SELECT * FROM \"mytable\"")
        ]

        for tc in tests {
            let bq = try BanquetParser.parse(tc.url)
            let sql = BanquetComposer.compose(bq)
            expectEqual(sql, tc.expected, "URL: \(tc.url)")
        }
    }

    // BanquetParser Tests
    await test("BanquetParser: Collections") {
        let cases: [(url: String, isCollection: Bool, dataSetPath: String, table: String, orderBy: String?, sortDir: String?)] = [
            ("/", true, ".", "databases", nil, nil),
            ("/d1", true, "d1", "databases", nil, nil),
            ("/local/Documents/Income", true, "local/Documents/Income", "databases", nil, nil),
            ("/local/Documents/Income/", true, "local/Documents/Income/", "databases", nil, nil),
            ("/local/Documents/Income/databases/-size_bytes", true, "local/Documents/Income", "databases", "size_bytes", "DESC"),
            ("/local/Documents/Income/tables/+database", true, "local/Documents/Income", "tables", "database", "ASC"),
            ("/my-bucket/reports.db/orders", false, "my-bucket/reports.db", "orders", nil, nil),
            ("data/sales.sqlite;orders;amount", false, "data/sales.sqlite", "orders", nil, nil)
        ]

        for c in cases {
            let b = try BanquetParser.parse(c.url)
            expectEqual(b.isCollection, c.isCollection, "URL: \(c.url)")
            expectEqual(b.dataSetPath, c.dataSetPath, "URL: \(c.url)")
            expectEqual(b.table, c.table, "URL: \(c.url)")
            expectEqual(b.sortColumn, c.orderBy, "URL: \(c.url)")
            expectEqual(b.sortDirection, c.sortDir, "URL: \(c.url)")
        }
    }

    await test("BanquetParser: GroupBy from path") {
        let b = try BanquetParser.parse("data.sqlite/tb/some_column(group_column)")
        expectEqual(b.groupBy, "group_column")
    }

    await test("BanquetParser: Legacy literal prefixes") {
        let b = try BanquetParser.parse("data.sqlite/tb/^column1,!^column2")
        expectEqual(b.select, ["^column1", "!^column2"])
        expectEqual(b.sortColumn, nil)
    }
    
    await test("BanquetParser: Super ugly nested URL") {
        let ugly = "http://localhost:8080/https://bucket.appspot.com:8080/v1/{banquet}/path:with;@+,$/[^]|\\< >~%25/column1,column2/+const?orderid=-1&tag=prime+val&filter={status:active}&search=~alt#fragment-top"
        let b = try BanquetParser.parse(ugly)
        expectEqual(b.host, "bucket.appspot.com")
        expectEqual(b.port, "8080")
        expectEqual(b.dataSetPath, "v1/{banquet}/path:with")
        expectEqual(b.table, "@+,$/")
        expectEqual(b.rawQuery, "orderid=-1&tag=prime+val&filter={status:active}&search=~alt#fragment-top")
    }

    // Float Formatting & Noise Elimination Tests
    await test("SQLiteValueFormat: Quant/Float smart formatting & rawText preservation") {
        // IEEE-754 float32 noise from daily_bars.db
        expectEqual(SQLiteValueFormat.realString(46.4199981689453), "46.42")
        // Unrounded ratios from regime_score.db
        expectEqual(SQLiteValueFormat.realString(0.842105263157895), "0.8421")
        expectEqual(SQLiteValueFormat.realString(-0.00722589489603039), "-0.0072")
        // Large PnL with integer grouping + 2 decimals
        expectEqual(SQLiteValueFormat.realString(14387.06458, decimals: 2, trimTrailingZeros: false), "14,387.06")
        expectEqual(SQLiteValueFormat.realString(14387.06458, decimals: 2, trimTrailingZeros: false, forceSign: true), "+14,387.06")
        // Raw text keeps full IEEE-754 representation
        let val = SQLiteValue.real(46.4199981689453)
        expectEqual(val.displayText, "46.42")
        expectTrue(val.rawText.hasPrefix("46.419998"))
    }

    // WITHOUT ROWID Composite PK Keyset Seeking Tests
    await test("RowReader: WITHOUT ROWID composite primary key keyset seeking") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("without_rowid_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("""
            CREATE TABLE daily_bar (
                symbol TEXT NOT NULL,
                date TEXT NOT NULL,
                close REAL NOT NULL,
                volume INTEGER NOT NULL,
                PRIMARY KEY (symbol, date)
            ) WITHOUT ROWID
        """)
        try conn.exec("BEGIN TRANSACTION")
        let symbols = ["AAA", "QQQ", "SPY", "TQQQ", "VOO"]
        for sym in symbols {
            for day in 1...40 {
                let dStr = String(format: "2026-01-%02d", day)
                try conn.exec("INSERT INTO daily_bar VALUES ('\(sym)', '\(dStr)', \(100.0 + Double(day) * 0.25), \(1000 * day))")
            }
        }
        try conn.exec("COMMIT")
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        let cols = try doc.columns(for: "daily_bar")
        expectEqual(cols[0].pkIndex, 1)
        expectEqual(cols[1].pkIndex, 2)

        // Page 1 (offset 0, no OFFSET scan needed -> pk-keyset)
        let p1 = try doc.rows(window: Window(table: "daily_bar", limit: 50))
        expectEqual(p1.path, "pk-keyset")
        expectEqual(p1.rows.count, 50)
        expectEqual(p1.rows.first?[0], .text("AAA"))
        expectEqual(p1.rows.first?[1], .text("2026-01-01"))

        // Walk the entire 200-row WITHOUT ROWID table via afterPKValues keyset seeks
        var collected: [String] = p1.rows.map { "\($0[0].textValue!)|\($0[1].textValue!)" }
        var lastRow = p1.rows.last!
        var off: Int64 = 50
        for _ in 0..<5 {
            let anchorPK: [SQLiteValue] = [lastRow[0], lastRow[1]]
            let pg = try doc.rows(window: Window(
                table: "daily_bar",
                limit: 50,
                useAfter: true,
                offset: off,
                afterPKValues: anchorPK
            ))
            if pg.rows.isEmpty { break }
            expectEqual(pg.path, "pk-keyset")
            collected.append(contentsOf: pg.rows.map { "\($0[0].textValue!)|\($0[1].textValue!)" })
            lastRow = pg.rows.last!
            off += 50
        }
        expectEqual(collected.count, 200)
        expectEqual(Set(collected).count, 200)
    }

    // QueryStyle Trim, Summary & Lineage Tests
    await test("QueryStyle: Trim column ordering/hiding, Summary rollup, and View lineage") {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("querystyle_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("""
            CREATE TABLE regime_score (
                rn INTEGER,
                empty_col TEXT,
                created_at TEXT,
                avg_hold_days REAL,
                profit_factor REAL,
                total_net_pnl REAL,
                avg_return_pct REAL,
                win_rate REAL,
                wins INTEGER,
                n INTEGER,
                regime TEXT,
                win TEXT,
                strategy_id TEXT PRIMARY KEY
            )
        """)
        try conn.exec("""
            INSERT INTO regime_score VALUES
            (1, NULL, '2026-10-12', 3.6, 10.84, 14387.06, 0.0635, 0.875, 7, 8, 'bull', 'in_sample', 'strat_a'),
            (2, NULL, '2026-10-12', 4.0, 1.94, 26705.02, 0.0391, 0.842, 16, 19, 'sideways', 'in_sample', 'strat_b'),
            (3, NULL, '2026-10-12', 4.3, 8.25, 26568.44, 0.0784, 0.900, 9, 10, 'bull', 'oos', 'strat_c'),
            (4, NULL, '2026-10-12', 4.5, 1.07, 3473.08, 0.0061, 0.833, 25, 30, 'sideways', 'oos', 'strat_d'),
            (5, NULL, '2026-10-12', 3.2, 5.50, 9500.00, 0.0510, 0.880, 11, 12, 'bull', 'oos', 'strat_e')
        """)
        try conn.exec("""
            CREATE VIEW v_bull_regimes AS
            -- High-conviction bull regime filter
            SELECT strategy_id, win, regime, win_rate, total_net_pnl
            FROM regime_score
            WHERE regime = 'bull'
        """)
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        let plan = doc.trimPlan(for: "regime_score")
        // Primary key `strategy_id` must be ordered first
        expectEqual(plan.ordered.first?.name, "strategy_id")
        // `empty_col`, `rn` (row number), and `created_at` (system column) must be hidden in Trim
        expectTrue(plan.hidden.contains("empty_col"))
        expectTrue(plan.hidden.contains("rn"))
        expectTrue(plan.hidden.contains("created_at"))

        // Summary mode groups by low-cardinality dimensions (regime, win)
        let summary = try doc.summaryPage(for: "regime_score")
        expectEqual(summary.path, "summary-group")
        expectTrue(summary.rows.count >= 2)
        expectTrue(summary.columns.contains { $0.name == "rows" })

        // View lineage & comment extraction
        let lineage = doc.viewLineage(for: "v_bull_regimes")
        expectEqual(lineage.comment, "High-conviction bull regime filter")
        expectEqual(lineage.upstream, ["regime_score"])
        let parentLineage = doc.viewLineage(for: "regime_score")
        expectEqual(parentLineage.downstream, ["v_bull_regimes"])

        // Related tables by column name
        let related = doc.relatedTables(forColumn: "strategy_id", excluding: "regime_score")
        expectEqual(related, ["v_bull_regimes"])
    }

    await test("FolderScanner: Resolves stripped leading slash & scans nested SQLite files") {
        let rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sqldoc_folder_test_\(UUID().uuidString)")
        let subDir = rootDir.appendingPathComponent("reports/oos")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db1Path = rootDir.appendingPathComponent("daily_bars.db").path
        let db2Path = subDir.appendingPathComponent("rotation.db").path

        for (p, tbl) in [(db1Path, "daily_bars"), (db2Path, "rotation_summary")] {
            let conn = try SQLiteConnection(path: p, readOnly: false)
            try conn.exec("CREATE TABLE \(tbl) (id INT, val REAL); CREATE VIEW v_\(tbl) AS SELECT * FROM \(tbl);")
            conn.close()
        }

        // Verify resolveLocalPath restores a stripped leading "/" (from BanquetParser.cleanURL)
        let stripped = String(rootDir.path.dropFirst())
        let resolved = FolderScanner.resolveLocalPath(stripped + "/")
        expectEqual(resolved, rootDir.standardizedFileURL.path)
        expectTrue(FolderScanner.isDirectory(resolved))

        let scanned = FolderScanner.scan(rootPath: stripped, maxDepth: 4, inspectSchema: true)
        expectEqual(scanned.files.count, 2)
        expectEqual(scanned.folders.count, 2)
        expectEqual(scanned.files[0].name, "daily_bars.db")
        expectEqual(scanned.files[0].relativeFolder, ".")
        expectEqual(scanned.files[0].tables, ["daily_bars"])
        expectEqual(scanned.files[0].views, ["v_daily_bars"])
        expectEqual(scanned.files[1].name, "rotation.db")
        expectEqual(scanned.files[1].relativeFolder, "reports/oos")
    }

    await test("Banquet: Pasted SQL & aggregate expressions in Banquet URL") {
        let b1 = try BanquetParser.parse("daily_bars.db/daily_bar[0:100]/select count(*), min(date), max(date) from daily_bar where symbol='QQQ';")
        expectEqual(b1.dataSetPath, "daily_bars.db")
        expectEqual(b1.table, "daily_bar")
        expectEqual(b1.select, ["count(*)", "min(date)", "max(date)"])
        expectEqual(b1.whereClause, "symbol='QQQ'")
        expectEqual(b1.offset, 0)
        expectEqual(b1.limit, 100)
        expectEqual(b1.groupBy, nil)

        let b2 = try BanquetParser.parse("daily_bars.db/daily_bar[0:100]/count(*), min(date), max(date)?where=symbol='QQQ'")
        expectEqual(b2.dataSetPath, "daily_bars.db")
        expectEqual(b2.table, "daily_bar")
        expectEqual(b2.select, ["count(*)", "min(date)", "max(date)"])
        expectEqual(b2.whereClause, "symbol='QQQ'")
        expectEqual(b2.offset, 0)
        expectEqual(b2.limit, 100)
        expectEqual(b2.groupBy, nil)

        let sql = BanquetComposer.compose(b1)
        expectEqual(sql, "SELECT count(*), min(date), max(date) FROM \"daily_bar\" WHERE symbol='QQQ' LIMIT 100 OFFSET 0")
    }

    await test("Banquet: Collection & Database Overview URLs") {
        // 1. Root folder databases collection
        let b1 = try BanquetParser.parse("data/databases")
        expectEqual(b1.dataSetPath, "data")
        expectEqual(b1.table, "databases")
        expectTrue(b1.isCollection || b1.table == "databases")

        // 2. Subfolder collection with sort and where query
        let b2 = try BanquetParser.parse("data/reports/1/oos/databases/-size_bytes?where=markov")
        expectEqual(b2.dataSetPath, "data/reports/1/oos")
        expectEqual(b2.table, "databases")
        expectEqual(b2.sortColumn, "size_bytes")
        expectTrue(b2.isSortDesc)
        expectEqual(b2.whereClause, "markov")

        // 3. Database Overview (tables catalog)
        let b3 = try BanquetParser.parse("reports/1/oos/markov.db/tables")
        expectEqual(b3.dataSetPath, "reports/1/oos/markov.db")
        expectEqual(b3.table, "tables")
    }

    // Omnibox-style suggestions, history, back/forward
    await test("BanquetSuggester: ranking, tables, columns, dedupe") {
        let ctx = BanquetSuggestContext(
            history: ["/d/sales.db/orders[0:100]", "/d/sales.db/customers[0:100]"],
            recents: [.init(path: "/d/markov.db", name: "markov.db")],
            openDocs: [.init(path: "/d/sales.db", name: "sales.db")],
            activeDocPath: "/d/sales.db", tables: ["orders", "customers", "order_items"],
            activeTable: "orders", columns: ["id", "name", "amount"])
        // prefix beats substring; tables come before history at equal score
        let s = BanquetSuggester.suggestions(for: "ord", context: ctx)
        expectEqual(s.first?.kind, .table)
        expectEqual(s.first?.completion, "/d/sales.db/orders")
        expectTrue(s.contains { $0.display == "order_items" })
        // no row repeats a completion
        expectEqual(Set(s.map(\.completion)).count, s.count)
        // column completion on the last segment, sort marker kept
        let c = BanquetSuggester.suggestions(for: "/d/sales.db/orders/-am", context: ctx)
        expectEqual(c.first?.completion, "/d/sales.db/orders/-amount")
        expectEqual(c.first?.kind, .column)
        // an exact column is not re-suggested; columns need the table in the path
        expectTrue(BanquetSuggester.suggestions(for: "/d/sales.db/orders/amount", context: ctx).allSatisfy { $0.kind != .column })
        expectTrue(BanquetSuggester.suggestions(for: "/d/other.db/x/am", context: ctx).allSatisfy { $0.kind != .column })
        // history rows are removable, others are not
        let h = BanquetSuggester.suggestions(for: "custom", context: ctx)
        expectTrue(h.contains { $0.kind == .history && $0.removable })
        expectTrue(h.allSatisfy { $0.kind == .history || !$0.removable })
        // limit and empty input
        expectEqual(BanquetSuggester.suggestions(for: "o", context: ctx, limit: 1).count, 1)
        expectTrue(BanquetSuggester.suggestions(for: "zzz-nothing", context: ctx).isEmpty)
        expectEqual(BanquetSuggester.suggestions(for: "", context: ctx).first?.kind, .history)
    }

    await test("BanquetSuggester: @keywords") {
        let ctx = BanquetSuggestContext(
            history: ["/d/a.db/t1", "/d/b.db/t2"],
            recents: [.init(path: "/d/markov.db", name: "markov.db")],
            openDocs: [.init(path: "/d/a.db", name: "a.db")],
            activeDocPath: "/d/a.db", tables: ["t1", "events"], activeTable: "t1", columns: [])
        let kw = BanquetSuggester.suggestions(for: "@ta", context: ctx)
        expectEqual(kw.map(\.display), ["@tables"])
        expectEqual(kw.first?.completion, "@tables ")
        expectEqual(BanquetSuggester.suggestions(for: "@", context: ctx).count, BanquetSuggester.keywords.count)
        expectEqual(BanquetSuggester.suggestions(for: "@tables ev", context: ctx).map(\.completion), ["/d/a.db/events"])
        expectEqual(BanquetSuggester.suggestions(for: "@tables ", context: ctx).count, 2)
        expectEqual(BanquetSuggester.suggestions(for: "@recent mark", context: ctx).map(\.display), ["markov.db"])
        expectEqual(BanquetSuggester.suggestions(for: "@open", context: ctx).first?.kind, .keyword)
        expectEqual(BanquetSuggester.suggestions(for: "@open ", context: ctx).map(\.display), ["a.db"])
        expectEqual(BanquetSuggester.suggestions(for: "@history b.db", context: ctx).map(\.completion), ["/d/b.db/t2"])
        // unknown keyword with a space matches nothing rather than falling through to plain text
        expectTrue(BanquetSuggester.suggestions(for: "@nope x", context: ctx).isEmpty)
    }

    await test("BanquetHistory: record, dedupe, cap, remove, persistence") {
        let suite = "sqldoc.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let h = BanquetHistory(storageKey: "k", defaults: d, maxEntries: 3)
        h.record("a"); h.record("b"); h.record("c"); h.record("a")
        expectEqual(h.entries, ["a", "c", "b"])
        h.record("d")
        expectEqual(h.entries, ["d", "a", "c"])      // oldest dropped at the cap
        h.record("   "); h.record("")
        expectEqual(h.entries.count, 3)              // blanks ignored
        h.remove("a")
        expectEqual(h.entries, ["d", "c"])
        expectEqual(BanquetHistory(storageKey: "k", defaults: d, maxEntries: 3).entries, ["d", "c"])
    }

    await test("BanquetRecall: ↑ older, ↓ newer, back to draft") {
        var r = BanquetRecall()
        let e = ["c", "b", "a"]
        expectEqual(r.step(older: false, current: "x", entries: e), nil)   // ↓ with no walk
        expectEqual(r.step(older: true, current: "draft", entries: e), "c")
        expectEqual(r.step(older: true, current: "c", entries: e), "b")
        expectEqual(r.step(older: true, current: "b", entries: e), "a")
        expectEqual(r.step(older: true, current: "a", entries: e), nil)    // oldest: stay
        expectEqual(r.step(older: false, current: "a", entries: e), "b")
        expectEqual(r.step(older: false, current: "b", entries: e), "c")
        expectEqual(r.step(older: false, current: "c", entries: e), "draft")
        expectTrue(!r.isRecalling)
        expectEqual(r.step(older: true, current: "new", entries: []), nil) // empty history
        var q = BanquetRecall()
        expectEqual(q.step(older: true, current: "c", entries: e), "b")   // skips the URL already showing
        expectEqual(q.step(older: false, current: "b", entries: e), "c")  // ↓ returns to the draft
    }

    await test("TableList: ordering, header, empty placeholder") {
        func sec(_ n: String, _ rows: Int64) -> TableListSection {
            TableListSection(name: n, rowCount: rows, rowCountText: "\(rows)",
                             category: TableListCategory.classify(rowCount: rows),
                             columns: ["a", "b"], cells: [])
        }
        let ordered = TableListBuilder.ordered([sec("empty", 0), sec("big", 5000), sec("t3", 3),
                                                sec("huge", 90000), sec("t19", 19), sec("t20", 20)])
        // Tiny (1-19) first by count desc, then Large (20+) by count desc, then Empty.
        expectEqual(ordered.map(\.name), ["t19", "t3", "huge", "big", "t20", "empty"])
        expectEqual(sec("steps", 3152).header, "=== Table: steps (3152 rows, 2 columns) ===")
        expectEqual(sec("one", 1).header, "=== Table: one (1 row, 2 columns) ===")
        expectEqual(TableListBuilder.emptyRows(columnCount: 3), [["(Empty)", "", ""]])
    }

    await test("BanquetNavStack: back/forward, truncation, cap") {
        var n = BanquetNavStack(maxEntries: 3)
        expectTrue(!n.canGoBack && !n.canGoForward)
        n.visit("a"); n.visit("b"); n.visit("b")    // same URL twice is one entry
        expectEqual(n.entries, ["a", "b"])
        expectEqual(n.back(), "a")
        expectEqual(n.back(), nil)
        expectEqual(n.forward(), "b")
        _ = n.back()
        n.visit("c")                                  // new visit drops "b"
        expectEqual(n.entries, ["a", "c"])
        expectTrue(!n.canGoForward)
        n.visit("d"); n.visit("e")                    // cap of 3 drops the oldest
        expectEqual(n.entries, ["c", "d", "e"])
        expectEqual(n.current, "e")
    }

    await test("Theme: configured first-launch default applies only until a theme is chosen") {
        let suite = "sqldoc.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = StatePersistenceManager(defaults: d)
        // Nothing stored: whatever config/seed.sql `ui.theme_default` says.
        expectEqual(p.themeMode, AppThemeMode(rawValue: BehaviorConfig.uiThemeDefault))
        expectEqual(BehaviorConfig.uiThemeDefault, "dark")
        // An explicit choice, including System, is kept and never overridden by the default.
        p.themeMode = .system
        expectEqual(StatePersistenceManager(defaults: d).themeMode, .system)
        p.themeMode = .light
        expectEqual(StatePersistenceManager(defaults: d).themeMode, .light)
        // The default accent is the configured token, not a literal in Style.swift.
        expectEqual(Style.default.accent, DesignToken.accentHex)
        expectEqual(DesignToken.accentHex, "#0f9d58")
    }

    // Edit mode (docs/BanquetEditStyle.md)
    func makeEditDB() throws -> String {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("edit_\(UUID().uuidString).db")
        let c = try SQLiteConnection(path: p, readOnly: false)
        try c.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER, price REAL, note TEXT)")
        try c.exec("INSERT INTO t VALUES (1,'a',10,1.5,NULL),(2,'b',20,2.5,'x')")
        try c.exec("CREATE VIEW v AS SELECT * FROM t")
        try c.exec("CREATE TABLE w (k TEXT PRIMARY KEY, val TEXT) WITHOUT ROWID")
        c.close()
        return p
    }

    await test("EditBuffer: stage, no-op drop, undo/redo, revert") {
        let b = EditBuffer()
        let e1 = CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(11))
        b.stage(e1)
        expectEqual(b.count, 1)
        expectEqual(b.pending(table: "t", rowID: 1, column: "qty"), .integer(11))
        // Back to the original drops the entry.
        b.stage(CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(11), new: .integer(10)))
        expectEqual(b.count, 0)
        expectTrue(b.undo()); expectEqual(b.count, 1)
        expectTrue(b.undo()); expectEqual(b.count, 0)
        expectTrue(!b.undo())
        expectTrue(b.redo()); expectEqual(b.count, 1)
        b.revert()
        expectEqual(b.count, 0); expectTrue(!b.canUndo)
    }

    await test("CellCoercion: affinity, bad input, NULL rules") {
        let int = Column(name: "qty", type: "INTEGER")
        let real = Column(name: "price", type: "REAL")
        let text = Column(name: "name", type: "TEXT", notNull: true)
        expectEqual(try? CellCoercion.parse(" 42 ", for: int).get(), .integer(42))
        expectTrue((try? CellCoercion.parse("4.2", for: int).get()) == nil)
        expectEqual(try? CellCoercion.parse("2.5", for: real).get(), .real(2.5))
        expectTrue((try? CellCoercion.parse("abc", for: real).get()) == nil)
        expectEqual(try? CellCoercion.parse("", for: text).get(), .text(""))
        expectTrue((try? CellCoercion.null(for: text).get()) == nil)
        expectEqual(try? CellCoercion.null(for: int).get(), SQLiteValue.null)
    }

    await test("EditSession: commit persists, conflict rolls back everything") {
        let path = try makeEditDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = try Doc.open(path: path)
        defer { doc.close() }
        let s = try EditSession(doc: doc)
        defer { s.close() }

        s.buffer.stage(CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(99)))
        s.buffer.stage(CellEdit(table: "t", rowID: 2, column: "note", original: .text("x"), new: .null))
        try s.commit()
        expectEqual(s.buffer.count, 0)
        let check = try SQLiteConnection(path: path)
        expectEqual(try check.queryRow("SELECT qty FROM t WHERE id=1")?.first, .integer(99))
        expectEqual(try check.queryRow("SELECT note FROM t WHERE id=2")?.first, SQLiteValue.null)
        check.close()

        // Stale original on the second edit: whole commit must roll back, including the first.
        s.buffer.stage(CellEdit(table: "t", rowID: 1, column: "name", original: .text("a"), new: .text("A")))
        s.buffer.stage(CellEdit(table: "t", rowID: 2, column: "name", original: .text("STALE"), new: .text("B")))
        var conflicted = false
        do { try s.commit() } catch let e as EditError { if case .conflict = e { conflicted = true } }
        expectTrue(conflicted)
        let after = try SQLiteConnection(path: path)
        expectEqual(try after.queryRow("SELECT name FROM t WHERE id=1")?.first, .text("a"))
        after.close()
        expectEqual(s.buffer.count, 2) // buffer kept so the user can see/resolve
    }

    await test("EditSession: eligibility and immutable refusal; read connection stays query_only") {
        let path = try makeEditDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = try Doc.open(path: path)
        defer { doc.close() }
        expectEqual(EditSession.ineligibleReason(doc: doc, table: "t"), nil)
        expectTrue(EditSession.ineligibleReason(doc: doc, table: "v") != nil)
        expectTrue(EditSession.ineligibleReason(doc: doc, table: "w") != nil)
        var refused = false
        do { _ = try EditSession(doc: try Doc.open(path: path, options: DocOptions(isImmutable: true))) }
        catch { refused = true }
        expectTrue(refused)
        var wrote = true
        do { try doc.fg.exec("UPDATE t SET qty=0") } catch { wrote = false }
        expectTrue(!wrote, "viewer connection must stay read-only")
    }

    await test("EditBuffer: new rows, deletes, grouped undo/redo, batch") {
        let b = EditBuffer()
        let id1 = b.insertRow(table: "t", values: ["name": .text("n1")])
        let id2 = b.insertRow(table: "t")
        expectTrue(id1 < 0 && id2 < id1, "temp ids are negative and distinct")
        b.setNewRowValue(id: id2, column: "name", value: .text("n2"))
        expectEqual(b.newRows(table: "t").map(\.id), [id1, id2])
        expectEqual(b.count, 2)

        // Deleting a stored row also drops its pending cell edits; one undo restores both.
        b.stage(CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(11)))
        expectEqual(b.count, 3)
        b.deleteRow(table: "t", rowID: 1, original: ["id": .integer(1), "qty": .integer(10)])
        expectTrue(b.isDeleted(table: "t", rowID: 1))
        expectEqual(b.updateCount, 0)
        expectEqual(b.deleteCount, 1)
        // Edits to a row staged for delete are ignored.
        b.stage(CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(12)))
        expectEqual(b.updateCount, 0)
        b.undo()
        expectTrue(!b.isDeleted(table: "t", rowID: 1))
        expectEqual(b.pending(table: "t", rowID: 1, column: "qty"), .integer(11))
        b.redo()
        expectTrue(b.isDeleted(table: "t", rowID: 1))

        // Deleting a new row just drops it.
        b.deleteRow(table: "t", rowID: id1, original: [:])
        expectEqual(b.insertCount, 1)
        b.undo()
        expectEqual(b.insertCount, 2)

        // A batch is one undo step.
        b.revert()
        expectEqual(b.count, 0)
        b.stageBatch([
            CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(1)),
            CellEdit(table: "t", rowID: 2, column: "qty", original: .integer(20), new: .integer(2)),
        ])
        expectEqual(b.updateCount, 2)
        b.undo()
        expectEqual(b.count, 0)
        expectTrue(!b.canUndo)
    }

    await test("EditSession: insert + delete + update commit in one transaction, preview matches") {
        let path = try makeEditDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = try Doc.open(path: path)
        defer { doc.close() }
        let s = try EditSession(doc: doc)
        defer { s.close() }

        s.buffer.stage(CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(99)))
        s.buffer.deleteRow(table: "t", rowID: 2, original: [
            "id": .integer(2), "name": .text("b"), "qty": .integer(20), "price": .real(2.5), "note": .text("x"),
        ])
        s.buffer.insertRow(table: "t", values: ["name": .text("it's"), "qty": .integer(7)])
        let preview = s.sqlPreview()
        expectEqual(preview.count, 3)
        expectTrue(preview[0].hasPrefix("UPDATE \"t\" SET \"qty\" = 99"))
        expectTrue(preview[1].hasPrefix("DELETE FROM \"t\" WHERE rowid = 2"))
        expectTrue(preview[2].contains("'it''s'"), "preview escapes quotes")
        try s.commit()
        expectEqual(s.buffer.count, 0)
        let check = try SQLiteConnection(path: path)
        expectEqual(try check.queryRow("SELECT qty FROM t WHERE id=1")?.first, .integer(99))
        expectEqual(try check.queryRow("SELECT count(*) FROM t WHERE name='b'")?.first, .integer(0)) // the insert reuses id 2
        expectEqual(try check.queryRow("SELECT qty FROM t WHERE name='it''s'")?.first, .integer(7))
        check.close()
    }

    await test("EditSession: a failed insert or stale delete rolls everything back") {
        let path = try makeEditDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = try Doc.open(path: path)
        defer { doc.close() }
        let s = try EditSession(doc: doc)
        defer { s.close() }

        // NOT NULL column `name` has no default: refused before anything is written.
        s.buffer.stage(CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(55)))
        s.buffer.insertRow(table: "t", values: ["qty": .integer(1)])
        expectEqual(s.missingRequiredColumns(table: "t", values: ["qty": .integer(1)]), ["name"])
        var refused = false
        do { try s.commit() } catch let e as EditError { if case .invalidValue = e { refused = true } }
        expectTrue(refused)
        let c1 = try SQLiteConnection(path: path)
        expectEqual(try c1.queryRow("SELECT qty FROM t WHERE id=1")?.first, .integer(10))
        c1.close()
        s.buffer.revert()

        // Delete whose original no longer matches: conflict, and the earlier update rolls back.
        s.buffer.stage(CellEdit(table: "t", rowID: 1, column: "qty", original: .integer(10), new: .integer(55)))
        s.buffer.deleteRow(table: "t", rowID: 2, original: ["id": .integer(2), "qty": .integer(999)])
        var conflicted = false
        do { try s.commit() } catch let e as EditError { if case .conflict = e { conflicted = true } }
        expectTrue(conflicted)
        let c2 = try SQLiteConnection(path: path)
        expectEqual(try c2.queryRow("SELECT qty FROM t WHERE id=1")?.first, .integer(10))
        expectEqual(try c2.queryRow("SELECT count(*) FROM t WHERE id=2")?.first, .integer(1))
        c2.close()

        // A delete with a clipped/BLOB guard column commits on the remaining columns.
        s.buffer.revert()
        s.buffer.deleteRow(table: "t", rowID: 2, original: [
            "id": .integer(2), "note": .textPrefix("x", totalBytes: 9_999_999),
        ])
        try s.commit()
    }

    await test("CellCoercion: empty string only for non-numeric columns") {
        expectEqual(try? CellCoercion.emptyString(for: Column(name: "n", type: "TEXT")).get(), .text(""))
        expectTrue((try? CellCoercion.emptyString(for: Column(name: "q", type: "INTEGER")).get()) == nil)
    }

    await test("FolderSort: columns, direction, URL clause, header toggle") {
        func f(_ name: String, size: Int64, tables: Int, mod: TimeInterval, folder: String = ".") -> SQLiteFileEntry {
            SQLiteFileEntry(path: "/x/\(folder)/\(name)", name: name, folderPath: "/x/\(folder)", relativeFolder: folder,
                            relativePath: "\(folder)/\(name)", size: size, modified: Date(timeIntervalSince1970: mod),
                            tables: (0..<tables).map { "t\($0)" }, views: [])
        }
        let files = [f("b.db", size: 300, tables: 2, mod: 100), f("a.db", size: 100, tables: 9, mod: 300),
                     f("c.db", size: 200, tables: 2, mod: 200, folder: "z")]
        func names(_ s: FolderSort) -> [String] { s.sorted(files).map(\.name) }
        expectEqual(names(FolderSort(key: .size)), ["b.db", "c.db", "a.db"])               // numbers default largest first
        expectEqual(names(FolderSort(key: .size, descending: false)), ["a.db", "c.db", "b.db"])
        expectEqual(names(FolderSort(key: .tableCount)), ["a.db", "b.db", "c.db"])         // tie on 2 falls back to name
        expectEqual(names(FolderSort(key: .modified)), ["a.db", "c.db", "b.db"])
        expectEqual(names(FolderSort(key: .name)), ["a.db", "b.db", "c.db"])
        expectEqual(names(FolderSort(key: .location)), ["a.db", "b.db", "c.db"])           // "." before "z", then name
        expectEqual(names(.scanOrder), ["b.db", "a.db", "c.db"])                           // scan order untouched

        expectEqual(FolderSort.scanOrder.urlClause, "")
        expectEqual(FolderSort(key: .size).urlClause, "-size_bytes")
        expectEqual(FolderSort(key: .tableCount, descending: false).urlClause, "+table_count")
        expectEqual(FolderSortKey(column: "size_bytes"), .size)
        expectEqual(FolderSortKey(column: "table_count"), .tableCount)
        expectEqual(FolderSortKey(column: "modified"), .modified)
        expectTrue(FolderSortKey(column: "status") == nil)

        let s1 = FolderSort.scanOrder.toggled(to: .size)
        expectEqual(s1, FolderSort(key: .size, descending: true))
        expectEqual(s1.toggled(to: .size), FolderSort(key: .size, descending: false))     // same header flips
        expectEqual(s1.toggled(to: .name), FolderSort(key: .name, descending: false))      // another header resets to its default
    }

    // Query control (docs/GUIStability.md, technique 3)
    // A statement that never finishes on its own.
    let endless = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n"

    await test("QueryControl: budget stops a runaway statement with .timedOut") {
        let conn = try SQLiteConnection(path: ":memory:", readOnly: false)
        defer { conn.close() }
        let start = Date()
        var timedOut = false
        do { _ = try conn.query(endless, control: QueryControl(budgetMs: 150)) }
        catch SQLiteError.timedOut { timedOut = true }
        expectTrue(timedOut, "expected .timedOut")
        expectTrue(Date().timeIntervalSince(start) < 3, "budget should stop it promptly")
        // The connection is usable afterwards and the handler is gone.
        expectEqual(try conn.queryRow("SELECT 41 + 1")?.first, .integer(42))
    }

    await test("QueryControl: token cancels from another thread; next query unaffected") {
        let conn = try SQLiteConnection(path: ":memory:", readOnly: false)
        defer { conn.close() }
        let token = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let start = Date()
        var cancelled = false
        do { _ = try conn.query(endless, control: QueryControl(token: token)) }
        catch SQLiteError.cancelled { cancelled = true }
        expectTrue(cancelled, "expected .cancelled")
        expectTrue(Date().timeIntervalSince(start) < 3, "cancel should land promptly")
        expectEqual(try conn.queryRow("SELECT 7")?.first, .integer(7))
        // A token cancelled before the statement starts means it never runs.
        var skipped = false
        do { _ = try conn.query("SELECT 1", control: QueryControl(token: token)) }
        catch SQLiteError.cancelled { skipped = true }
        expectTrue(skipped, "pre-cancelled token must not run")
    }

    await test("QueryControl: superseded loads queued on one connection do not run") {
        let conn = try SQLiteConnection(path: ":memory:", readOnly: false)
        defer { conn.close() }
        // Three loads requested in a row; each supersedes the one before, as
        // TableViewModel.beginLoad does. Only the last may produce rows.
        let tokens = [CancelToken(), CancelToken(), CancelToken()]
        let outcomes = Outcomes()
        for (i, token) in tokens.enumerated() {
            let sql = i < 2 ? endless : "SELECT 99"
            DispatchQueue.global().async {
                do {
                    let rows = try conn.query(sql, control: QueryControl(budgetMs: 20_000, token: token))
                    outcomes.record(i, rows.first?.first?.intValue.map { "rows:\($0)" } ?? "empty")
                } catch SQLiteError.cancelled { outcomes.record(i, "cancelled") }
                catch { outcomes.record(i, "error") }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            if i < 2 { token.cancel() }
        }
        // Without cancellation the first statement would hold the connection for
        // its whole 20 s budget; with it, all three settle almost at once.
        let start = Date()
        while outcomes.all.count < 3 && Date().timeIntervalSince(start) < 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expectEqual(outcomes.all, ["cancelled", "cancelled", "rows:99"])
    }

    await test("QueryControl: Doc.runQuery and Doc.rows honour budget and token") {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("qc_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: p) }
        let c = try SQLiteConnection(path: p, readOnly: false)
        try c.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        try c.exec("INSERT INTO t VALUES (1,'a'),(2,'b')")
        c.close()
        let doc = try Doc.open(path: p)
        defer { doc.close() }

        var timedOut = false
        do { _ = try doc.runQuery(endless, control: QueryControl(budgetMs: 150)) }
        catch SQLiteError.timedOut { timedOut = true }
        expectTrue(timedOut, "console query must time out")
        // Counts and find share that connection; they must work straight after.
        expectEqual(try doc.runQuery("SELECT count(*) FROM t").rows.first?.first, .integer(2))

        let dead = CancelToken()
        dead.cancel()
        var cancelled = false
        do { _ = try doc.rows(window: Window(table: "t", limit: 10), control: QueryControl(token: dead)) }
        catch SQLiteError.cancelled { cancelled = true }
        expectTrue(cancelled, "page load must honour its token")
        expectEqual(try doc.rows(window: Window(table: "t", limit: 10)).rows.count, 2)
        expectEqual(Doc.queryRowCap, BehaviorConfig.queryRowCap)

        // Page loads run on their own connection so metadata reads on `fg` never
        // queue behind them; it is opened the same way and is just as read-only.
        expectTrue(doc.pages !== doc.fg && doc.pages !== doc.bg)
        var wrote = true
        do { try doc.pages.exec("UPDATE t SET v = 'x'") } catch { wrote = false }
        expectTrue(!wrote, "the page connection must stay read-only")
        // A long page load holds `pages`, not `fg`: metadata stays instant meanwhile.
        let slow = CancelToken()
        let started = Date()
        DispatchQueue.global().async {
            _ = try? doc.pages.query(endless, control: QueryControl(budgetMs: 2_000, token: slow))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let t0 = Date()
        expectEqual(doc.estimateRows(for: "t").known, true)
        expectEqual(try doc.columns(for: "t").count, 2)
        expectTrue(Date().timeIntervalSince(t0) < 0.2, "metadata waited behind a page load")
        slow.cancel()
        _ = started
    }

    // Cell-size caps (docs/GUIStability.md, technique 4)
    await test("TextPrefix: grid pages carry only the head of a huge TEXT cell") {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("big_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: p) }
        let c = try SQLiteConnection(path: p, readOnly: false)
        try c.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT, n INTEGER)")
        // 10 MB of ASCII; a value whose cap falls inside a 2-byte character; a short one.
        try c.exec("INSERT INTO t VALUES (1, printf('%.*c', 10485760, 'x'), 1)")
        try c.exec("INSERT INTO t VALUES (2, 'a' || replace(printf('%.*c', 3000, 'e'), 'e', 'é'), 2)")
        try c.exec("INSERT INTO t VALUES (3, 'short', 3)")
        try c.exec("CREATE TABLE w (k TEXT PRIMARY KEY, body TEXT) WITHOUT ROWID")
        try c.exec("INSERT INTO w VALUES ('k1', printf('%.*c', 10000, 'y'))")
        c.close()
        let doc = try Doc.open(path: p)
        defer { doc.close() }
        let cap = BehaviorConfig.textCellFetchMaxBytes

        let page = try doc.rows(window: Window(table: "t", limit: 10))
        expectTrue(page.rowKeyed)
        guard case .textPrefix(let head, let total) = page.rows[0][1] else {
            fatalError("row 1 should be clipped, got \(page.rows[0][1].isPartial)")
        }
        expectEqual(total, 10_485_760)
        expectEqual(head.utf8.count, cap)
        expectTrue(page.text[0][1].truncated)
        expectTrue(page.text[0][1].text.count <= BehaviorConfig.textCellDisplayMaxChars + 1)

        // The cut backs up to a character boundary: no replacement characters, no half scalar.
        guard case .textPrefix(let head2, let total2) = page.rows[1][1] else { fatalError("row 2 should be clipped") }
        expectEqual(total2, 6001)
        expectEqual(head2.utf8.count, cap - 1)
        expectTrue(!head2.unicodeScalars.contains("\u{FFFD}"))
        expectTrue(head2.hasPrefix("aé") && head2.hasSuffix("é"))

        // Short values and other types are untouched.
        expectEqual(page.rows[2][1], .text("short"))
        expectEqual(page.rows[0][2], .integer(1))

        // The whole value is one rowid lookup away.
        let full = doc.cellValues(table: "t", columns: ["body", "n"], rowID: 1)
        expectEqual(full?.count, 2)
        if case .text(let s)? = full?.first { expectEqual(s.utf8.count, 10_485_760) } else { fatalError("expected full text") }
        expectEqual(full?.last, .integer(1))
        expectTrue(doc.cellValues(table: "t", columns: ["body"], rowID: 999) == nil)

        // No row key, no way to re-fetch: such pages keep the value whole.
        let wpage = try doc.rows(window: Window(table: "w", limit: 10))
        expectTrue(!wpage.rowKeyed)
        if case .text(let s) = wpage.rows[0][1] { expectEqual(s.utf8.count, 10_000) } else { fatalError("WITHOUT ROWID cell should be whole") }
        expectTrue(doc.cellValues(table: "w", columns: ["body"], rowID: 1) == nil)

        // The console cuts at the same cap and says so.
        let qr = try doc.runQuery("SELECT body FROM t ORDER BY id",
                                  control: QueryControl(maxTextBytes: cap))
        expectTrue(qr.hasClippedText)
        expectTrue(try !doc.runQuery("SELECT body FROM t WHERE id = 3", control: QueryControl(maxTextBytes: cap)).hasClippedText)
        // Uncapped reads (export, find, editor) are unaffected.
        if case .text(let s)? = try doc.fg.queryRow("SELECT body FROM t WHERE id = 1")?.first {
            expectEqual(s.utf8.count, 10_485_760)
        } else { fatalError("uncapped read should be whole") }
    }

    await test("QueryControl: result byte budget stops an oversized result") {
        let conn = try SQLiteConnection(path: ":memory:", readOnly: false)
        defer { conn.close() }
        let sql = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000) SELECT printf('%.*c', 1000, 'z') FROM n"
        var tooLarge = false
        do { _ = try conn.query(sql, control: QueryControl(maxResultBytes: 100_000)) }
        catch SQLiteError.resultTooLarge { tooLarge = true }
        expectTrue(tooLarge, "expected .resultTooLarge")
        expectEqual(try conn.query(sql, control: QueryControl(maxResultBytes: 2_000_000)).count, 1000)
    }

    await test("EditSession: a clipped original is refused; the resolved value commits") {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("bigedit_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: p) }
        let c = try SQLiteConnection(path: p, readOnly: false)
        try c.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")
        try c.exec("INSERT INTO t VALUES (1, printf('%.*c', 20000, 'q'))")
        c.close()
        let doc = try Doc.open(path: p)
        defer { doc.close() }
        let page = try doc.rows(window: Window(table: "t", limit: 10))
        let clipped = page.rows[0][1]
        expectTrue(clipped.isPartial)

        let s = try EditSession(doc: doc)
        defer { s.close() }
        s.buffer.stage(CellEdit(table: "t", rowID: 1, column: "body", original: clipped, new: .text("new")))
        var refused = false
        do { try s.commit() } catch { refused = true }
        expectTrue(refused, "a clipped original must never reach the UPDATE")
        s.buffer.revert()

        // What the grid does instead: fetch the stored value, then stage against it.
        guard let whole = doc.cellValues(table: "t", columns: ["body"], rowID: 1)?.first else { fatalError("no value") }
        expectTrue(!whole.isPartial)
        s.buffer.stage(CellEdit(table: "t", rowID: 1, column: "body", original: whole, new: .text("new")))
        try s.commit()
        let check = try SQLiteConnection(path: p)
        expectEqual(try check.queryRow("SELECT body FROM t WHERE id = 1")?.first, .text("new"))
        check.close()
    }

    // Keyset paging under filters and sort, both directions (docs/GUIStability.md, technique 1)
    await test("Seek paging: forward, backward and from-end match offset paging row for row") {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("seek_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: p) }
        let c = try SQLiteConnection(path: p, readOnly: false)
        // 1,000 rows; `v` repeats heavily and is NULL for every 7th row; rowids have gaps.
        try c.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, grp INTEGER, v INTEGER, s TEXT)")
        try c.exec("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000)
            INSERT INTO t SELECT i * 3, i % 4, CASE WHEN i % 7 = 0 THEN NULL ELSE i % 23 END,
                                 CASE WHEN i % 11 = 0 THEN NULL ELSE 'k' || (i % 17) END FROM n
            """)
        c.close()
        let doc = try Doc.open(path: p)
        defer { doc.close() }
        let limit = 37
        let grp1 = [ColumnFilter(column: "grp", op: .equals, value: "1")]

        struct Case { let name: String; let filters: [ColumnFilter]; let sort: String?; let desc: Bool; let numeric: Bool }
        let cases = [
            Case(name: "plain", filters: [], sort: nil, desc: false, numeric: false),
            Case(name: "filtered", filters: grp1, sort: nil, desc: false, numeric: false),
            Case(name: "sorted asc", filters: [], sort: "v", desc: false, numeric: false),
            Case(name: "sorted desc", filters: [], sort: "v", desc: true, numeric: false),
            Case(name: "sorted numeric desc", filters: [], sort: "v", desc: true, numeric: true),
            Case(name: "filtered sorted asc", filters: grp1, sort: "v", desc: false, numeric: false),
            Case(name: "filtered sorted desc", filters: grp1, sort: "v", desc: true, numeric: false),
            Case(name: "filtered sorted text desc", filters: grp1, sort: "s", desc: true, numeric: false),
        ]

        for k in cases {
            func window(offset: Int64) -> Window {
                Window(table: "t", limit: limit, offset: offset, sort: k.sort, desc: k.desc,
                       forceOffset: false, sortNumeric: k.numeric, filters: k.filters)
            }
            // Ground truth: every page by counted offset. (Unfiltered, unsorted jumps
            // normally interpolate on rowid, which is approximate when ids have gaps.)
            let plain = k.filters.isEmpty && k.sort == nil
            var truth: [[Int64]] = []
            var off: Int64 = 0
            while true {
                var tw = window(offset: off)
                tw.forceOffset = plain
                var pg = try doc.rows(window: tw)
                if plain {
                    // The forced-offset path selects no rowid; `id` is the rowid alias.
                    pg.rowIDs = pg.rows.map { $0[0].intValue ?? 0 }
                }
                if pg.rows.isEmpty { break }
                expectTrue(!pg.path.contains("keyset"), "\(k.name): offset pages must not seek")
                truth.append(pg.rowIDs)
                off += Int64(pg.rows.count)
                if pg.rows.count < limit { break }
            }
            let total = truth.reduce(0) { $0 + $1.count }
            expectTrue(truth.count >= 5, "\(k.name): fixture too small")
            let sortIdx = k.sort.map { $0 == "v" ? 2 : 3 }

            // Forward: seek from the last row of each page.
            var page = try doc.rows(window: window(offset: 0))
            expectEqual(page.rowIDs, truth[0], "\(k.name): first page")
            expectTrue(page.rowKeyed)
            for i in 1..<truth.count {
                var w = window(offset: Int64(i * limit))
                w.useAfter = true
                w.after = page.rowIDs.last!
                w.afterSortValue = sortIdx.map { page.rows.last![$0] }
                page = try doc.rows(window: w)
                expectTrue(page.path.contains("keyset"), "\(k.name): forward page \(i) took \(page.path)")
                expectEqual(page.rowIDs, truth[i], "\(k.name): forward page \(i)")
            }

            // From the end: the last `limit` rows, wherever the page boundaries fall.
            var e = window(offset: Int64(max(0, total - limit)))
            e.fromEnd = true
            let tail = try doc.rows(window: e)
            expectTrue(tail.path.contains("keyset"), "\(k.name): tail took \(tail.path)")
            expectEqual(tail.rowIDs, Array(truth.joined().suffix(limit)), "\(k.name): tail")
            expectEqual(tail.start, Int64(total - limit))

            // Backward: from the last full page down to the second, seeking from each first row.
            page = tail
            // Re-anchor on a page boundary: seek back from the tail's rows that follow the last full page.
            var lastFull = window(offset: Int64((truth.count - 1) * limit))
            lastFull.useAfter = true
            lastFull.after = truth[truth.count - 2].last!
            lastFull.afterSortValue = sortIdx.map { _ in
                let prev = truth[truth.count - 2].last!
                return ((try? doc.fg.queryRow("SELECT \(k.sort!) FROM t WHERE id = ?", args: [prev]))??.first) ?? .null
            }
            page = try doc.rows(window: lastFull)
            expectEqual(page.rowIDs, truth[truth.count - 1], "\(k.name): last page by seek")
            for i in stride(from: truth.count - 2, through: 1, by: -1) {
                var w = window(offset: Int64(i * limit))
                w.backward = true
                w.after = page.rowIDs.first!
                w.afterSortValue = sortIdx.map { page.rows.first![$0] }
                page = try doc.rows(window: w)
                expectTrue(page.path.contains("keyset"), "\(k.name): backward page \(i) took \(page.path)")
                expectEqual(page.rowIDs, truth[i], "\(k.name): backward page \(i)")
            }
            // Stepping back past the start lands on the first page, not a short one.
            var w = window(offset: 0)
            w.backward = true
            w.after = truth[0][5]
            w.afterSortValue = sortIdx.map { _ in (try! doc.rows(window: window(offset: 0))).rows[5][sortIdx!] }
            expectEqual(try doc.rows(window: w).rowIDs, truth[0], "\(k.name): backward into the start")
        }

        // A clipped sort value cannot anchor a seek; the reader falls back rather than guess.
        var w = Window(table: "t", limit: limit, after: 30, useAfter: true, offset: 37, sort: "s")
        w.afterSortValue = .textPrefix("k1", totalBytes: 9999)
        expectEqual(try doc.rows(window: w).path, "sorted-offset")
    }

    print("\n-------------------------------------------------------")
    print("Results: \(passed) passed, \(failed) failed")
    print("-------------------------------------------------------\n")

    if failed > 0 {
        exit(1)
    }
}

// Helpers
func expect(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fatalError("Assertion failed: \(message) at \(file):\(line)")
    }
}

func expectEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b {
        fatalError("Expected \(String(describing: a)) == \(String(describing: b)). \(message) at \(file):\(line)")
    }
}

func expectTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    expect(condition == true, message, file: file, line: line)
}

func expectNotNil<T>(_ val: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    expect(val != nil, "Expected non-nil value. \(message)", file: file, line: line)
}

// Entry Point
Task {
    await runAllTests()
    exit(0)
}

RunLoop.main.run()

/// Thread-safe slot-per-index results for the concurrency tests.
final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Int: String] = [:]
    func record(_ i: Int, _ value: String) {
        lock.lock(); slots[i] = value; lock.unlock()
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return slots.keys.sorted().map { slots[$0] ?? "" }
    }
}
