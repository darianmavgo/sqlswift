import Foundation
import SQLite3

/// Fast integer grouping. `NumberFormatter` costs microseconds per call — far too
/// much to run per cell — so group the digits by hand with the locale's grouping
/// separator (resolved once).
enum SQLiteValueFormat {
    private static let groupingSeparator: String = {
        Locale.current.groupingSeparator ?? ","
    }()

    static func integerString(_ v: Int64) -> String {
        let negative = v < 0
        // Careful with Int64.min, whose magnitude has no positive representation.
        var digits = String(v.magnitude)
        guard digits.count > 3 else { return String(v) }

        let sep = groupingSeparator
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3 + 1)
        let firstGroup = digits.count % 3 == 0 ? 3 : digits.count % 3
        var idx = digits.startIndex
        out += digits[idx..<digits.index(idx, offsetBy: firstGroup)]
        idx = digits.index(idx, offsetBy: firstGroup)
        while idx < digits.endIndex {
            out += sep
            out += digits[idx..<digits.index(idx, offsetBy: 3)]
            idx = digits.index(idx, offsetBy: 3)
        }
        digits.removeAll()
        return negative ? "-" + out : out
    }
}

/// Strongly-typed SQLite cell value supporting zero-copy and lazy representations.
public enum SQLiteValue: Equatable, Hashable, Sendable, CustomStringConvertible {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(bytes: Int)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var isBlob: Bool {
        if case .blob = self { return true }
        return false
    }

    public var intValue: Int64? {
        if case .integer(let v) = self { return v }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }

    /// The underlying scalar in a form `SQLiteConnection.bindArgs` understands,
    /// for use as a query parameter (keyset anchors, etc.).
    public var bindable: Any {
        switch self {
        case .null: return NSNull()
        case .integer(let v): return v
        case .real(let v): return v
        case .text(let s): return s
        case .blob: return NSNull()
        }
    }

    public var textValue: String? {
        switch self {
        case .text(let s): return s
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        case .blob(let b): return "◼ \(formatBytes(b))"
        case .null: return nil
        }
    }

    public var description: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let v):
            return String(v)
        case .real(let v):
            // Format round floating point values nicely
            if v.rounded() == v && !v.isInfinite && !v.isNaN && abs(v) < 1e15 {
                return String(Int64(v))
            }
            return String(v)
        case .text(let s):
            return s
        case .blob(let count):
            return "◼ \(formatBytes(count))"
        }
    }

    /// Formats the value for display in the grid cell
    public var displayText: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let v):
            return SQLiteValueFormat.integerString(v)
        case .real(let v):
            return String(format: "%g", v)
        case .text(let s):
            return s
        case .blob(let count):
            return "◼ \(formatBytes(count))"
        }
    }

    /// A cell string prepared for the grid: display text clamped to `maxChars`
    /// so the view never has to lay out a multi-megabyte string, plus a flag
    /// telling the view the value was clipped (for a hover hint / inspector cue).
    ///
    /// Tuned for the common case — a short single-line value — which returns the
    /// backing string with no allocation or grapheme counting.
    public func gridCell(maxChars: Int) -> (text: String, truncated: Bool) {
        switch self {
        case .text(let s):
            // Fast reject on UTF-8 length; only short strings reach the scan.
            if s.utf8.count <= maxChars {
                var hasBreak = false
                for b in s.utf8 where b == 0x0A || b == 0x0D { hasBreak = true; break }
                if !hasBreak { return (s, false) }
                let flattened = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined(separator: " ")
                return (flattened, true)
            }
            if s.count > maxChars {
                return (s.prefix(maxChars).replacingOccurrences(of: "\n", with: " ") + "…", true)
            }
            // Between the UTF-8 and grapheme thresholds: keep as-is, just flatten.
            if s.contains("\n") || s.contains("\r") {
                return (s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined(separator: " "), true)
            }
            return (s, false)
        case .integer, .real, .null:
            return (displayText, false)
        case .blob:
            return (displayText, false)
        }
    }

    /// Formats the value for CSV export
    public var csvText: String {
        switch self {
        case .null:
            return ""
        case .integer(let v):
            return String(v)
        case .real(let v):
            return String(v)
        case .text(let s):
            if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return s
        case .blob(let count):
            return "[BLOB \(formatBytes(count))]"
        }
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 {
            return "\(n) B"
        } else if n < 1024 * 1024 {
            return String(format: "%.1f KB", Double(n) / 1024.0)
        } else if n < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(n) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.2f GB", Double(n) / (1024.0 * 1024.0 * 1024.0))
        }
    }
}
