import Foundation

/// Implements "Trim View" column ordering logic.
/// Conforms to `banquet-query-style.md`.
public struct QueryStyle {
    /// Orders columns based on the Banquet trim view rules.
    public static func orderColumns(
        primaryKeys: [String],
        allColumns: [String],
        sampledRows: [[String: Any]]
    ) -> [String] {
        // TODO: Implement the 8 rules:
        // 1. Primary keys first.
        // 2. name / label / description prioritized.
        // 3. Drop row-number.
        // 4. Group columns (<10 distinct, never null).
        // 5. Hide technical columns.
        // 6. status > date > numeric > free-text.
        // 7. Drop near-duplicates.
        // 8. Max ~40 columns.
        
        return allColumns
    }
}
