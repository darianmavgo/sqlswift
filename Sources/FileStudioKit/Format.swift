import Foundation

/// Human formatting shared by the views (Kit has no SwiftUI, so this is plain strings).
public enum Fmt {
    public static func bytes(_ n: Int64) -> String {
        n == 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "1 file", "2.004 files".
    public static func files(_ n: Int64, _ noun: String = "file") -> String {
        "\(count(n)) \(n == 1 ? noun : noun + "s")"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    public static func count(_ n: Int64) -> String {
        n.formatted(.number)
    }

    public static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "—" }
        if s < 1 { return "<1s" }
        let t = Int(s.rounded())
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m \(t % 60)s" }
        return "\(t / 3600)h \((t % 3600) / 60)m"
    }

    public static func percent(_ f: Double) -> String {
        guard f.isFinite else { return "—" }
        return (f * 100).formatted(.number.precision(.fractionLength(f > 0 && f < 0.1 ? 1 : 0))) + "%"
    }

    /// "2026-11-20 16:26:26" / RFC 3339 from SQLite -> "3 min ago".
    public static func ago(_ sqliteTime: String, now: Date = Date()) -> String {
        guard let d = date(sqliteTime) else { return sqliteTime }
        return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: now)
    }

    public static func date(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }
}
