import Foundation

/// Banquet URLs the user has submitted, most recent first. Feeds the bar's
/// suggestion dropdown (the omnibox "history"). Persisted in UserDefaults like
/// `RecentsManager`; the cap comes from `BehaviorConfig.omniboxHistoryMax`.
public final class BanquetHistory: @unchecked Sendable {
    public static let shared = BanquetHistory()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let maxEntries: Int
    private var urls: [String] = []

    public init(
        storageKey: String = "sqldoc.banquetHistory",
        defaults: UserDefaults = .standard,
        maxEntries: Int = BehaviorConfig.omniboxHistoryMax
    ) {
        self.storageKey = storageKey
        self.defaults = defaults
        self.maxEntries = max(0, maxEntries)
        self.urls = defaults.stringArray(forKey: storageKey) ?? []
    }

    public var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    /// Moves `url` to the front (de-duplicated) and trims to the cap.
    public func record(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxEntries > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        urls.removeAll { $0 == trimmed }
        urls.insert(trimmed, at: 0)
        if urls.count > maxEntries { urls = Array(urls.prefix(maxEntries)) }
        defaults.set(urls, forKey: storageKey)
    }

    /// Forgets one URL (the omnibox "remove this suggestion" action).
    public func remove(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        urls.removeAll { $0 == url }
        defaults.set(urls, forKey: storageKey)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        urls.removeAll()
        defaults.removeObject(forKey: storageKey)
    }
}

/// Back/forward through the Banquet URLs a session has visited (⌘[ / ⌘]).
/// A value type so it is trivially testable; the app view-model owns one.
public struct BanquetNavStack: Equatable, Sendable {
    public private(set) var entries: [String] = []
    public private(set) var index: Int = -1
    private let maxEntries: Int

    public init(maxEntries: Int = BehaviorConfig.omniboxNavStackMax) {
        self.maxEntries = max(1, maxEntries)
    }

    public var current: String? { entries.indices.contains(index) ? entries[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Visiting a new URL discards the forward entries. Re-visiting the current URL is a no-op.
    public mutating func visit(_ url: String) {
        guard !url.isEmpty, url != current else { return }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(url)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        index = entries.count - 1
    }

    public mutating func back() -> String? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    public mutating func forward() -> String? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}

/// ↑/↓ recall of submitted URLs in the bar (banquet-bar-style rule 6). ↑ walks to older
/// entries, ↓ back toward the newest and then to the unsubmitted draft. Pure value type.
public struct BanquetRecall: Equatable, Sendable {
    public private(set) var index: Int?
    public private(set) var draft = ""
    /// The text recall last wrote into the bar; seeing it again means "still browsing", not typing.
    public private(set) var lastWritten: String?

    public init() {}

    public var isRecalling: Bool { index != nil }

    /// The text the bar should now show, or nil when there is nowhere further to go.
    public mutating func step(older: Bool, current: String, entries: [String]) -> String? {
        var next = (index ?? -1) + (older ? 1 : -1)
        if index == nil {
            if !older { return nil }          // ↓ with nothing recalled is not ours
            // The newest entry is usually the URL already showing; ↑ should go somewhere new.
            if entries.indices.contains(next), entries[next] == current { next += 1 }
        }
        if next >= entries.count { return nil }
        if index == nil { draft = current }
        let value: String
        if next < 0 {
            index = nil
            value = draft
        } else {
            index = next
            value = entries[next]
        }
        lastWritten = value
        return value
    }

    /// The user typed, blurred, or navigated: forget the walk.
    public mutating func reset() {
        index = nil
        lastWritten = nil
        draft = ""
    }
}
