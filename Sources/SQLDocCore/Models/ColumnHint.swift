import Foundation

/// ColumnHint is a best-effort column width hint for a table, corrected in the background
/// from a bounded 24-anchor sample of representative values.
public struct ColumnHint: Equatable, Codable, Sendable {
    public let table: String
    public var known: Bool
    public var done: Bool
    public var samples: [String]

    public init(table: String, known: Bool = false, done: Bool = false, samples: [String] = []) {
        self.table = table
        self.known = known
        self.done = done
        self.samples = samples
    }
}
