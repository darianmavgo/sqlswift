// ConformanceGen — tools over the Banquet conformance ledger
// (docs/conformance/conformance.db, built from config/conformance.sql).
//
//   swift run ConformanceGen check       ledger integrity; non-zero exit on failure
//   swift run ConformanceGen scorecard   per-standard totals
//
// Invoked by `make conformance-check`. Run from the repo root. Like ConfigGen this is a
// dev-time tool: it is not linked into the app and depends on nothing but libsqlite3.

import Foundation
import SQLite3

let dbPath = "docs/conformance/conformance.db"
let casesPath = "Tests/SQLDocAppTests/banquet-ui-cases.json"
let runnerPath = "Tests/SQLDocTestsRunner/main.swift"
let uiCommandsPath = "Sources/SQLDocApp/Utilities/UICommands.swift"

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("ConformanceGen: \(m)\n".utf8)); exit(2)
}

func read(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return s
}

// MARK: - tiny sqlite reader

final class DB {
    private var handle: OpaquePointer?
    init(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { fail("\(path) missing — run: make conformance-db") }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            fail("cannot open \(path): \(String(cString: sqlite3_errmsg(handle)))")
        }
    }
    deinit { sqlite3_close(handle) }

    /// Rows as [column: value]; a NULL column is absent from the dictionary.
    func rows(_ sql: String, _ args: [String] = []) -> [[String: String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            fail("bad query: \(sql)\n\(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient) }
        var out: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                if let c = sqlite3_column_text(stmt, i) {
                    row[String(cString: sqlite3_column_name(stmt, i))] = String(cString: c)
                }
            }
            out.append(row)
        }
        return out
    }
}

// MARK: - sources the ledger points into

/// Names of the cases in banquet-ui-cases.json.
func uiCaseNames() -> Set<String> {
    guard let data = FileManager.default.contents(atPath: casesPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]] else { fail("cannot parse \(casesPath)") }
    return Set(cases.compactMap { $0["name"] as? String })
}

/// Verbs the dev app accepts: every string literal on a `case "x", "y":` line of UICommands.swift.
func uiVerbs() -> Set<String> {
    var verbs = Set<String>()
    for line in read(uiCommandsPath).split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("case \""), t.hasSuffix(":") else { continue }
        for (i, part) in t.split(separator: "\"").enumerated() where i % 2 == 1 { verbs.insert(String(part)) }
    }
    return verbs
}

/// Numbers of the rules a standard prints (`3. ` list items or `### 3. ` headings), stopping at
/// the screenshots / bindings appendix.
func ruleNumbers(inStandard path: String) -> [Int] {
    var nums: [Int] = []
    for line in read(path).split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("## sqlswift reference screenshots") || line.hasPrefix("## sqlswift bindings")
            || line.hasPrefix("## Screenshots") { break }
        let body = line.hasPrefix("### ") ? line.dropFirst(4) : line[...]
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". "), let n = Int(digits) { nums.append(n) }
    }
    return nums
}

func gitHead(_ repo: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo, "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return p.terminationStatus == 0 && !s.isEmpty ? s : nil
}

// MARK: - commands

