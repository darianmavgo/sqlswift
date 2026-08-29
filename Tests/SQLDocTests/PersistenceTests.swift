import Testing
import Foundation
import CoreGraphics
@testable import SQLDocCore

@Suite("PersistenceTests")
struct PersistenceTests {
    @Test("Test StatePersistenceManager saves and restores column widths")
    func testColumnWidthPersistence() {
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
        #expect(loaded != nil)
        #expect(loaded?["id"] == 80.0)
        #expect(loaded?["name"] == 180.0)
        #expect(loaded?["email"] == 240.0)

        manager.clearColumnWidths(dbID: testDB, table: testTable)
        let cleared = manager.loadColumnWidths(dbID: testDB, table: testTable)
        #expect(cleared == nil)
    }

    @Test("Test Theme persistence")
    func testSettingsPersistence() {
        let manager = StatePersistenceManager.shared

        manager.themeMode = .dark
        #expect(manager.themeMode == .dark)

        manager.themeMode = .light
        #expect(manager.themeMode == .light)
    }
}
