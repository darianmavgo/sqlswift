import SwiftUI
import AppKit
import SQLDocCore
import FileStudioKit

/// FileStudio wears SqlSwift's clothes: the same generated design tokens (config/seed.sql →
/// `DesignToken`) and the same chrome pieces (toolbar buttons, pills, section headers), copied
/// from SQLDocApp's BanquetBarView / TableSidebarView / StatusBarView so both apps read as one.
struct FSPalette: Equatable {
    let ink, dim, rule, ruleStrong, head, page, ground: Color
    let ok, warn, error: Color

    static func resolve(dark: Bool) -> FSPalette {
        func c(_ t: ColorToken) -> Color { hex(dark ? t.dark : t.light) }
        return FSPalette(
            ink: c(DesignToken.ink), dim: c(DesignToken.dim),
            rule: c(DesignToken.rule), ruleStrong: c(DesignToken.ruleStrong),
            head: c(DesignToken.head), page: c(DesignToken.page),
            // SqlSwift's start page sits on the window background; the token ground is for behind a sheet
            ground: Color(NSColor.windowBackgroundColor),
            ok: c(DesignToken.statusOk), warn: c(DesignToken.statusWarn), error: c(DesignToken.statusError))
    }

    static func hex(_ s: String) -> Color {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return .secondary }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

private struct FSPaletteKey: EnvironmentKey {
    static let defaultValue = FSPalette.resolve(dark: false)
}

extension EnvironmentValues {
    var fsPalette: FSPalette {
        get { self[FSPaletteKey.self] }
        set { self[FSPaletteKey.self] = newValue }
    }
}

/// SqlSwift's type scale: system for prose, monospaced for names, paths and numbers.
enum FSFont {
    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let label = Font.system(size: 11, weight: .medium)
    static let sectionHeader = Font.system(size: 10, weight: .bold)
    static let panelTitle = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let bigNumber = Font.system(size: 22, weight: .semibold, design: .monospaced)
}

/// The 28 pt bordered button of SqlSwift's top bar (BanquetBarView.toolbarIconButton).
struct ToolbarButton: View {
    let icon: String
    var label: String? = nil
    var isActive = false
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                if let label { Text(label).font(.system(size: 11, weight: .medium)) }
            }
            .padding(.horizontal, label != nil ? 8 : 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? accent.opacity(0.16) : Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? accent.opacity(0.6) : Color(NSColor.separatorColor).opacity(0.65), lineWidth: 1))
            .foregroundColor(isActive ? accent : .primary)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var accent: Color { tint ?? .accentColor }
}

/// A count or value pill (the sidebar's row counts, the top bar's telemetry).
struct Pill: View {
    let text: String
    var tint: Color? = nil
    var selected = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(selected ? .white.opacity(0.9) : (tint ?? .secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(selected ? Color.white.opacity(0.18) : (tint ?? .secondary).opacity(0.12)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The small uppercase tag (SqlSwift's VIEW / PK / DEV badges).
struct Tag: View {
    let text: String
    var tint: Color = .secondary
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 2.5) {
            if let icon { Image(systemName: icon).font(.system(size: 8)) }
            Text(text.uppercased()).font(.system(size: 8.5, weight: .bold, design: .monospaced))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3.5).fill(tint.opacity(0.14)))
        .fixedSize()
    }
}

/// "TABLES        7": a sidebar section title with its count.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack {
            Text(title.uppercased()).font(FSFont.sectionHeader).foregroundColor(.secondary)
            Spacer()
            if let count {
                Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

enum Compact {
    /// 6,514 → "6,514"; 400,211 → "400.2k"; 1,200,000 → "1.2M" (TableSidebarView.compactCount).
    static func count(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return Fmt.count(n)
    }

    /// µs as SqlSwift's timing badge prints it.
    static func micros(_ us: Int64) -> String {
        if us < 1000 { return "\(us) µs" }
        if us < 1_000_000 { return String(format: "%.2f ms", Double(us) / 1000) }
        return String(format: "%.2f s", Double(us) / 1_000_000)
    }
}

/// Status colours from the tokens (same in light and dark), so `.fsOk` reads like `.green` did.
extension ShapeStyle where Self == Color {
    static var fsOk: Color { FSPalette.hex(DesignToken.statusOk.light) }
    static var fsWarn: Color { FSPalette.hex(DesignToken.statusWarn.light) }
    static var fsError: Color { FSPalette.hex(DesignToken.statusError.light) }
}
