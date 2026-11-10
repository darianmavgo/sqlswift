import Foundation
import SQLite3

public final class CounterWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: TableCount] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    // Keyed by table so several open tables can each observe their own count
    // (a single shared closure meant only the last table registered won).
    private var observers: [String: @Sendable (TableCount) -> Void] = [:]

    public init() {}

    public func setObserver(for tableName: String, _ handler: (@Sendable (TableCount) -> Void)?) {
        lock.lock()
        observers[tableName] = handler
        lock.unlock()
    }

    public func getCachedCount(for tableName: String) -> TableCount? {
        lock.lock()
        defer { lock.unlock() }
        return counts[tableName]
    }

    public func updateCount(for tableName: String, count: TableCount) {
        lock.lock()
        counts[tableName] = count
        let observer = observers[tableName]
        lock.unlock()
        observer?(count)
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

    public func reset() {
        lock.lock()
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        counts.removeAll()
        lock.unlock()
    }
}

extension Doc {
    /// Returns the best known size of a table without blocking, and starts an exact count
    /// in the background the first time it is asked.
    public func count(for tableName: String) -> TableCount {
        if let existing = counterWorker.getCachedCount(for: tableName) {
            return existing
        }

        let initialEstimate = estimateRows(for: tableName)
        counterWorker.updateCount(for: tableName, count: initialEstimate)

        if !counterWorker.isStarted(for: tableName) {
            let task = Task.detached { [weak self] in
                guard let self else { return }
                await self.runExactCount(for: tableName)
            }
            counterWorker.registerTask(for: tableName, task: task)
        }

        return initialEstimate
    }

    /// Returns the same O(1) estimate that count() does, but never starts a background exact count.
    public func estimateRows(for tableName: String) -> TableCount {
        if let cached = cachedEstimate(for: tableName) { return cached }
        let estimate = computeEstimate(for: tableName)
        storeEstimate(estimate, for: tableName)
        return estimate
    }

    private func computeEstimate(for tableName: String) -> TableCount {
        // 1. Try sqlite_stat1 (if ANALYZE was run on the database)
        if let statCount = statEstimate(for: tableName) {
            return TableCount(rows: statCount, exact: false, known: true)
        }

        // 2. For rowid tables, max(rowid) - min(rowid) + 1 is an O(1) upper bound
        if let t = table(named: tableName), t.hasRowID {
            let (lo, hi, ok) = bounds(for: tableName)
            if ok && hi >= lo {
                return TableCount(rows: hi - lo + 1, exact: false, known: true)
            }
        }

        return TableCount(rows: 0, exact: false, known: false)
    }

    private func statEstimate(for tableName: String) -> Int64? {
        let q1 = "SELECT stat FROM sqlite_stat1 WHERE tbl = ? AND idx IS NULL LIMIT 1"
        if let row = try? fg.queryRow(q1, args: [tableName]), let stat = row.first?.textValue {
            let firstToken = stat.split(separator: " ").first.map(String.init) ?? ""
            if let n = Int64(firstToken), n >= 0 {
                return n
            }
        }

        let q2 = "SELECT stat FROM sqlite_stat1 WHERE tbl = ? LIMIT 1"
        if let row = try? fg.queryRow(q2, args: [tableName]), let stat = row.first?.textValue {
            let firstToken = stat.split(separator: " ").first.map(String.init) ?? ""
            if let n = Int64(firstToken), n >= 0 {
                return n
            }
        }

        return nil
    }

    /// Exact `COUNT(*)` over a filtered set. Runs on the background connection;
    /// callers should treat it as async work (it is a scan for a non-selective filter).
    public func filteredCount(table tableName: String, filters: [ColumnFilter]) -> Int64? {
        guard table(named: tableName) != nil, !filters.isEmpty else { return nil }
        let cols = (try? columns(for: tableName)) ?? []
        var clauses: [String] = []
        var args: [Any] = []
        for f in filters where cols.contains(where: { $0.name == f.column }) {
            let (clause, a) = f.sql(quotedColumn: Doc.quoteIdent(f.column))
            clauses.append("(\(clause))")
            args.append(contentsOf: a)
        }
        guard !clauses.isEmpty else { return nil }
        let sql = "SELECT COUNT(*) FROM \(Doc.quoteIdent(tableName)) WHERE \(clauses.joined(separator: " AND "))"
        return bg.queryRowWithTimeout(sql, args: args, maxMillis: BehaviorConfig.countFilteredBudgetMs)?.first?.intValue
    }

    private func runExactCount(for tableName: String) async {
        // Yield to foreground queries
        await waitIdle()

        guard let t = table(named: tableName) else { return }
        // Bound background COUNT(*) time so 20 GB tables (which already have an O(1)
        // rowid-bounds estimate) and expensive multi-stage window-function views never
        // thrash disk or CPU in the background.
        let budgetMs = t.isView ? BehaviorConfig.countExactViewBudgetMs : BehaviorConfig.countExactBudgetMs
        let q = "SELECT COUNT(*) FROM \(Doc.quoteIdent(tableName))"
        guard let row = bg.queryRowWithTimeout(q, maxMillis: budgetMs),
              let countVal = row.first?.intValue else {
            return
        }

        let exactCount = TableCount(rows: countVal, exact: true, known: true)
        counterWorker.updateCount(for: tableName, count: exactCount)
    }
}
