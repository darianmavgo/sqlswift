import Foundation
import Testing
import SQLDocCore
@testable import FileStudioKit

/// These run against a real filestudio db made by the Go binary, so the triggers and views are the
/// real ones. Without the binary (FILESTUDIO_BIN, or ../filestudio/bin/filestudio) they are skipped.
enum Fixture {
    static let binary: String? = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FILESTUDIO_BIN"], fm.isExecutableFile(atPath: env) { return env }
        let here = URL(fileURLWithPath: #filePath) // <repo>/Tests/FileStudioKitTests/x.swift
        let p = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../filestudio/bin/filestudio").standardizedFileURL.path
        return fm.isExecutableFile(atPath: p) ? p : nil
    }()

    /// A fresh filestudio db in a temp dir (the binary creates the schema on first open).
    static func makeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fskit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("t.db").path
        try runCLI(db, ["query", "select 1"])
        return db
    }

    @discardableResult
    static func runCLI(_ db: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary!)
        p.arguments = ["-db", db] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite(.enabled(if: Fixture.binary != nil, "needs the filestudio binary"))
struct LiveDBTests {
    @Test func opensAndReadsActions() throws {
        let (db, _) = try LiveDB.open(path: try Fixture.makeDB())
        let s = db.loadSnapshot()
        #expect(Set(s.actions.keys).isSuperset(of: ["free", "apply", "backup", "retry_failed", "stop"]))
        #expect(s.busyAction == nil)
        #expect(s.run == nil)
    }

    @Test func refusesNonFilestudioDB() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString).db").path
        let c = try SQLiteConnection(path: path, readOnly: false)
        _ = try c.exec("PRAGMA journal_mode=WAL; CREATE TABLE t(x)")
        c.close()
        #expect(throws: LiveDBError.notFilestudio(path)) { try LiveDB(path: path) }
    }

    @Test func changeCounterMovesOnAnotherConnectionsCommit() throws {
        let path = try Fixture.makeDB()
        let (db, cmd) = try LiveDB.open(path: path)
        let before = db.changeCounter()
        #expect(db.changeCounter() == before) // nothing changed: same value, nothing to re-read
        try cmd.setSetting("bk_transfers", "16")
        #expect(db.changeCounter() != before)
        #expect(db.loadSnapshot().settings["bk_transfers"] == "16")
    }
}

@Suite(.enabled(if: Fixture.binary != nil, "needs the filestudio binary"))
struct CommandsTests {
    @Test func queuesAnActionAndTheTriggerAllowsOnlyOne() throws {
        let path = try Fixture.makeDB()
        let (db, cmd) = try LiveDB.open(path: path)
        try cmd.run("backup")
        #expect(db.loadSnapshot().actions["backup"]?.state == "queued")
        // the db's own trigger refuses a second action while one is queued
        #expect(throws: CommandError.self) { try cmd.run("free") }
        // stop is allowed while something is queued/running: it becomes a request
        try cmd.run("stop")
        #expect(db.loadSnapshot().actions["stop"]?.state == "requested")
    }

    @Test func refusesWhatTheProtocolDoesNotAllow() throws {
        let cmd = try Commands(path: try Fixture.makeDB())
        #expect(throws: CommandError.notAllowed("drop_everything")) { try cmd.run("drop_everything") }
        #expect(throws: CommandError.notAllowed("apply")) { try cmd.run("apply") } // only via apply(confirm:)
        #expect(throws: CommandError.notAllowed("gmail_token")) { try cmd.setSetting("gmail_token", "x") }
    }

    @Test func applyNeedsTheExactPhrase() throws {
        let path = try Fixture.makeDB()
        let cmd = try Commands(path: path)
        do {
            try cmd.apply(confirm: "DELETE EVERYTHING")
            Issue.record("apply with a wrong phrase was accepted")
        } catch let CommandError.refused(msg) {
            #expect(msg.contains("phrase"))
        }
        let s = try LiveDB(path: path).loadSnapshot() // cmd keeps the WAL files open
        #expect(s.actions["apply"]?.state == "idle")
    }

