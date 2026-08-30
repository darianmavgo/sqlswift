import Foundation

/// Style represents presentation metadata that the SQLite document carries about
/// itself, read from the optional `_style` or `_head` key-value tables.
public struct Style: Equatable, Codable, Sendable {
    public var title: String?
    public var accent: String
    public var theme: String            // "auto", "light", "dark"

    // Extended `_head` keys — used natively where they make sense and baked into
    // the HTML export otherwise.
    public var favicon: String?
    public var description: String?
    public var author: String?
    public var fontFamily: String?
    public var bgColor: String?
    public var textColor: String?
    public var customCSS: String?
    public var pageSize: Int?

    public init(title: String? = nil, accent: String = "#2563eb", theme: String = "auto") {
        self.title = title
        self.accent = accent
        self.theme = theme
    }

    public static let `default` = Style(title: nil, accent: "#2563eb", theme: "auto")
}
