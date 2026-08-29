import SwiftUI
import AppKit
import SQLDocCore

public struct AppTheme {
    public static let primaryFont = Font.system(.body, design: .default)
    public static let monoFont = Font.system(.caption, design: .monospaced)
    public static let codeFont = Font.system(size: 12, weight: .regular, design: .monospaced)

    public static func color(from hex: String, defaultColor: Color = Color.accentColor) -> Color {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        guard cleanHex.count == 6, let rgb = UInt64(cleanHex, radix: 16) else {
            return defaultColor
        }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    public static func nsColor(from hex: String, defaultColor: NSColor = .controlAccentColor) -> NSColor {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        guard cleanHex.count == 6, let rgb = UInt64(cleanHex, radix: 16) else {
            return defaultColor
        }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    public static func color(for token: ColorToken, isDark: Bool) -> Color {
        color(from: isDark ? token.dark : token.light)
    }
}

/// Resolved grid colours for the current appearance, straight from the generated
/// `DesignToken` palette. One value, computed once per appearance, instead of the
/// ad-hoc `Color(NSColor.controlBackgroundColor).opacity(…)` guesses scattered
/// through the grid.
public struct GridPalette: Equatable, Sendable {
    public let ink: Color          // primary text
    public let dim: Color          // secondary text: headers, NULL, gutter
    public let rule: Color         // hairline gridlines
    public let ruleStrong: Color   // header underline / panel edges
    public let head: Color         // header + gutter + status fill
    public let page: Color         // cell surface
    public let stripe: Color       // zebra row tint
    public let selectionFill: Color
    public let matchFill: Color
    public let activeMatchFill: Color
    public let markBg: Color
    public let markFg: Color

    public static func resolve(dark: Bool, accent: Color) -> GridPalette {
        func c(_ t: ColorToken) -> Color { AppTheme.color(for: t, isDark: dark) }
        return GridPalette(
            ink: c(DesignToken.ink),
            dim: c(DesignToken.dim),
            rule: c(DesignToken.rule),
            ruleStrong: c(DesignToken.ruleStrong),
            head: c(DesignToken.head),
            page: c(DesignToken.page),
            stripe: c(DesignToken.head).opacity(DesignToken.rowStripeMix),
            selectionFill: accent.opacity(0.14),
            matchFill: accent.opacity(DesignToken.hitMix),
            activeMatchFill: accent.opacity(DesignToken.cursorMix),
            markBg: c(DesignToken.markBg),
            markFg: c(DesignToken.markFg)
        )
    }
}

private struct GridPaletteKey: EnvironmentKey {
    static let defaultValue = GridPalette.resolve(dark: false, accent: .accentColor)
}

public extension EnvironmentValues {
    var gridPalette: GridPalette {
        get { self[GridPaletteKey.self] }
        set { self[GridPaletteKey.self] = newValue }
    }
}
