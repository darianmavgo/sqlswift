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
