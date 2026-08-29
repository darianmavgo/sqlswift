import Testing
import Foundation
@testable import SQLDocCore

@Suite("CSVExporterTests")
struct CSVExporterTests {
    @Test("Test CSV Export of records")
    func testCSVExport() throws {
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

        #expect(lines.count == 3)
        #expect(lines[0] == "id,name,price")
        #expect(lines[1] == "1,\"Widget, Pro\",29.99")
        #expect(lines[2] == "2,\"Gadget \"\"Special\"\"\",49.5")
    }
}
