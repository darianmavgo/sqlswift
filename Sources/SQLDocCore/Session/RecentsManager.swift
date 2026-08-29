import Foundation

public struct RecentItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: Int64
    public var lastOpened: Date
    public var tableCount: Int

    public init(path: String, name: String, size: Int64, lastOpened: Date = Date(), tableCount: Int = 0) {
        self.path = path
        self.name = name
        self.size = size
        self.lastOpened = lastOpened
        self.tableCount = tableCount
    }
}

public final class RecentsManager: @unchecked Sendable {
    public static let shared = RecentsManager()
    private let lock = NSLock()
    private let storageKey = "sqldoc.recentDocuments"
    private var items: [RecentItem] = []

    public init() {
        load()
    }

    public func getRecents() -> [RecentItem] {
        lock.lock()
        defer { lock.unlock() }
        // Filter out paths that no longer exist on disk
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func touch(path: String, name: String, size: Int64, tableCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        items.removeAll { $0.path == path }
        let newItem = RecentItem(path: path, name: name, size: size, lastOpened: Date(), tableCount: tableCount)
        items.insert(newItem, at: 0)

        // Keep maximum 30 recent files
        if items.count > 30 {
            items = Array(items.prefix(30))
        }
        save()
    }

    public func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll { $0.path == path }
        save()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([RecentItem].self, from: data) {
            self.items = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
