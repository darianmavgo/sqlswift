import Foundation
import SQLite3

/// Metadata for a single discovered SQLite database file inside a scanned folder tree.
public struct SQLiteFileEntry: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let folderPath: String
    public let relativeFolder: String
    public let relativePath: String
    public let size: Int64
    public let modified: Date
    public var tables: [String]
    public var views: [String]

    public var totalObjects: Int { tables.count + views.count }

    public init(
        path: String,
        name: String,
        folderPath: String,
        relativeFolder: String,
        relativePath: String,
        size: Int64,
        modified: Date,
        tables: [String] = [],
        views: [String] = []
    ) {
        self.path = path
        self.name = name
        self.folderPath = folderPath
        self.relativeFolder = relativeFolder
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.tables = tables
        self.views = views
    }
}

/// Summary of a subfolder containing one or more SQLite files.
public struct FolderSummary: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { folderPath }
    public let relativeFolder: String
    public let folderPath: String
    public let fileCount: Int
    public let totalSize: Int64
    public let latestModified: Date

    public init(
        relativeFolder: String,
        folderPath: String,
        fileCount: Int,
        totalSize: Int64,
        latestModified: Date
    ) {
        self.relativeFolder = relativeFolder
        self.folderPath = folderPath
        self.fileCount = fileCount
        self.totalSize = totalSize
        self.latestModified = latestModified
    }
}

/// Fast directory scanner for discovering SQLite files, their folder hierarchy, and their tables/views.
public enum FolderScanner {
    public static let sqliteExtensions: Set<String> = ["db", "sqlite", "sqlite3", "db3"]

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "Library", "DerivedData", "__pycache__", ".venv", "venv", "target"
    ]

    /// Normalizes a user- or Banquet-supplied path string into a valid local filesystem path.
    /// Fixes paths where `BanquetParser.cleanURL` stripped the leading `/` (e.g. `"Users/darianhickman/Documents/"`).
    public static func resolveLocalPath(_ raw: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty { return "" }

        if str.hasPrefix("file://"), let url = URL(string: str) {
            str = url.path
        }
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) || (str.hasPrefix("'") && str.hasSuffix("'")) {
            str = String(str.dropFirst().dropLast())
        }

        let expanded = (str as NSString).expandingTildeInPath
        let fm = FileManager.default
        if fm.fileExists(atPath: expanded) {
            return standardizePath(expanded)
        }

        // BanquetParser strips a leading "/" during URL normalization, turning
        // "/Users/..." into "Users/...". Restore the leading "/" if that path exists.
        if !expanded.hasPrefix("/") {
            let withLeadingSlash = "/" + expanded
            if fm.fileExists(atPath: withLeadingSlash) {
                return standardizePath(withLeadingSlash)
            }
        }

        return expanded
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    private static func standardizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Recursively scans `rootPath` for SQLite files up to `maxDepth` directory levels,
    /// returning sorted files and per-subfolder summaries.
    public static func scan(
        rootPath: String,
        maxDepth: Int = 6,
        inspectSchema: Bool = true
    ) -> (root: String, files: [SQLiteFileEntry], folders: [FolderSummary]) {
        let resolvedRoot = resolveLocalPath(rootPath)
        let fm = FileManager.default
        guard isDirectory(resolvedRoot) else {
            return (resolvedRoot, [], [])
        }

        let rootURL = URL(fileURLWithPath: resolvedRoot, isDirectory: true).standardizedFileURL
        let rootComponentsCount = rootURL.pathComponents.count

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return (resolvedRoot, [], [])
        }

        var entries: [SQLiteFileEntry] = []

        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let depth = standardized.pathComponents.count - rootComponentsCount
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if skippedDirectoryNames.contains(standardized.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let ext = standardized.pathExtension.lowercased()
            guard sqliteExtensions.contains(ext) else { continue }

            let filePath = standardized.path
            let fileName = standardized.lastPathComponent
            // Skip internal build artifact DBs
            if fileName == "build.db" && filePath.contains("/.build/") { continue }

            let folderURL = standardized.deletingLastPathComponent()
            let folderPath = folderURL.path

            let relPath: String
            if filePath.hasPrefix(rootURL.path + "/") {
                relPath = String(filePath.dropFirst(rootURL.path.count + 1))
            } else {
                relPath = fileName
            }

            let relFolder: String
            if folderPath == rootURL.path {
                relFolder = "."
            } else if folderPath.hasPrefix(rootURL.path + "/") {
                relFolder = String(folderPath.dropFirst(rootURL.path.count + 1))
            } else {
                relFolder = folderURL.lastPathComponent
            }

            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? Date.distantPast

            var tables: [String] = []
            var views: [String] = []
            if inspectSchema && size > 0 {
                let schema = quickReadSchema(at: filePath)
                tables = schema.tables
                views = schema.views
            }

            entries.append(
                SQLiteFileEntry(
                    path: filePath,
                    name: fileName,
                    folderPath: folderPath,
                    relativeFolder: relFolder,
                    relativePath: relPath,
                    size: size,
                    modified: modified,
                    tables: tables,
                    views: views
                )
            )
        }

        // Sort files: relativeFolder first (root ".", then alphabetical), then name
        entries.sort { a, b in
            if a.relativeFolder != b.relativeFolder {
                if a.relativeFolder == "." { return true }
                if b.relativeFolder == "." { return false }
                return a.relativeFolder.localizedStandardCompare(b.relativeFolder) == .orderedAscending
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        // Build per-folder summaries
        var grouped: [String: [SQLiteFileEntry]] = [:]
        for entry in entries {
            grouped[entry.relativeFolder, default: []].append(entry)
        }

        var folderSummaries: [FolderSummary] = grouped.map { relFolder, files in
            let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
            let latest = files.map(\.modified).max() ?? Date.distantPast
            let fPath = files.first?.folderPath ?? resolvedRoot
            return FolderSummary(
                relativeFolder: relFolder,
                folderPath: fPath,
                fileCount: files.count,
                totalSize: totalBytes,
                latestModified: latest
            )
        }

        folderSummaries.sort { a, b in
            if a.relativeFolder == "." { return true }
            if b.relativeFolder == "." { return false }
            return a.relativeFolder.localizedStandardCompare(b.relativeFolder) == .orderedAscending
        }

        return (rootURL.path, entries, folderSummaries)
    }

    /// Reads table and view names from `sqlite_master` using a lightweight read-only handle.
    private static func quickReadSchema(at path: String) -> (tables: [String], views: [String]) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK || db == nil {
            if let db { sqlite3_close_v2(db) }
            db = nil
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let uri = "file:\(encoded)?immutable=1&mode=ro"
            guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, db != nil else {
                if let db { sqlite3_close_v2(db) }
                return ([], [])
            }
        }
        guard let validDB = db else { return ([], []) }
        defer { sqlite3_close_v2(validDB) }
        sqlite3_busy_timeout(validDB, 150)

        let sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' AND substr(name, 1, 1) != '_' ORDER BY type ASC, name ASC LIMIT 60"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(validDB, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return ([], [])
        }
        defer { sqlite3_finalize(stmt) }

        var tables: [String] = []
        var views: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(stmt, 0),
                  let typeC = sqlite3_column_text(stmt, 1) else { continue }
            let name = String(cString: nameC)
            let type = String(cString: typeC).lowercased()
            if type == "view" {
                views.append(name)
            } else {
                tables.append(name)
            }
        }
        return (tables, views)
    }
}
