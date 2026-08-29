import XCTest
import Foundation
@testable import SQLDocCore

final class StyleNavTests: XCTestCase {
    func testStyleAndNavOverrides() throws {
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

        // Verify _style
        XCTAssertEqual(doc.style.title, "Sensor Dashboard")
        XCTAssertEqual(doc.style.accent, "#10b981")
        XCTAssertEqual(doc.style.theme, "dark")

        // Verify _nav and tables
        let visible = doc.tables.filter { !$0.hidden }
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].name, "readings")
        XCTAssertEqual(visible[0].label, "Live Sensor Readings")

        // Internal metadata tables starting with _ are hidden
        let styleTable = doc.tables.first { $0.name == "_style" }
        XCTAssertNotNil(styleTable)
        XCTAssertEqual(styleTable?.hidden, true)
    }
}
