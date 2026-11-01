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
        expectEqual(b2.select, ["id", "name"])
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
        expectTrue(canonical.contains("history.db/orders/-total,id,total[50:75]"))
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
            (url: "data.sqlite;users;id,+name", expected: "SELECT \"id\" FROM \"users\" ORDER BY \"name\" ASC"),
            (url: "data.sqlite;users;id,-age,email", expected: "SELECT \"id\", \"email\" FROM \"users\" ORDER BY \"age\" DESC"),

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
            (url: "data.sqlite;users;id,name,-age?where=active=1&limit=5", expected: "SELECT \"id\", \"name\" FROM \"users\" WHERE active=1 ORDER BY \"age\" DESC LIMIT 5"),
            (url: "data.sqlite;users;id,email,+joined[10:20]", expected: "SELECT \"id\", \"email\" FROM \"users\" ORDER BY \"joined\" ASC LIMIT 10 OFFSET 10"),
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
