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
}