    @Test func setBackupValidatesSources() throws {
        let path = try Fixture.makeDB()
        let cmd = try Commands(path: path)
        #expect(throws: CommandError.self) { try cmd.setBackup(target: "nope", prefix: "", from: "") }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        let bak = FileManager.default.temporaryDirectory.appendingPathComponent("bak-\(UUID().uuidString)")
        for d in [local, bak] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("hi".utf8).write(to: local.appendingPathComponent("a.txt"))
        try Fixture.runCLI(path, ["index", "loc", local.path])
        try Fixture.runCLI(path, ["index", "bak", bak.path])
        try cmd.setBackup(target: "bak", prefix: "p", from: "loc")
        let c = try LiveDB(path: path).loadSnapshot().config
        #expect(c.target == "bak" && c.prefix == "p" && c.from == "loc")
        #expect(throws: CommandError.self) { try cmd.setBackup(target: "bak", prefix: "", from: "no_such_local") }
    }
}

@Suite(.enabled(if: Fixture.binary != nil, "needs the filestudio binary"), .serialized)
struct WorkerSupervisorTests {
    private func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            usleep(50_000)
        }
        return cond()
    }

    @Test func startsRestartsAndStopsTheWorker() throws {
        let path = try Fixture.makeDB()
        let (db, cmd) = try LiveDB.open(path: path)
        defer { _ = cmd }
        let sup = WorkerSupervisor(dbPath: path, binary: Fixture.binary)
        sup.onChildDied = { pid in try? cmd.releaseWorkerLease(deadPID: pid) }
        sup.ensureRunning(externalAlive: false)
        #expect(waitFor(5) { db.loadSnapshot().workerAlive })
        guard case let .running(pid) = sup.status else { Issue.record("not running: \(sup.status)"); return }

        kill(pid, SIGKILL) // a crash: the lease is released for the dead pid, so the restart is quick
        func leaseHolder() -> String {
            (try? db.row("SELECT value FROM app_flags WHERE key='worker_pid'"))??.string(0) ?? ""
        }
        #expect(waitFor(6) {
            let holder = leaseHolder()
            return !holder.isEmpty && holder != String(pid) && db.loadSnapshot().workerAlive
        })

        // let the new worker get past startup (signal handling, first heartbeat) before stopping it;
        // a SIGTERM in its first milliseconds kills it before it can clear the heartbeat
        Thread.sleep(forTimeInterval: 1.5)
        sup.stop()
        #expect(sup.status == .stopped)
        #expect(waitFor(3) { !db.loadSnapshot().workerAlive }) // SIGTERM clears the heartbeat
    }

    @Test func leavesAnExternalWorkerAlone() throws {
        let sup = WorkerSupervisor(dbPath: try Fixture.makeDB(), binary: Fixture.binary)
        sup.ensureRunning(externalAlive: true)
        #expect(sup.status == .external)
    }

    @Test func reportsAMissingBinary() throws {
        let sup = WorkerSupervisor(dbPath: try Fixture.makeDB(), binary: "/nonexistent/filestudio")
        sup.ensureRunning(externalAlive: false)
        #expect(sup.status == .missingBinary)
    }
}

struct CoverageTests {
    @Test func emptyFilesCountByFiles() {
        #expect(Coverage(files: 10, bytes: 0, provenFiles: 10, provenBytes: 0).fraction == 1)
        #expect(Coverage(files: 10, bytes: 0, provenFiles: 5, provenBytes: 0).fraction == 0.5)
        #expect(Coverage(files: 0, bytes: 0, provenFiles: 0, provenBytes: 0).fraction == 1)
        #expect(Coverage(files: 2, bytes: 100, provenFiles: 1, provenBytes: 25).fraction == 0.25)
    }
}
