import Foundation

public enum AppThemeMode: String, CaseIterable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public final class StatePersistenceManager: @unchecked Sendable {
    public static let shared = StatePersistenceManager()
    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    private let keyTheme = "sqldoc.settings.theme"
    private let keyZoom = "sqldoc.settings.zoom"
    private let keyColWidthPrefix = "sqldoc.colwidths."
    private let keySortPrefix = "sqldoc.sort."
    private let keyHiddenColsPrefix = "sqldoc.hiddencols."

    public init() {}

    // MARK: - Theme Mode
    public var themeMode: AppThemeMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let raw = defaults.string(forKey: keyTheme),
                  let mode = AppThemeMode(rawValue: raw) else {
                return .system
            }
            return mode
        }
        set {
            lock.lock()
            defaults.set(newValue.rawValue, forKey: keyTheme)
            lock.unlock()
        }
    }

    // MARK: - Zoom Scale
    public var zoomScale: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            let val = defaults.double(forKey: keyZoom)
            return val > 0 ? val : 1.0
        }
        set {
            lock.lock()
            defaults.set(newValue, forKey: keyZoom)
            lock.unlock()
        }
    }

    // MARK: - Column Widths
    public func saveColumnWidths(dbID: String, table: String, widths: [String: CGFloat]) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(keyColWidthPrefix)\(dbID):\(table)"
        let dict = widths.mapValues { Double($0) }
        defaults.set(dict, forKey: key)
    }

    public func loadColumnWidths(dbID: String, table: String) -> [String: CGFloat]? {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(keyColWidthPrefix)\(dbID):\(table)"
        guard let dict = defaults.dictionary(forKey: key) as? [String: Double] else {
            return nil
        }
        return dict.mapValues { CGFloat($0) }
    }

    public func clearColumnWidths(dbID: String, table: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(keyColWidthPrefix)\(dbID):\(table)"
        defaults.removeObject(forKey: key)
    }

    // MARK: - Sort preference (per table)

    /// (column, descending, numeric). column == nil clears the stored sort.
    public func saveSort(dbID: String, table: String, column: String?, desc: Bool, numeric: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = "\(keySortPrefix)\(dbID):\(table)"
        if let column {
            defaults.set(["c": column, "d": desc ? "1" : "0", "n": numeric ? "1" : "0"], forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func loadSort(dbID: String, table: String) -> (column: String, desc: Bool, numeric: Bool)? {
        lock.lock(); defer { lock.unlock() }
        let key = "\(keySortPrefix)\(dbID):\(table)"
        guard let d = defaults.dictionary(forKey: key) as? [String: String], let c = d["c"] else { return nil }
        return (c, d["d"] == "1", d["n"] == "1")
    }

    // MARK: - Hidden columns (per table)

    public func saveHiddenColumns(dbID: String, table: String, hidden: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let key = "\(keyHiddenColsPrefix)\(dbID):\(table)"
        if hidden.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(Array(hidden), forKey: key) }
    }

    public func loadHiddenColumns(dbID: String, table: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let key = "\(keyHiddenColsPrefix)\(dbID):\(table)"
        return Set((defaults.array(forKey: key) as? [String]) ?? [])
    }
}
