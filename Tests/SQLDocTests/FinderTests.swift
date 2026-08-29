import XCTest
import Foundation
@testable import SQLDocCore

final class FinderTests: XCTestCase {
    func testStreamingFind() throws {
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

        // Find "INFO"
        let res1 = try doc.find(table: "logs", query: "INFO")
        XCTAssertEqual(res1.matches.count, 2)
        XCTAssertEqual(res1.matches[0].rowID, 1)
        XCTAssertEqual(res1.matches[1].rowID, 4)

        // Find wildcard text "95%"
        let res2 = try doc.find(table: "logs", query: "95%")
        XCTAssertEqual(res2.matches.count, 1)
        XCTAssertEqual(res2.matches[0].rowID, 2)
    }
}