func check(_ db: DB) -> Int32 {
    var errors: [String] = [], warnings: [String] = []
    let cases = uiCaseNames(), runner = read(runnerPath), verbs = uiVerbs()

    for p in db.rows("SELECT rule_id, kind, ref FROM proofs") {
        let rule = p["rule_id"]!, ref = p["ref"]!
        if p["kind"] == "ui-case", !cases.contains(ref) { errors.append("\(rule): no UI case named \"\(ref)\"") }
        if p["kind"] == "runner", !runner.contains("test(\"\(ref)\"") { errors.append("\(rule): no runner test titled \"\(ref)\"") }
    }
    for r in db.rows("""
        SELECT id FROM rules r WHERE status = 'conforms'
        AND NOT EXISTS (SELECT 1 FROM proofs p WHERE p.rule_id = r.id)
        """) {
        errors.append("\(r["id"]!): marked conforms but has no proof row at all")
    }
    for r in db.rows("SELECT id, status FROM rules WHERE status IN ('differs','missing') AND note IS NULL") {
        errors.append("\(r["id"]!): status \(r["status"]!) needs a note saying how")
    }
    for s in db.rows("SELECT id, steps FROM shots") {
        for step in s["steps"]!.split(separator: "\n") {
            let verb = String(step.split(separator: " ").first ?? "")
            if !verbs.contains(verb) { errors.append("shot \(s["id"]!): unknown UI command \"\(verb)\"") }
        }
    }

    // Drift against the standards themselves. banquet/ is a separate checkout and may be absent.
    for s in db.rows("SELECT id, file, banquet_rev FROM standards") {
        let id = s["id"]!, file = s["file"]!
        guard FileManager.default.fileExists(atPath: file) else {
            warnings.append("\(id): \(file) not present, rule numbers not compared"); continue
        }
        let want = ruleNumbers(inStandard: file).sorted()
        let have = db.rows("SELECT num FROM rules WHERE standard = ? AND num IS NOT NULL", [id])
            .compactMap { Int($0["num"]!) }.sorted()
        if want != have { warnings.append("\(id): standard numbers rules \(want), ledger has \(have)") }
        if let rev = s["banquet_rev"], let head = gitHead(String(file.split(separator: "/")[0])), head != rev {
            warnings.append("\(id): audited at banquet \(rev), checkout is at \(head)")
        }
    }

    warnings.forEach { print("warn  \($0)") }
    errors.forEach { print("FAIL  \($0)") }
    let n = db.rows("SELECT count(*) AS n FROM rules")[0]["n"]!
    print("\(n) rules, \(errors.count) errors, \(warnings.count) warnings")
    return errors.isEmpty ? 0 : 1
}

func scorecard(_ db: DB) -> Int32 {
    let cols = ["standard", "rules", "conforms", "differs", "missing", "unproven", "unconfirmed"]
    func line(_ cells: [String]) -> String {
        cells.enumerated().map { i, c in
            let pad = String(repeating: " ", count: max(0, 11 - c.count))
            return i == 0 ? c + pad : pad + c
        }.joined(separator: "  ")
    }
    let rows = db.rows("SELECT * FROM scorecard")
    print(line(cols))
    for r in rows { print(line(cols.map { r[$0] ?? "0" })) }
    print(line(["total"] + cols.dropFirst().map { c in String(rows.reduce(0) { $0 + (Int($1[c] ?? "0") ?? 0) }) }))
    return 0
}

// MARK: - shoot: replay each shot's recipe in the running dev app and keep the window PNG

let outDir = "docs/conformance"
let commandFile = "bin/ui-command.txt"
let stateFile = "bin/ui-state.json"
/// Per-table view state survives between recipes; same neutral reset as scripts/ui-e2e.py.
let resetCommands = ["revert", "edit off", "blur", "navreset", "allrowscap 0", "showall", "clearfilters", "sort -", "display raw"]

