import XCTest
import Foundation
@testable import SQLDocCore

final class CounterTests: XCTestCase {
    func testO1EstimateAndBackgroundExactCount() async throws {
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
        try conn.exec("ANALYZE") // Populates sqlite_stat1
        conn.close()

        let doc = try Doc.open(path: tempDBPath)
        defer { doc.close() }

        // O(1) estimate is instant
        let est = doc.estimateRows(for: "items")
        XCTAssertTrue(est.known)
        XCTAssertEqual(est.rows, 500)

        // Count triggers background exact count
        _ = doc.count(for: "items")

        // Wait for exact count to land
        var settled = false
        for _ in 0..<100 {
            let current = doc.count(for: "items")
            if current.exact {
                XCTAssertEqual(current.rows, 500)
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(settled)
    }
}
