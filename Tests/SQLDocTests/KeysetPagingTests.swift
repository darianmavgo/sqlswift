import Testing
import Foundation
@testable import SQLDocCore

@Suite("KeysetPagingTests")
struct KeysetPagingTests {
    @Test("Test Keyset Paging and window navigation")
    func testKeysetPaging() throws {
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

        // First window (100 rows)
        let page1 = try doc.rows(window: Window(table: "sensor_readings", limit: 100))
        #expect(page1.rows.count == 100)
        #expect(page1.rowIDs.first == 1)
        #expect(page1.rowIDs.last == 100)
        #expect(page1.path == "interpolated")

        // Next window via keyset seek (after: 100)
        let page2 = try doc.rows(window: Window(table: "sensor_readings", limit: 100, after: 100, useAfter: true, offset: 100))
        #expect(page2.rows.count == 100)
        #expect(page2.rowIDs.first == 101)
        #expect(page2.rowIDs.last == 200)
        #expect(page2.path == "keyset")

        // Jump to offset 500
        let page3 = try doc.rows(window: Window(table: "sensor_readings", limit: 50, offset: 500))
        #expect(page3.rows.count == 50)
        #expect(page3.rowIDs.first == 501)
        #expect(page3.path == "interpolated")

        // Sort by temp DESC
        let page4 = try doc.rows(window: Window(table: "sensor_readings", limit: 20, sort: "temp", desc: true))
        #expect(page4.rows.count == 20)
        #expect(page4.path == "sorted-offset")
    }
}
