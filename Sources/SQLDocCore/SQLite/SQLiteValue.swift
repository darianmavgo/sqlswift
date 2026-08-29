import Foundation
import SQLite3

/// Shared, thread-safe integer grouping formatter. `NumberFormatter.localizedString`
/// builds a fresh formatter on every call, which is far too slow to run per cell
/// per frame — this caches one instance.
enum SQLiteValueFormat {
    static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static func integerString(_ v: Int64) -> String {
        grouped.string(from: NSNumber(value: v)) ?? String(v)
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
    public func gridCell(maxChars: Int) -> (text: String, truncated: Bool) {
        switch self {
        case .text(let s):
            if s.count > maxChars {
                return (String(s.prefix(maxChars)).trimmingCharacters(in: .newlines) + "…", true)
            }
            // Collapse hard line breaks so a single grid row stays one visual line.
            if s.contains("\n") || s.contains("\r") {
                let flattened = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined(separator: " ")
                return (flattened, flattened.count != s.count)
            }
            return (s, false)
        default:
            let t = displayText
            if t.count > maxChars {
                return (String(t.prefix(maxChars)) + "…", true)
            }
            return (t, false)
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
