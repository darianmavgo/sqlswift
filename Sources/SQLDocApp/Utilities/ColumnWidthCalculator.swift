import SwiftUI
import AppKit
import SQLDocCore

@MainActor
public enum ColumnWidthCalculator {
    public static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    public static let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    public static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    public static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attrs)
        return ceil(size.width)
    }

    /// Calculates pixel-perfect optimal column width based on exact font metrics for both header and sample data
    public static func optimalWidth(
        column: Column,
        sampleTexts: [String],
        minWidth: CGFloat = 50,
        maxWidth: CGFloat = 460
    ) -> CGFloat {
        // 1. Exact measurement of column name in header font
        let titleWidth = textWidth(column.name, font: headerFont)

        // 8pt left padding + 8pt right padding + 4pt margin
        var headerTotalWidth = titleWidth + 20

        if column.pk {
            // "PK" badge: 8pt horizontal padding + ~16pt text width + 6pt spacing
            headerTotalWidth += 30
        }

        // Add 16pt clearance for sort arrow indicator
        headerTotalWidth += 16

        // 2. Exact measurement of sample data texts
        var maxContentWidth: CGFloat = 0
        let dataFont = column.isNumeric ? monoFont : bodyFont

        for text in sampleTexts {
            guard !text.isEmpty else { continue }
            let truncated = text.count > 80 ? String(text.prefix(80)) : text
            let w = textWidth(truncated, font: dataFont)
            if w > maxContentWidth {
                maxContentWidth = w
            }
        }

        // 8pt left padding + 8pt right padding + 4pt margin
        let contentTotalWidth = maxContentWidth > 0 ? (maxContentWidth + 20) : 0

        // 3. The optimal column width is the maximum of header requirements and content requirements
        let bestWidth = max(headerTotalWidth, contentTotalWidth)
        return max(minWidth, min(maxWidth, bestWidth))
    }
}
