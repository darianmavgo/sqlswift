import Foundation

/// Style represents presentation metadata that the SQLite document carries about itself,
/// read from the optional `_style` or `_head` key-value tables.
public struct Style: Equatable, Codable, Sendable {
    public var title: String?
    public var accent: String
    public var theme: String // "auto", "light", "dark"

    public init(title: String? = nil, accent: String = "#2563eb", theme: String = "auto") {
        self.title = title
        self.accent = accent
        self.theme = theme
    }

    public static let `default` = Style(title: nil, accent: "#2563eb", theme: "auto")
}
