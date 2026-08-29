import Testing
import Foundation
@testable import SQLDocCore

@Suite("StyleNavTests")
struct StyleNavTests {
    @Test("Test Style and Nav overrides")
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
        #expect(doc.style.title == "Sensor Dashboard")
        #expect(doc.style.accent == "#10b981")
        #expect(doc.style.theme == "dark")

        // Verify _nav and tables
        let visible = doc.tables.filter { !$0.hidden }
        #expect(visible.count == 1)
        #expect(visible[0].name == "readings")
        #expect(visible[0].label == "Live Sensor Readings")

        // Internal metadata tables starting with _ are hidden
        let styleTable = doc.tables.first { $0.name == "_style" }
        #expect(styleTable != nil)
        #expect(styleTable?.hidden == true)
    }
}
