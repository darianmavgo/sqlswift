import Foundation
import SQLite3

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
            return NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
        case .real(let v):
            return String(format: "%g", v)
        case .text(let s):
            return s
        case .blob(let count):
            return "◼ \(formatBytes(count))"
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
