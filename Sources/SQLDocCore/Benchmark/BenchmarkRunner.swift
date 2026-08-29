import Foundation

public final class BenchmarkRunner {
    public struct BenchmarkResult: Sendable {
        public let path: String
        public let size: Int64
        public let targetTable: String
        public let columnCount: Int
        public let openDuration: Duration
        public let firstWindowDuration: Duration
        public let firstWindowPath: String
        public let initialRowCount: TableCount
        public let settledRowCount: Int64
        public let countSettleDuration: Duration
        public let colWidthSettleDuration: Duration
        public let scrollP50: Duration
        public let scrollP99: Duration
        public let seekP50: Duration
        public let seekP99: Duration
        public let naiveSeekP50: Duration
        public let naiveSeekP99: Duration
    }

    public static func run(path: String, options: DocOptions = DocOptions()) async throws -> BenchmarkResult {
        let t0 = DispatchTime.now()
        let doc = try Doc.open(path: path, options: options)
        defer { doc.close() }
        let openNanos = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds

        // Pick the largest table by estimate
        var target: String = ""
        var bestCount: Int64 = -1

        for t in doc.tables where !t.hidden {
            let c = doc.count(for: t.name)
            if c.known && c.rows > bestCount {
                bestCount = c.rows
                target = t.name
            } else if target.isEmpty {
                target = t.name
            }
        }

        if target.isEmpty {
            throw SQLiteError.executionFailed(query: "bench", message: "No tables found to benchmark")
        }

        let t1 = DispatchTime.now()
        let firstPage = try doc.rows(window: Window(table: target, limit: 100))
        let firstNanos = DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds

        let initialCount = doc.count(for: target)

        // Wait for background exact count to land
        let t2 = DispatchTime.now()
        var settledTotal: Int64 = 0
        for _ in 0..<1200 {
            let c = doc.count(for: target)
            if c.exact {
                settledTotal = c.rows
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let countSettleNanos = DispatchTime.now().uptimeNanoseconds - t2.uptimeNanoseconds

        // Wait for column width sample to land
        let t3 = DispatchTime.now()
        for _ in 0..<400 {
            let h = doc.columnHints(for: target)
            if h.done {
                break
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        let colWidthSettleNanos = DispatchTime.now().uptimeNanoseconds - t3.uptimeNanoseconds

        // Sequential scroll: 60 samples
        var scrollDurations: [UInt64] = []
        for i in 0..<60 {
            let after: Int64 = i > 0 ? Int64(i * 100) : 0
            let s = DispatchTime.now()
            _ = try? doc.rows(window: Window(table: target, limit: 100, after: after, useAfter: after > 0))
            let d = DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds
            scrollDurations.append(d)
        }
        scrollDurations.sort()
        let scrollP50 = Duration.nanoseconds(Int64(scrollDurations[scrollDurations.count / 2]))
        let scrollP99 = Duration.nanoseconds(Int64(scrollDurations[min(scrollDurations.count - 1, scrollDurations.count * 99 / 100)]))

        // Random seeks: 40 samples
        var seekDurations: [UInt64] = []
        let maxOffset = max(1, settledTotal)
        for _ in 0..<40 {
            let off = Int64.random(in: 0..<maxOffset)
            let s = DispatchTime.now()
            _ = try? doc.rows(window: Window(table: target, limit: 100, offset: off))
            let d = DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds
            seekDurations.append(d)
        }
        seekDurations.sort()
        let seekP50 = Duration.nanoseconds(Int64(seekDurations[seekDurations.count / 2]))
        let seekP99 = Duration.nanoseconds(Int64(seekDurations[min(seekDurations.count - 1, seekDurations.count * 99 / 100)]))

        // Naive seeks via LIMIT/OFFSET
        var naiveDurations: [UInt64] = []
        let deepOffset = settledTotal * 9 / 10
        for _ in 0..<5 {
            let s = DispatchTime.now()
            _ = try? doc.rows(window: Window(table: target, limit: 100, offset: deepOffset, forceOffset: true))
            let d = DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds
            naiveDurations.append(d)
        }
        naiveDurations.sort()
        let naiveP50 = Duration.nanoseconds(Int64(naiveDurations.isEmpty ? 0 : naiveDurations[naiveDurations.count / 2]))
        let naiveP99 = Duration.nanoseconds(Int64(naiveDurations.isEmpty ? 0 : naiveDurations[naiveDurations.count - 1]))

        return BenchmarkResult(
            path: doc.path,
            size: doc.size,
            targetTable: target,
            columnCount: firstPage.columns.count,
            openDuration: .nanoseconds(Int64(openNanos)),
            firstWindowDuration: .nanoseconds(Int64(firstNanos)),
            firstWindowPath: firstPage.path,
            initialRowCount: initialCount,
            settledRowCount: settledTotal,
            countSettleDuration: .nanoseconds(Int64(countSettleNanos)),
            colWidthSettleDuration: .nanoseconds(Int64(colWidthSettleNanos)),
            scrollP50: scrollP50,
            scrollP99: scrollP99,
            seekP50: seekP50,
            seekP99: seekP99,
            naiveSeekP50: naiveP50,
            naiveSeekP99: naiveP99
        )
    }

    public static func formatDuration(_ d: Duration) -> String {
        let (seconds, attoseconds) = d.components
        let nanos = Double(seconds) * 1_000_000_000.0 + Double(attoseconds) / 1_000_000_000.0
        let micros = nanos / 1000.0
        let millis = micros / 1000.0

        if micros < 1000.0 {
            return String(format: "%.0fµs", micros)
        } else if millis < 1000.0 {
            return String(format: "%.2fms", millis)
        } else {
            return String(format: "%.2fs", millis / 1000.0)
        }
    }

    public static func formatBytes(_ n: Int64) -> String {
        let u: Int64 = 1024
        if n < u { return "\(n) B" }
        var div = u
        var exp = 0
        let units = ["KB", "MB", "GB", "TB", "PB"]
        while n / div >= u && exp < units.count - 1 {
            div *= u
            exp += 1
        }
        return String(format: "%.1f %@", Double(n) / Double(div), units[exp])
    }

    public static func formatInt(_ n: Int64) -> String {
        return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}
