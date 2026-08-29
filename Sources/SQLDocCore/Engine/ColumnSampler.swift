import Foundation
import SQLite3

public final class ColumnSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var hints: [String: ColumnHint] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    public var onHintUpdated: (@Sendable (String, ColumnHint) -> Void)?

    public init() {}

    public func getCachedHint(for tableName: String) -> ColumnHint? {
        lock.lock()
        defer { lock.unlock() }
        return hints[tableName]
    }

    public func updateHint(for tableName: String, hint: ColumnHint) {
        lock.lock()
        hints[tableName] = hint
        lock.unlock()
        onHintUpdated?(tableName, hint)
    }

    public func isStarted(for tableName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks[tableName] != nil
    }

    public func registerTask(for tableName: String, task: Task<Void, Never>) {
        lock.lock()
        activeTasks[tableName] = task
        lock.unlock()
    }
}

extension Doc {
    public static let sampleAnchors = 24
    public static let sampleRowsPerAnchor = 12

    /// Returns the current best column-width hint without blocking, and starts a bounded
    /// 24-anchor background sample the first time it is asked.
    public func columnHints(for tableName: String) -> ColumnHint {
        if let existing = columnSampler.getCachedHint(for: tableName) {
            return existing
        }

        let initialHint = ColumnHint(table: tableName, known: false, done: false)
        columnSampler.updateHint(for: tableName, hint: initialHint)

        if !columnSampler.isStarted(for: tableName) {
            let task = Task.detached { [weak self] in
                guard let self else { return }
                await self.runColumnWidthSampling(for: tableName)
            }
            columnSampler.registerTask(for: tableName, task: task)
        }

        return initialHint
    }

    private func runColumnWidthSampling(for tableName: String) async {
        guard let t = table(named: tableName), t.hasRowID else {
            columnSampler.updateHint(for: tableName, hint: ColumnHint(table: tableName, known: false, done: true))
            return
        }

        let ts = tableState(for: tableName)
        guard let (cols, colExpr) = try? ts.getColumns(loader: { try columns(for: tableName) }) else {
            columnSampler.updateHint(for: tableName, hint: ColumnHint(table: tableName, known: false, done: true))
            return
        }

        let (lo, hi, ok) = bounds(for: tableName)
        guard ok, hi >= lo else {
            columnSampler.updateHint(for: tableName, hint: ColumnHint(table: tableName, known: true, done: true, samples: []))
            return
        }

        await waitIdle()

        var longest = Array(repeating: "", count: cols.count)
        let q = "SELECT \(colExpr) FROM \(ts.quoted) WHERE rowid >= ? ORDER BY rowid LIMIT ?"
        let span = hi - lo

        for i in 0..<Doc.sampleAnchors {
            let anchor: Int64
            if Doc.sampleAnchors > 1 {
                anchor = lo + Int64(Double(span) * Double(i) / Double(Doc.sampleAnchors - 1))
            } else {
                anchor = lo
            }

            if let rows = try? bg.query(q, args: [anchor, Doc.sampleRowsPerAnchor]) {
                for row in rows {
                    for (colIdx, val) in row.prefix(cols.count).enumerated() {
                        let sample = sampleText(val)
                        if sample.count > longest[colIdx].count {
                            longest[colIdx] = sample
                        }
                    }
                }
            }
        }

        let hint = ColumnHint(table: tableName, known: true, done: true, samples: longest)
        columnSampler.updateHint(for: tableName, hint: hint)
    }

    private func sampleText(_ val: SQLiteValue) -> String {
        let maxLen = 256
        let text: String
        switch val {
        case .null:
            text = "NULL"
        case .blob:
            text = "◼ 000 KB"
        case .text(let s):
            text = s
        case .integer(let v):
            text = String(v)
        case .real(let v):
            text = String(v)
        }
        if text.count > maxLen {
            return String(text.prefix(maxLen))
        }
        return text
    }
}