func send(_ line: String) {
    do { try (line + "\n").write(toFile: commandFile, atomically: true, encoding: .utf8) }
    catch { fail("cannot write \(commandFile): \(error.localizedDescription)") }
    let deadline = Date().addingTimeInterval(5)
    while FileManager.default.fileExists(atPath: commandFile) {
        if Date() > deadline { fail("dev app is not consuming \(commandFile) — is the app from `make hot` open?") }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

/// Waits for the state snapshot to stop changing and the grid to finish loading.
func settle() {
    Thread.sleep(forTimeInterval: 0.8)
    var previous: Data?, stable = 0
    for _ in 0..<40 {
        let data = FileManager.default.contents(atPath: stateFile)
        let state = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let loading = ((state?["grid"] as? [String: Any])?["isLoading"] as? Bool) ?? false
        if data == previous, !loading { stable += 1; if stable >= 2 { return } } else { stable = 0 }
        previous = data
        Thread.sleep(forTimeInterval: 0.3)
    }
}

func shoot(_ db: DB, only: String?) -> Int32 {
    // The bar shows absolute paths, so shoot from a short neutral folder: published screenshots
    // should not carry whoever ran this's home directory.
    let demoDir = "/tmp/sqldoc-demo", sample = demoDir + "/sample.db"
    let fm = FileManager.default
    guard fm.fileExists(atPath: "testdata/sample.db") else { fail("testdata/sample.db missing — run: sh scripts/make_testdata.sh") }
    // Copy only what is missing: replacing a file the dev app has open gives it disk I/O errors.
    try? fm.createDirectory(atPath: demoDir, withIntermediateDirectories: true)
    for name in ["sample.db", "benchmark.db"]
    where fm.fileExists(atPath: "testdata/\(name)") && !fm.fileExists(atPath: "\(demoDir)/\(name)") {
        try? fm.copyItem(atPath: "testdata/\(name)", toPath: "\(demoDir)/\(name)")
    }
    try? fm.createDirectory(atPath: outDir + "/img", withIntermediateDirectories: true)

    var failed = 0
    for s in db.rows("SELECT id, steps FROM shots ORDER BY rowid") where only == nil || s["id"]!.contains(only!) {
        let id = s["id"]!, png = "bin/\(id).png", dest = "\(outDir)/img/\(id).png"
        resetCommands.forEach(send)
        for step in s["steps"]!.split(separator: "\n") {
            send(step.replacingOccurrences(of: "{DBDIR}", with: demoDir)
                     .replacingOccurrences(of: "{DB}", with: sample))
            settle()
        }
        try? FileManager.default.removeItem(atPath: png)
        send("snapshot \(id)")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: png), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard FileManager.default.fileExists(atPath: png) else { print("✘ \(id): no snapshot (see [snapshot] in bin/ui.log)"); failed += 1; continue }
        try? FileManager.default.removeItem(atPath: dest)
        // Retina captures are ~1 MB each; 1600 px wide is plenty for a page.
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["--resampleWidth", "1600", png, "--out", dest]
        sips.standardOutput = FileHandle.nullDevice
        sips.standardError = FileHandle.nullDevice
        try? sips.run(); sips.waitUntilExit()
        if !FileManager.default.fileExists(atPath: dest) { try? FileManager.default.copyItem(atPath: png, toPath: dest) }
        print("✔ \(id)")
    }
    resetCommands.forEach(send)
    return failed == 0 ? 0 : 1
}

// MARK: - guide: the training page

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

let pageStyle = """
:root{--bg:#faf8f5;--card:#fff;--ink:#1f1d1a;--muted:#6b665e;--line:#e4dfd6;--accent:#d9622b;--code:#f1ede6;--warn:#8a5a00;--warnbg:#fff4d6}
@media (prefers-color-scheme:dark){:root{--bg:#171614;--card:#201f1c;--ink:#ece8e1;--muted:#a09a90;--line:#33302b;--accent:#f08a54;--code:#2a2824;--warn:#f0c674;--warnbg:#3a3018}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:920px;margin:0 auto;padding:40px 16px 80px}
h1{font-size:2.1rem;line-height:1.15;margin:0 0 8px}
.lede{color:var(--muted);font-size:1.1rem;margin:0 0 20px;max-width:60ch}
nav{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 36px}
nav a{color:var(--ink);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:4px 12px;font-size:.9rem}
nav a:hover{border-color:var(--accent);color:var(--accent)}
h2{font-size:1.35rem;margin:48px 0 4px;padding-top:8px}
.sub{color:var(--muted);margin:0 0 16px;font-size:.95rem}
.step{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:18px 18px 16px;margin:0 0 16px}
.step h3{font-size:1.05rem;margin:0 0 8px}
.step p{margin:6px 0}
.url{display:flex;align-items:center;gap:8px;margin:10px 0}
.url code{flex:1;min-width:0;overflow-x:auto;white-space:nowrap;background:var(--code);border-radius:6px;padding:7px 10px;font:14px ui-monospace,SFMono-Regular,Menlo,monospace}
.url button{flex:none;border:1px solid var(--line);background:none;color:var(--muted);border-radius:6px;padding:6px 10px;font:inherit;font-size:.85rem;cursor:pointer}
.url button:hover{color:var(--accent);border-color:var(--accent)}
figure{margin:12px 0 0}
figure img{display:block;width:100%;height:auto;border:1px solid var(--line);border-radius:8px}
figcaption{color:var(--muted);font-size:.9rem;margin-top:6px}
.rule{color:var(--muted);font-size:.85rem}
.note{background:var(--warnbg);color:var(--warn);border-radius:6px;padding:6px 10px;font-size:.9rem}
footer{color:var(--muted);font-size:.85rem;margin-top:48px;border-top:1px solid var(--line);padding-top:16px}
"""

func guide(_ db: DB) -> Int32 {
    // Training order, not the ledger's audit order: address first, then what you see, then editing.
    let order = ["url", "bar", "grid", "query", "tablelist", "dblist", "edit"]
    let blurbs = [
        "url": "A Banquet URL is a file path that keeps going: file, table, columns, rows.",
        "bar": "The bar at the top is the only control you need. Whatever you see has a URL.",
        "grid": "How values are drawn once you have a result.",
        "query": "Which columns you see first, and which are tucked away.",
        "tablelist": "A whole database on one page.",
        "dblist": "A folder of databases is browsable too.",
        "edit": "Files open read-only. Editing is a mode you switch on.",
    ]
    let titles = Dictionary(uniqueKeysWithValues: db.rows("SELECT id, title FROM standards").map { ($0["id"]!, $0["title"]!) })

    var body = "", toc = ""
    for std in order {
        // A rule earns a place in the guide when there is something to do (how_to) or to see (a shot).
        let rules = db.rows("""
            SELECT r.id, r.title, r.text, r.status, r.note, r.how_to, r.demo_url
            FROM rules r WHERE r.standard = ? AND r.status <> 'missing'
              AND (r.how_to IS NOT NULL OR EXISTS (SELECT 1 FROM shots s WHERE s.rule_id = r.id))
            ORDER BY r.rowid
            """, [std])
        if rules.isEmpty { continue }
        toc += "<a href=\"#\(std)\">\(esc(titles[std] ?? std))</a>"
        body += "<h2 id=\"\(std)\">\(esc(titles[std] ?? std))</h2>\n<p class=\"sub\">\(esc(blurbs[std] ?? ""))</p>\n"
        for r in rules {
            body += "<section class=\"step\" id=\"\(r["id"]!)\">\n<h3>\(esc(r["how_to"] ?? r["title"]!))</h3>\n"
            body += "<p class=\"rule\">\(esc(r["id"]!)) · \(esc(r["text"]!))</p>\n"
            if let url = r["demo_url"] {
                body += "<div class=\"url\"><code>\(esc(url))</code><button type=\"button\" data-copy=\"\(esc(url))\">Copy</button></div>\n"
            }
            if r["status"] == "differs", let note = r["note"] {
                body += "<p class=\"note\">Differs from the standard: \(esc(note))</p>\n"
            }
            for s in db.rows("SELECT id, caption FROM shots WHERE rule_id = ? ORDER BY rowid", [r["id"]!])
            where FileManager.default.fileExists(atPath: "\(outDir)/img/\(s["id"]!).png") {
                body += "<figure><img src=\"img/\(s["id"]!).png\" alt=\"\(esc(s["caption"]!))\" loading=\"lazy\"><figcaption>\(esc(s["caption"]!))</figcaption></figure>\n"
            }
            body += "</section>\n"
        }
    }

    let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>sqldoc guide: Banquet in practice</title>
    <style>
    \(pageStyle)
    </style>
    </head>
    <body>
    <main>
    <h1>Banquet in practice</h1>
    <p class="lede">Everything sqldoc shows you has an address. Learn to read and write that address and you can reach any view of any SQLite file in one line.</p>
    <nav>\(toc)</nav>
    \(body)
    <footer>Generated from <code>config/conformance.sql</code> by <code>make conformance-guide</code>. URLs are relative to the sqlswift repo root; <code>testdata/sample.db</code> comes from <code>sh scripts/make_testdata.sh</code>.</footer>
    </main>
    <script>
    document.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-copy]');
      if (!b) return;
      navigator.clipboard.writeText(b.dataset.copy).then(function () {
        b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1200);
      });
    });
    </script>
    </body>
    </html>

    """
    let path = "\(outDir)/guide.html"
    do { try html.write(toFile: path, atomically: true, encoding: .utf8) }
    catch { fail("cannot write \(path): \(error.localizedDescription)") }
    print("wrote \(path)")
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "check":     exit(check(DB(dbPath)))
case "scorecard": exit(scorecard(DB(dbPath)))
case "shoot":     exit(shoot(DB(dbPath), only: args.dropFirst().first))
case "guide":     exit(guide(DB(dbPath)))
default:          fail("usage: ConformanceGen check | scorecard | shoot [id-substring] | guide")
}
