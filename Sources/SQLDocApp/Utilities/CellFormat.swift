import Foundation
import SQLDocCore

/// Best-effort "make this value readable" formatting for the grid, keyed off the
/// column name and the value itself. Applied only when smart-format is on and
/// only when the guess is unambiguous, so raw data is never hidden by accident.
enum CellFormat {
    private static let epochFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    /// Returns a formatted display string, or nil to fall back to the raw text.
    static func pretty(value: SQLiteValue, column: Column) -> String? {
        let name = column.name.lowercased()

        switch value {
        case .integer(let i):
            // Unix mode bits: a column called mode/permission/perms with a value
            // that looks like an octal file mode.
            if (name == "mode" || name.contains("permission") || name.contains("perms")),
               i >= 0, i <= 0o7777 {
                return permissions(i)
            }
            // Epoch timestamps in a time-ish column.
            if isTimeColumn(name) {
                if i > 100_000_000, i < 4_102_444_800 {           // ~1973 .. 2100 in seconds
                    return epochFormatter.string(from: Date(timeIntervalSince1970: Double(i)))
                }
                if i > 100_000_000_000, i < 4_102_444_800_000 {   // milliseconds
                    return epochFormatter.string(from: Date(timeIntervalSince1970: Double(i) / 1000))
                }
            }
            // Byte sizes.
            if (name.contains("size") || name.contains("bytes")) && i >= 1024 {
                return byteSize(i)
            }
            return nil

        case .real(let r):
            if isTimeColumn(name), r > 100_000_000, r < 4_102_444_800 {
                return epochFormatter.string(from: Date(timeIntervalSince1970: r))
            }
            return nil

        default:
            return nil
        }
    }

    private static func isTimeColumn(_ name: String) -> Bool {
        name == "ts" || name == "time" || name == "date" || name == "timestamp"
            || name.hasSuffix("_at") || name.hasSuffix("_ts") || name.hasSuffix("_time")
            || name.hasSuffix("_date") || name.contains("epoch")
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
