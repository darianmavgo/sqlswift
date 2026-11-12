import Testing
import Foundation
import Combine
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
        var editing: Bool?
        var pendingEdits: Int?
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
        check(s["editing"] as? Bool, e.editing, "edit mode")
        check(s["pendingEdits"] as? Int, e.pendingEdits, "pending edits")
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

    /// Commit path end to end, on a private copy (the shared fixture must stay unwritten).
    @Test func commitWritesAndReloads() async throws {
        let path = try makeFixtureDB()
        let appVM = AppViewModel()
        var lastSelection = ""
        func lifecycle() {
            let now = "\(appVM.activeDocEntry?.id ?? "-"):\(appVM.selectedTableName)"
            if now != lastSelection { lastSelection = now; appVM.syncActiveTableVM() }
        }
        for step in ["url \(path)/telemetry[0:100]", "edit on", "set 0 temperature 77.5", "set 1 device_id 42"] {
            UICommandRunner.execute(step, appVM: appVM)
            await settle(appVM, lifecycle: lifecycle)
        }
        #expect(appVM.edit.pendingCount == 2)
        let urlBefore = appVM.banquetURLString(for: appVM.activeTableVM)
        UICommandRunner.execute("commit", appVM: appVM)
        await settle(appVM, lifecycle: lifecycle)
        #expect(appVM.edit.pendingCount == 0)
        #expect(appVM.errorMessage == nil, "\(appVM.errorMessage ?? "")")
        #expect(appVM.banquetURLString(for: appVM.activeTableVM) == urlBefore, "commit must not change the URL")
        // The grid re-read the committed values.
        let page = appVM.activeTableVM?.currentPage
        #expect(page?.rows[0][3] == .real(77.5))
        #expect(page?.rows[1][1] == .integer(42))
        // And they are really in the file.
        let check = try SQLiteConnection(path: path)
        #expect(try check.queryRow("SELECT temperature FROM telemetry WHERE id=1")?.first == .real(77.5))
        check.close()
        // Our own write is not an "external change".
        #expect(appVM.activeTableVM?.fileChangedOnDisk == false)
        appVM.edit.exit()
    }

    /// Row operations (docs/HighRepEdit.md): new, delete and duplicate stage in the buffer,
    /// leave the Banquet URL untouched, and commit together.
    @Test func rowOpsStageCommitAndKeepURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqldoc-ui-rowops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("items.db").path
        let conn = try SQLiteConnection(path: path, readOnly: false)
        try conn.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER)")
        try conn.exec("INSERT INTO items VALUES (1,'a',1),(2,'b',2),(3,'c',3)")
        conn.close()

        let (appVM, lifecycle) = await open("\(path)/items[0:100]")
        func run(_ step: String) async {
            UICommandRunner.execute(step, appVM: appVM)
            await settle(appVM, lifecycle: lifecycle)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let urlPlain = appVM.banquetURLString(for: appVM.activeTableVM)
        await run("edit on")
        #expect(appVM.banquetURLString(for: appVM.activeTableVM) == urlPlain, "edit mode must not change the URL")

        await run("newrow name nn qty 5")
        await run("deleterow 0")
        await run("duplicaterow 1")
        let snap = appVM.uiStateSnapshot()
        #expect(snap["pendingInserts"] as? Int == 2)
        #expect(snap["pendingDeletes"] as? Int == 1)
        #expect(appVM.banquetURLString(for: appVM.activeTableVM) == urlPlain, "row ops must not change the URL")
        #expect(appVM.edit.sqlPreview.count == 3)

        // Navigating while dirty keeps the pending rows (rule 11).
        await run("sort name desc")
        #expect(appVM.edit.pendingCount == 3)
        await run("sort - ")

        // One undo step per op; undo the duplicate and redo it.
        appVM.edit.undo(); #expect(appVM.edit.insertCount == 1)
        appVM.edit.redo(); #expect(appVM.edit.insertCount == 2)

        await run("commit")
        #expect(appVM.errorMessage == nil, "\(appVM.errorMessage ?? "")")
        #expect(appVM.edit.pendingCount == 0)
        let check = try SQLiteConnection(path: path)
        #expect(try check.queryRow("SELECT count(*) FROM items")?.first == .integer(4))
        #expect(try check.queryRow("SELECT count(*) FROM items WHERE name='a'")?.first == .integer(0))
        #expect(try check.queryRow("SELECT count(*) FROM items WHERE name='b'")?.first == .integer(2))
        #expect(try check.queryRow("SELECT qty FROM items WHERE name='nn'")?.first == .integer(5))
        check.close()
        #expect(appVM.activeTableVM?.fileChangedOnDisk == false)
        appVM.edit.exit()
    }

    /// The folder catalog sorts by any column, in either direction, and the Banquet bar and the
    /// list's sort state are one thing: a clause in the bar sets the sort, a header click sets the clause.
    @Test func folderCatalogSortsAndTracksTheBar() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqldoc-ui-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ name: String, tables: Int, rows: Int) throws {
            let c = try SQLiteConnection(path: dir.appendingPathComponent(name).path, readOnly: false)
            for t in 0..<tables {
                try c.exec("CREATE TABLE t\(t) (id INTEGER PRIMARY KEY, v TEXT)")
                for r in 0..<rows { try c.exec("INSERT INTO t\(t)(v) VALUES (printf('%.*c', 200, 'x\(r)'))") }
            }
            c.close()
        }
        try make("small.db", tables: 5, rows: 1)
        try make("big.db", tables: 1, rows: 400)
        try make("mid.db", tables: 3, rows: 20)

        let appVM = AppViewModel()
        // AppViewModel restores the dev app's saved session asynchronously; let that land first,
        // or it would overwrite the folder this test opens.
        for _ in 0..<500 where appVM.inFlightOpens > 0 || appVM.isScanningFolder { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        func names() -> [String] { appVM.folderSort.sorted(appVM.folderFiles).map(\.name) }
        func go(_ step: String) async {
            UICommandRunner.execute(step, appVM: appVM)
            for _ in 0..<300 where appVM.isScanningFolder { try? await Task.sleep(nanoseconds: 10_000_000) }
            // The dev app's saved session may restore another folder first: wait for this one's files.
            for _ in 0..<500 where !appVM.folderFiles.contains(where: { $0.path.hasPrefix(dir.path) && $0.name == "small.db" }) || appVM.inFlightOpens > 0 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        func sortField() -> String { (appVM.uiStateSnapshot()["folder"] as? [String: Any])?["sort"] as? String ?? "?" }

        await go("url \(dir.path)/-table_count")
        #expect(sortField() == "-table_count")
        #expect(names() == ["small.db", "mid.db", "big.db"])
        #expect(appVM.banquetURLString(for: nil).hasSuffix("/-table_count"))

        await go("url \(dir.path)/+table_count")        // direction is honoured, not guessed
        #expect(names() == ["big.db", "mid.db", "small.db"])

        await go("url \(dir.path)/-size_bytes")
        #expect(names() == ["big.db", "mid.db", "small.db"])
        await go("url \(dir.path)/+size_bytes")
        #expect(names() == ["small.db", "mid.db", "big.db"])

        // A header click is the same state as the bar clause, and the URL follows it.
        appVM.folderSort = appVM.folderSort.toggled(to: .name)
        #expect(appVM.banquetURLString(for: nil).hasSuffix("/+name"))
        appVM.folderSort = appVM.folderSort.toggled(to: .name)
        #expect(appVM.banquetURLString(for: nil).hasSuffix("/-name"))
        // ...and the URL the bar shows is a fixed point.
        let shown = appVM.banquetURLString(for: nil)
        await go("url \(shown)")
        #expect(appVM.banquetURLString(for: nil) == shown)
        #expect(names() == ["small.db", "mid.db", "big.db"])
    }

    // MARK: - Big-data behaviour (docs/GUIStability.md)

    private func open(_ url: String) async -> (AppViewModel, () -> Void) {
        let appVM = AppViewModel()
        var lastSelection = ""
        let lifecycle = {
            let now = "\(appVM.activeDocEntry?.id ?? "-"):\(appVM.selectedTableName)"
            if now != lastSelection { lastSelection = now; appVM.syncActiveTableVM() }
        }
        UICommandRunner.execute("url \(url)", appVM: appVM)
        await settle(appVM, lifecycle: lifecycle)
        return (appVM, lifecycle)
    }

    /// The pager moves by rewriting the URL slice. A step to a neighbouring page
    /// must still seek from the rows on screen, filtered and sorted included, and
    /// must show exactly the rows a counted offset would.
    @Test func pagerStepsSeekInsteadOfCountingOffsets() async throws {
        // A private copy: view state is remembered per database, and the shared
        // fixture's cases run in parallel with this.
        let fixtureDBPath = try makeFixtureDB()
        let (appVM, lifecycle) = await open("\(fixtureDBPath)/telemetry[0:100]")
        func run(_ step: String) async {
            UICommandRunner.execute(step, appVM: appVM)
            await settle(appVM, lifecycle: lifecycle)
        }
        let truthDoc = try Doc.open(path: fixtureDBPath)
        defer { truthDoc.close() }
        func check(_ what: String, path: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let vm = try #require(appVM.activeTableVM)
            let page = try #require(vm.currentPage)
            #expect(vm.lastQueryPath == path, "\(what): took \(vm.lastQueryPath)", sourceLocation: sourceLocation)
            // Ground truth by counted offset, straight from the engine.
            let ids = try truthDoc.fg.query(
                "SELECT id FROM telemetry"
                    + (vm.filters.isEmpty ? "" : " WHERE device_id = 2")
                    + " ORDER BY " + (vm.sortColumn.map { "\($0) \(vm.isSortDesc ? "DESC" : "ASC"), " } ?? "") + "id"
                    + " LIMIT \(vm.pageLimit) OFFSET \(vm.currentOffset)"
            ).compactMap { $0.first?.intValue }
            #expect(page.rowIDs == ids, "\(what): wrong rows at offset \(vm.currentOffset)", sourceLocation: sourceLocation)
            #expect(page.start == vm.currentOffset, sourceLocation: sourceLocation)
        }

        await run("page next"); try check("plain next", path: "keyset")
        await run("page next"); try check("plain next 2", path: "keyset")
        await run("page prev"); try check("plain prev", path: "keyset")

        await run("filter device_id equals 2")
        await run("page next"); try check("filtered next", path: "filtered-keyset")
        await run("page next"); try check("filtered next 2", path: "filtered-keyset")
        await run("page prev"); try check("filtered prev", path: "filtered-keyset")
        await run("page prev"); try check("filtered back to first", path: "filtered")
        await run("page last"); try check("filtered last", path: "filtered-keyset")
        #expect(appVM.activeTableVM?.currentOffset == 1900)
        await run("page prev"); try check("filtered prev from last", path: "filtered-keyset")

        await run("sort temperature desc")
        try check("filtered sorted first", path: "filtered")
        await run("page next"); try check("filtered sorted next", path: "filtered-keyset")
        await run("page next"); try check("filtered sorted next 2", path: "filtered-keyset")
        await run("page prev"); try check("filtered sorted prev", path: "filtered-keyset")
        await run("page last"); try check("filtered sorted last", path: "filtered-keyset")

        await run("clearfilters")
        await run("page next"); try check("sorted next", path: "sorted-keyset")
        await run("page prev"); try check("sorted prev back to first", path: "sorted-offset")
        // A jump has no neighbour to seek from; it still lands on the right rows.
        appVM.executeBanquetSlice(offset: 5000, limit: 100, tableVM: try #require(appVM.activeTableVM))
        await settle(appVM, lifecycle: lifecycle)
        try check("sorted jump", path: "sorted-offset")
        await run("page next"); try check("sorted next after jump", path: "sorted-keyset")
    }

    /// Loads requested in a burst: the earlier ones are cancelled, and only the
    /// newest page is ever shown.
    @Test func supersededLoadsNeverLand() async throws {
        let fixtureDBPath = try makeFixtureDB()
        let (appVM, lifecycle) = await open("\(fixtureDBPath)/telemetry[0:100]")
        let vm = try #require(appVM.activeTableVM)
        var landed: [Int64] = []
        let watch = vm.$currentPage.sink { if let p = $0 { landed.append(p.start) } }
        defer { watch.cancel() }
        landed.removeAll()
        for off in [1000, 2000, 3000, 4000, 5000] as [Int64] { vm.loadPage(offset: off) }
        await settle(appVM, lifecycle: lifecycle)
        #expect(vm.currentPage?.start == 5000)
        #expect(landed == [5000], "pages that landed: \(landed)")
        #expect(vm.isLoading == false && vm.loadIsSlow == false)
        // Cancelling when nothing is loading is a no-op and leaves the page alone.
        vm.cancelLoad()
        #expect(vm.currentPage?.start == 5000 && vm.queryError == nil)
    }

    /// A wide table opens in Trim by itself. That is the app's choice of how to draw
    /// the rows, so it must not write itself into the URL, on open or on a page turn.
    @Test func trimNeverEntersTheURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqldoc-ui-wide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("wide.db").path
        let conn = try SQLiteConnection(path: path, readOnly: false)
        let cols = (1...20).map { "c\($0) INTEGER" }.joined(separator: ", ")
        try conn.exec("CREATE TABLE wide (id INTEGER PRIMARY KEY, \(cols))")
        try conn.exec("BEGIN")
        for i in 1...300 {
            try conn.exec("INSERT INTO wide VALUES (\(i), \((1...20).map { "\(i * $0)" }.joined(separator: ", ")))")
        }
        try conn.exec("COMMIT")
        conn.close()

        let (appVM, lifecycle) = await open("\(path)/wide")
        let vm = try #require(appVM.activeTableVM)
        #expect(vm.displayKind == .trim, "a 21-column table should open in Trim")
        #expect(appVM.banquetURLString(for: vm) == "\(path)/wide")

        for step in ["size 100", "page next", "sort c3 desc"] {
            UICommandRunner.execute(step, appVM: appVM)
            await settle(appVM, lifecycle: lifecycle)
            #expect(vm.displayKind == .trim, "\(step) must not leave Trim")
            #expect(!appVM.banquetURLString(for: vm).contains("display"), "after \(step): \(appVM.banquetURLString(for: vm))")
        }

        // Summary is a different result set, so it is the one display kind the URL names.
        UICommandRunner.execute("display summary", appVM: appVM)
        await settle(appVM, lifecycle: lifecycle)
        #expect(appVM.banquetURLString(for: vm).hasSuffix("?display=summary"))
    }

    /// A cell too big for the page arrives clipped; inspecting, copying and
    /// editing it all work on the stored value.
    @Test func clippedCellResolvesForEditing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqldoc-ui-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("big.db").path
        let conn = try SQLiteConnection(path: path, readOnly: false)
        try conn.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT, body TEXT)")
        try conn.exec("INSERT INTO notes VALUES (1, 'long', printf('%.*c', 50000, 'w')), (2, 'short', 'hi')")
        conn.close()

        let (appVM, lifecycle) = await open("\(path)/notes[0:100]")
        func run(_ step: String) async {
            UICommandRunner.execute(step, appVM: appVM)
            await settle(appVM, lifecycle: lifecycle)
            try? await Task.sleep(nanoseconds: 150_000_000)   // let a deferred stage finish
        }
        let vm = try #require(appVM.activeTableVM)
        let body = try #require(vm.currentPage?.columns.firstIndex { $0.name == "body" })
        guard case .textPrefix(let head, let total)? = vm.currentPage?.rows[0][body] else {
            Issue.record("the 50,000-byte cell should arrive clipped"); return
        }
        #expect(total == 50_000 && head.utf8.count == BehaviorConfig.textCellFetchMaxBytes)
        #expect(vm.currentPage?.rows[1][body] == .text("hi"))

        // Resolving swaps the stored value into the page.
        #expect(await vm.resolveFullValues(row: 0, cols: [body]))
        if case .text(let whole)? = vm.currentPage?.rows[0][body] { #expect(whole.utf8.count == 50_000) }
        else { Issue.record("cell should be whole after resolving") }

        // Edit a clipped cell on a fresh page: staging fetches the original, so the commit matches.
        vm.loadPage(offset: 0)
        await settle(appVM, lifecycle: lifecycle)
        #expect(vm.currentPage?.rows[0][body].isPartial == true)
        await run("edit on")
        await run("set 0 body replaced")
        #expect(appVM.edit.pendingCount == 1)
        await run("commit")
        #expect(appVM.errorMessage == nil, "\(appVM.errorMessage ?? "")")
        #expect(appVM.edit.pendingCount == 0)
        let check = try SQLiteConnection(path: path)
        #expect(try check.queryRow("SELECT body FROM notes WHERE id = 1")?.first == .text("replaced"))
        check.close()
        appVM.edit.exit()
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
