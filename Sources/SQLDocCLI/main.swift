import Foundation
import SQLDocCore

// Generated from the identity table in sqldoc.db (see AppIdentity.swift).
let version = AppIdentity.version

let usage = """
sqldoc — open a SQLite database as a document (Pure Swift & SwiftUI)

Usage:
  sqldoc                        open the start page (recent files, drag & drop)
  sqldoc <file.db> [more.db...] open one or more databases
  sqldoc info  <file.db>        print what the document contains
  sqldoc bench <file.db>        measure read latency and scroll throughput
  sqldoc export <file.db> <table> [output.csv]  export table to CSV

Flags:
  -immutable    promise the file will not change while open (skips locking & WAL)
  -app          launch desktop SwiftUI application
  -version      print version
"""

func runCLI() {
    let args = Array(CommandLine.arguments.dropFirst())

    var isImmutable = false
    var showVersion = false
    var launchApp = false
    var cleanArgs: [String] = []
    var subcmd = "open"

    for arg in args {
        switch arg {
        case "-immutable", "--immutable":
            isImmutable = true
        case "-v", "-version", "--version":
            showVersion = true
        case "-app", "--app":
            launchApp = true
        case "-h", "-help", "--help":
            print(usage)
            return
        case "--":
            continue
        case "info", "bench", "export", "open":
            if subcmd == "open" {
                subcmd = arg
            } else {
                cleanArgs.append(arg)
            }
        default:
            cleanArgs.append(arg)
        }
    }

    if showVersion {
        print("sqldoc \(version) · Pure Swift 6 & native SQLite")
        return
    }

    let subArgs = cleanArgs
    let options = DocOptions(isImmutable: isImmutable)

    switch subcmd {
    case "info":
        guard let path = subArgs.first else {
            print("Error: missing database file path for info\n")
            print(usage)
            exit(2)
        }
        do {
            try printInfo(path: path, options: options)
        } catch {
            fputs("sqldoc: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "bench":
        guard let path = subArgs.first else {
            print("Error: missing database file path for bench\n")
            print(usage)
            exit(2)
        }
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                try await printBench(path: path, options: options)
            } catch {
                fputs("sqldoc: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            sema.signal()
        }
        sema.wait()

    case "export":
        guard subArgs.count >= 2 else {
            print("Usage: sqldoc export <file.db> <table_name> [output.csv]")
            exit(2)
        }
        let dbPath = subArgs[0]
        let tableName = subArgs[1]
        let outputPath = subArgs.count >= 3 ? subArgs[2] : nil
        do {
            let doc = try Doc.open(path: dbPath, options: options)
            defer { doc.close() }
            let csv = try doc.exportCSV(for: tableName)
            if let out = outputPath {
                try csv.write(toFile: out, atomically: true, encoding: .utf8)
                print("Exported \(tableName) to \(out)")
            } else {
                print(csv)
            }
        } catch {
            fputs("sqldoc: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

    case "open":
        openFiles(paths: subArgs, launchApp: launchApp)

    default:
        // Treat arguments as database files to open
        openFiles(paths: cleanArgs, launchApp: launchApp)
    }
}

func padRight(_ s: String, _ length: Int) -> String {
    if s.count >= length { return s }
    return s + String(repeating: " ", count: length - s.count)
}

func padLeft(_ s: String, _ length: Int) -> String {
    if s.count >= length { return s }
    return String(repeating: " ", count: length - s.count) + s
}

func printInfo(path: String, options: DocOptions) throws {
    let doc = try Doc.open(path: path, options: options)
    defer { doc.close() }

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
    let modStr = dateFormatter.string(from: doc.modified)

    print("\(doc.path)")
    print("\(BenchmarkRunner.formatBytes(doc.size)) · \(modStr) · native libsqlite3\n")

    let col1 = padRight("TABLE", 28)
    let col2 = padRight("TYPE", 6)
    let col3 = padLeft("ROWS", 12)
    let col4 = "COLUMNS"
    print("\(col1) \(col2) \(col3)  \(col4)")
    print(String(repeating: "-", count: 60))

    for t in doc.tables {
        let cols = (try? doc.columns(for: t.name)) ?? []
        let count = doc.count(for: t.name)
        let rowsStr = count.displayString
        var name = t.name
        if t.hidden { name += " (meta)" }
        let truncatedName = name.count > 28 ? String(name.prefix(27)) + "…" : name

        let p1 = padRight(truncatedName, 28)
        let p2 = padRight(t.type, 6)
        let p3 = padLeft(rowsStr, 12)
        let p4 = "\(cols.count)"
        print("\(p1) \(p2) \(p3)  \(p4)")
    }
}

func printBench(path: String, options: DocOptions) async throws {
    print("Running sqldoc benchmark against \(path)...")
    let result = try await BenchmarkRunner.run(path: path, options: options)

    let fileName = URL(fileURLWithPath: result.path).lastPathComponent
    print("\n\(fileName) · \(BenchmarkRunner.formatBytes(result.size)) · Swift 6 / native libsqlite3")
    print("table \"\(result.targetTable)\", \(result.columnCount) columns\n")

    let openStr = padLeft(BenchmarkRunner.formatDuration(result.openDuration), 10)
    let firstPaintStr = padLeft(BenchmarkRunner.formatDuration(result.firstWindowDuration), 10)
    print("  open (metadata only)      \(openStr)")
    print("  first window (100 rows)   \(firstPaintStr)   [\(result.firstWindowPath)]")

    let initialCountStr = result.initialRowCount.exact ? "exact" : "estimate"
    let zeroStr = padLeft("0s", 10)
    print("  row count at open         \(zeroStr)   [\(initialCountStr): \(BenchmarkRunner.formatInt(result.initialRowCount.rows)) rows]")

    let settleStr = padLeft(BenchmarkRunner.formatDuration(result.countSettleDuration), 10)
    print("  exact count settled after \(settleStr)   [\(BenchmarkRunner.formatInt(result.settledRowCount)) rows, in the background]")

    let colWidthStr = padLeft(BenchmarkRunner.formatDuration(result.colWidthSettleDuration), 10)
    print("  column width sample       \(colWidthStr)   [24-anchor scan]\n")

    let scrollP50Str = padLeft(BenchmarkRunner.formatDuration(result.scrollP50), 10)
    let scrollP99Str = padLeft(BenchmarkRunner.formatDuration(result.scrollP99), 10)
    print("  \(padRight("scroll (keyset, 100 rows)", 32)) p50 \(scrollP50Str)   p99 \(scrollP99Str)")

    let seekP50Str = padLeft(BenchmarkRunner.formatDuration(result.seekP50), 10)
    let seekP99Str = padLeft(BenchmarkRunner.formatDuration(result.seekP99), 10)
    print("  \(padRight("seek to random position", 32)) p50 \(seekP50Str)   p99 \(seekP99Str)")

    let naiveP50Str = padLeft(BenchmarkRunner.formatDuration(result.naiveSeekP50), 10)
    let naiveP99Str = padLeft(BenchmarkRunner.formatDuration(result.naiveSeekP99), 10)
    print("  \(padRight("same seek, plain LIMIT/OFFSET", 32)) p50 \(naiveP50Str)   p99 \(naiveP99Str)\n")
}

func openFiles(paths: [String], launchApp: Bool) {
    let resolvedPaths = paths.map { (p: String) -> String in
        let abs = (p as NSString).expandingTildeInPath
        return URL(fileURLWithPath: abs).standardized.path
    }

    let openProcess = Process()
    openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    
    var openArgs: [String] = []
    if let appPath = ProcessInfo.processInfo.environment["SQLDOC_APP"] {
        openArgs.append(contentsOf: ["-a", appPath])
    } else {
        let candidates = [
            "/Applications/sqldoc.app",
            "\(NSHomeDirectory())/Applications/sqldoc.app"
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            openArgs.append(contentsOf: ["-a", c])
            break
        }
    }

    if !resolvedPaths.isEmpty {
        openArgs.append(contentsOf: resolvedPaths)
    }

    if !openArgs.isEmpty {
        openProcess.arguments = openArgs
        try? openProcess.run()
    } else {
        print("sqldoc: Launching viewer. For CLI inspection use `sqldoc info <file.db>` or `sqldoc bench <file.db>`.")
    }
}

runCLI()
