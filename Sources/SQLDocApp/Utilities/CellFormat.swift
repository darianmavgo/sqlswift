import Foundation
import SQLDocCore

/// Best-effort "make this value readable" formatting for the grid, keyed off the
/// column name and the value itself. Applied only when smart-format is on and
/// only when the guess is unambiguous, so raw data is never hidden by accident.
enum CellFormat {
    enum Kind { case none, time, size, mode }

    private static let epochFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    /// Cheap one-time classification by column name — call this per column, not
    /// per cell, then pass the result to `pretty`.
    static func kind(forColumn name: String) -> Kind {
        let n = name.lowercased()
        if n == "mode" || n.contains("permission") || n.contains("perms") { return .mode }
        if n == "ts" || n == "time" || n == "date" || n == "timestamp"
            || n.hasSuffix("_at") || n.hasSuffix("_ts") || n.hasSuffix("_time")
            || n.hasSuffix("_date") || n.contains("epoch") { return .time }
        if n.contains("size") || n.contains("bytes") { return .size }
        return .none
    }

    /// Returns a formatted display string, or nil to fall back to the raw text.
    static func pretty(value: SQLiteValue, kind: Kind) -> String? {
        guard kind != .none else { return nil }
        switch value {
        case .integer(let i):
            switch kind {
            case .mode where i >= 0 && i <= 0o7777:
                return permissions(i)
            case .time where i > 100_000_000 && i < 4_102_444_800:
                return epochFormatter.string(from: Date(timeIntervalSince1970: Double(i)))
            case .time where i > 100_000_000_000 && i < 4_102_444_800_000:
                return epochFormatter.string(from: Date(timeIntervalSince1970: Double(i) / 1000))
            case .size where i >= 1024:
                return byteSize(i)
            default:
                return nil
            }
        case .real(let r) where kind == .time && r > 100_000_000 && r < 4_102_444_800:
            return epochFormatter.string(from: Date(timeIntervalSince1970: r))
        default:
            return nil
        }
    }

    static func permissions(_ mode: Int64) -> String {
        let bits = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        let u = Int((mode >> 6) & 7), g = Int((mode >> 3) & 7), o = Int(mode & 7)
        return "\(bits[u])\(bits[g])\(bits[o]) (\(String(mode, radix: 8)))"
    }

    static func byteSize(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }
}
