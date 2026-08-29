import XCTest
import Foundation
@testable import SQLDocCore

final class SQLiteConnectionTests: XCTestCase {
    func testReadOnlyConnectionAndPragmas() throws {
        let tempDir = NSTemporaryDirectory()
        let tempDBPath = (tempDir as NSString).appendingPathComponent("test_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        // Create a test database
        let conn = try SQLiteConnection(path: tempDBPath, readOnly: false)
        try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, age INTEGER, bio BLOB)")
        try conn.exec("INSERT INTO users (name, age, bio) VALUES ('Alice', 30, X'DEADBEEF')")
        try conn.exec("INSERT INTO users (name, age, bio) VALUES ('Bob', 25, NULL)")
        conn.close()

        let readConn = try SQLiteConnection(path: tempDBPath)
        defer { readConn.close() }

        let rows = try readConn.query("SELECT id, name, age, bio FROM users ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][1], .text("Alice"))
        XCTAssertEqual(rows[0][2], .integer(30))
        XCTAssertEqual(rows[0][3], .blob(bytes: 4))
        XCTAssertEqual(rows[1][1], .text("Bob"))
        XCTAssertEqual(rows[1][2], .integer(25))
        XCTAssertEqual(rows[1][3], .null)
    }
}
