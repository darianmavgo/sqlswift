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
        /// Exact completions the dropdown offers, in order (after a `suggest` step or typing).
        var suggestions: [String]?
        var navBack: Bool?
        var navForward: Bool?
        var navCurrent: String?
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
        // Cases run in parallel: give each its own history store, not the shared one.
        let suite = "sqldoc.uitest.\(UUID().uuidString)"
        appVM.banquetHistory = BanquetHistory(storageKey: "history", defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        appVM.resetNavigation()
        // MainView calls syncActiveTableVM when the document or table changes; mirror that.
        var lastSelection = ""
        func lifecycle() {
            let now = "\(appVM.activeDocEntry?.id ?? "-"):\(appVM.selectedTableName)"
            if now != lastSelection { lastSelection = now; appVM.syncActiveTableVM() }
        }
        for step in c.steps {
            UICommandRunner.execute(step.replacingOccurrences(of: "{DB}", with: db), appVM: appVM)
            await settle(appVM, lifecycle: lifecycle)
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
        let nav = s["nav"] as? [String: Any] ?? [:]
        check((s["suggestions"] as? [String]).map { $0.map { $0.replacingOccurrences(of: db, with: "{DB}") } }, e.suggestions, "suggestions")
        check(nav["back"] as? Bool, e.navBack, "can go back")
        check(nav["forward"] as? Bool, e.navForward, "can go forward")
        check((nav["current"] as? String).map { $0.replacingOccurrences(of: db, with: "{DB}") }, e.navCurrent, "nav current")
        let queryError: String = appVM.activeTableVM?.queryError ?? ""
        #expect(queryError.isEmpty, "query error: \(queryError)")

        // The URL the bar shows must be a fixed point: feeding it back changes nothing.
        if let shown = s["banquetURL"] as? String {
            appVM.openBanquet(urlString: shown, activeTableVM: appVM.activeTableVM)
            await settle(appVM, lifecycle: lifecycle)
            #expect(appVM.uiStateSnapshot()["banquetURL"] as? String == shown, "bar URL is not stable when re-applied")
        }
    }

    /// Wait for background page loads to finish (and stay finished briefly).
    private func settle(_ appVM: AppViewModel, lifecycle: () -> Void) async {
        // Opens run on worker threads now: wait for them, then mirror MainView's lifecycle hook.
        var opens = 0
        lifecycle()
        while appVM.inFlightOpens > 0, opens < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            opens += 1
            lifecycle()
        }
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
