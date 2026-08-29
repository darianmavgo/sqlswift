import Foundation
import SQLite3

public enum SQLiteError: LocalizedError {
    case openFailed(path: String, code: Int32, message: String)
    case prepareFailed(query: String, code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(index: Int32, code: Int32, message: String)
    case notADatabase(path: String)
    case tableNotFound(String)
    case columnNotFound(String)
    case executionFailed(query: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code, let message):
            return "Failed to open SQLite database at \(path): [\(code)] \(message)"
        case .prepareFailed(let query, let code, let message):
            return "Failed to prepare SQLite statement \"\(query)\": [\(code)] \(message)"
        case .stepFailed(let code, let message):
            return "SQLite step error: [\(code)] \(message)"
        case .bindFailed(let index, let code, let message):
            return "Failed to bind parameter at index \(index): [\(code)] \(message)"
        case .notADatabase(let path):
            return "\(path) is not a SQLite database"
        case .tableNotFound(let table):
            return "No such table: \(table)"
        case .columnNotFound(let col):
            return "No such column: \(col)"
        case .executionFailed(let query, let message):
            return "SQLite query execution failed for \"\(query)\": \(message)"
        }
    }
}
