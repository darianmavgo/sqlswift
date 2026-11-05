import Testing
import Foundation
@testable import SQLDocApp
@testable import SQLDocCore

// Headless UI tests: drive the real AppViewModel/TableViewModel (the layer the
// SwiftUI views render) with Banquet URLs and grid actions, then check what the
// window would show via `uiStateSnapshot()`. Cases live in banquet-ui-cases.json
// and are shared with scripts/ui-e2e.py, which replays them in the live app.

struct UICase: Decodable, Sendable, CustomTestStringConvertible {
    struct Expect: Decodable, Sendable {
        var table: String?
        var url: String?
        var sort: String?
        var filters: Int?
        var offset: Int?
        var pageLimit: Int?
        var rowsLoaded: Int?
        var visibleColumns: [String]?
        var bar: String?
    }
    var name: String
    var steps: [String]
    var expect: Expect
    var ui: Bool?
    var testDescription: String { name }
}

private struct CaseFile: Decodable { var cases: [UICase] }

/// 10,000-row `telemetry` table matching testdata/sample.db's shape, so the same
/// corpus passes headless (here) and against the live app.
private func makeFixtureDB() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqldoc-ui-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("fixture.db").path
    let conn = try SQLiteConnection(path: path, readOnly: false)
    try conn.exec("""
        CREATE TABLE telemetry (
            id INTEGER PRIMARY KEY, device_id INTEGER NOT NULL, timestamp TEXT NOT NULL,
            temperature REAL NOT NULL, humidity REAL NOT NULL, pressure REAL NOT NULL, raw_payload BLOB)
        """)
    try conn.exec("BEGIN")
    for i in 1...10_000 {
        try conn.exec("INSERT INTO telemetry VALUES (\(i), \(i % 5 + 1), '2026-01-01T00:00:\(i % 60)', \(Double(i % 400) / 10), \(Double(i % 100)), 1000.5, NULL)")
    }
    try conn.exec("COMMIT")
    conn.close()
    return path
}

private let fixtureDBPath: String = { (try? makeFixtureDB()) ?? "" }()

/// Headless cases only; `ui: true` cases need the real SwiftUI field (ui-e2e.py).
private let headlessCases: [UICase] = {
    guard let url = Bundle.module.url(forResource: "banquet-ui-cases", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(CaseFile.self, from: data) else { return [] }
    return file.cases.filter { $0.ui != true }
}()

@MainActor
@Suite("Banquet URLs in the UI")
struct BanquetUITests {
    @Test func corpusLoaded() {
        #expect(!fixtureDBPath.isEmpty, "fixture db was not created")
        #expect(headlessCases.count >= 10, "case corpus missing or empty")
    }

    @Test(arguments: headlessCases)
    func caseMatchesWindowState(_ c: UICase) async throws {
        let db = fixtureDBPath
        let appVM = AppViewModel()
        // MainView calls syncActiveTableVM when the document or table changes; mirror that.
        var lastSelection = ""
        func lifecycle() {
            let now = "\(appVM.activeDocEntry?.id ?? "-"):\(appVM.selectedTableName)"
            if now != lastSelection { lastSelection = now; appVM.syncActiveTableVM() }
        }
        for step in c.steps {
            UICommandRunner.execute(step.replacingOccurrences(of: "{DB}", with: db), appVM: appVM)
            lifecycle()
            await settle(appVM)
        }
        let s = appVM.uiStateSnapshot()
        let g = s["grid"] as? [String: Any] ?? [:]
        let sub = { (x: String) in x.replacingOccurrences(of: "{DB}", with: db) }
        let e = c.expect

        func check<T: Equatable>(_ actual: T?, _ want: T?, _ what: String) {
            guard let want else { return }
            #expect(actual == want, "\(c.name) — \(what): got \(String(describing: actual)), want \(want)")
        }
        check(s["table"] as? String, e.table, "table")
        check(s["banquetURL"] as? String, e.url.map(sub), "bar URL")
        check(g["sort"] as? String, e.sort, "sort")
        check(g["filters"] as? Int, e.filters, "filter count")
        check((g["offset"] as? Int64).map(Int.init) ?? g["offset"] as? Int, e.offset, "offset")
        check(g["pageLimit"] as? Int, e.pageLimit, "page limit")
        check(g["rowsLoaded"] as? Int, e.rowsLoaded, "rows loaded")
        check(g["visibleColumns"] as? [String], e.visibleColumns, "visible columns")
        let queryError: String = appVM.activeTableVM?.queryError ?? ""
        #expect(queryError.isEmpty, "query error: \(queryError)")

        // The URL the bar shows must be a fixed point: feeding it back changes nothing.
        if let shown = s["banquetURL"] as? String {
            appVM.openBanquet(urlString: shown, activeTableVM: appVM.activeTableVM)
            lifecycle()
            await settle(appVM)
            #expect(appVM.uiStateSnapshot()["banquetURL"] as? String == shown, "bar URL is not stable when re-applied")
        }
    }

    /// Wait for background page loads to finish (and stay finished briefly).
    private func settle(_ appVM: AppViewModel) async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            var spins = 0
            while appVM.activeTableVM?.isLoading == true, spins < 250 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                spins += 1
            }
        }
    }
}
