import Foundation
import CryptoKit

public final class DocEntry: Identifiable, @unchecked Sendable {
    public var id: String
    public let path: String
    public let name: String
    public let size: Int64
    public let opened: Date
    public var isEphemeral: Bool
    public let doc: Doc

    public init(id: String, path: String, name: String, size: Int64, opened: Date = Date(), isEphemeral: Bool = false, doc: Doc) {
        self.id = id
        self.path = path
        self.name = name
        self.size = size
        self.opened = opened
        self.isEphemeral = isEphemeral
        self.doc = doc
    }
}

public final class SessionManager: @unchecked Sendable {
    public static let shared = SessionManager()
    private let lock = NSLock()
    private var docs: [String: DocEntry] = [:]
    private var order: [String] = []
    private var tempDirectories: [String] = []

    public init() {}

    public static func computeID(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    public func open(path: String, options: DocOptions = DocOptions()) throws -> DocEntry {
        let expanded = (path as NSString).expandingTildeInPath
        let resolvedPath: String
        if (expanded as NSString).isAbsolutePath {
            resolvedPath = URL(fileURLWithPath: expanded).standardized.path
        } else {
            let currentDir = FileManager.default.currentDirectoryPath
            resolvedPath = URL(fileURLWithPath: (currentDir as NSString).appendingPathComponent(expanded)).standardized.path
        }
        let id = SessionManager.computeID(for: resolvedPath)

        lock.lock()
        if let existing = docs[id] {
            lock.unlock()
            RecentsManager.shared.touch(
                path: existing.path,
                name: existing.name,
                size: existing.size,
                tableCount: existing.doc.tables.count
            )
            return existing
        }
        lock.unlock()

        let doc = try Doc.open(path: resolvedPath, options: options)
        let name = URL(fileURLWithPath: resolvedPath).lastPathComponent
        let entry = DocEntry(
            id: id,
            path: resolvedPath,
            name: name,
            size: doc.size,
            opened: Date(),
            isEphemeral: false,
            doc: doc
        )

        lock.lock()
        if let existing = docs[id] {
            lock.unlock()
            doc.close()
            return existing
        }
        docs[id] = entry
        order.append(id)
        lock.unlock()

        RecentsManager.shared.touch(
            path: entry.path,
            name: entry.name,
            size: entry.size,
            tableCount: doc.tables.count
        )
        return entry
    }

    public func openTemporary(data: Data, originalName: String, options: DocOptions = DocOptions()) throws -> DocEntry {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sqldoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let safeName = originalName.isEmpty ? "database.db" : originalName
        let tempFile = tempDir.appendingPathComponent(safeName)
        try data.write(to: tempFile)

        let entry = try open(path: tempFile.path, options: options)
        entry.isEphemeral = true

        lock.lock()
        tempDirectories.append(tempDir.path)
        lock.unlock()

        return entry
    }

    public func get(id: String) -> DocEntry? {
        lock.lock()
        defer { lock.unlock() }
        return docs[id]
    }

    public func list() -> [DocEntry] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { docs[$0] }
    }

    public func first() -> DocEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstID = order.first else { return nil }
        return docs[firstID]
    }

    public func close(id: String) {
        lock.lock()
        guard let entry = docs.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        order.removeAll { $0 == id }
        lock.unlock()

        entry.doc.close()
        if entry.isEphemeral {
            try? FileManager.default.removeItem(atPath: (entry.path as NSString).deletingLastPathComponent)
        }
    }

    public func closeAll() {
        let entries = list()
        for e in entries {
            close(id: e.id)
        }
        lock.lock()
        for dir in tempDirectories {
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDirectories.removeAll()
        lock.unlock()
    }
}
