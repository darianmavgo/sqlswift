import SwiftUI
import FileStudioKit
import SQLDocCore

/// A titled panel: the one container every screen is built from, so spacing and surfaces match.
struct Card<Content: View, Accessory: View>: View {
    let title: String?
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content
    }

    @Environment(\.fsPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || subtitle != nil {
                // a grid header strip: the panel's title on the `head` surface, ruled off from the body
                HStack(alignment: .center, spacing: 8) {
                    if let title {
                        Text(title.uppercased()).font(FSFont.sectionHeader).foregroundColor(palette.dim)
                            .lineLimit(1)
                    }
                    if let subtitle {
                        Text(subtitle).font(FSFont.caption).foregroundColor(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    accessory().controlSize(.small)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(palette.head)
                .overlay(Rectangle().frame(height: 1).foregroundColor(palette.rule), alignment: .bottom)
            }
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.page, in: RoundedRectangle(cornerRadius: DesignToken.radiusCard))
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: DesignToken.radiusCard).strokeBorder(palette.ruleStrong))
    }
}

/// A big number with a label: the three facts that matter, readable from across the room.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var symbol: String
    var tint: Color = .accentColor
    var loading = false

    @Environment(\.fsPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundColor(tint)
                Text(title.uppercased()).font(FSFont.sectionHeader).foregroundColor(palette.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(FSFont.bigNumber)
                    .foregroundColor(palette.ink)
                    .contentTransition(.numericText())
                if loading { ProgressView().controlSize(.small) }
            }
            Text(detail.isEmpty ? " " : detail)
                .font(FSFont.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.page, in: RoundedRectangle(cornerRadius: DesignToken.radiusCard))
        .overlay(alignment: .leading) {
            // the accent edge SqlSwift uses for a selected row
            Rectangle().fill(tint).frame(width: 3).padding(.vertical, 10)
        }
        .overlay(RoundedRectangle(cornerRadius: DesignToken.radiusCard).strokeBorder(palette.ruleStrong))
    }
}

/// Throughput over the last minute. Drawn as one path in a Canvas: cheap to redraw at 4 Hz.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let peak = max(values.max() ?? 1, 1)
            let step = size.width / CGFloat(max(values.count - 1, 1))
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(values[i] / peak) * (size.height - 2) - 1)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var fill = line
            fill.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .accessibilityLabel("Transfer speed over time")
    }
}

/// A slim bar with a fraction, used in lists (no animation cost per row).
struct Meter: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6
    /// An optional lighter layer under the bar (work in progress, not yet counted).
    var under: Double = 0

    @Environment(\.fsPalette) private var palette

    private static func clamp(_ f: Double) -> Double { max(0, min(1, f.isFinite ? f : 0)) }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(palette.rule)
                if under > fraction {
                    RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.35)).frame(width: Self.clamp(under) * g.size.width)
                }
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: Self.clamp(fraction) * g.size.width)
            }
        }
        .frame(height: height)
    }
}

struct WorkerBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.workerHealthy ? Color.fsOk : (model.workerStatus == .missingBinary ? .fsError : .fsWarn))
                .frame(width: 7, height: 7)
            Text(model.workerLabel).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
        }
        .help(helpText)
    }

    private var helpText: String {
        switch model.workerStatus {
        case .missingBinary:
            "FileStudio could not find the filestudio command. Build it (go build -o bin/filestudio ./cmd/filestudio) or set FILESTUDIO_BIN."
        case .crashed(let why): why
        default: "The worker does the backups and deletes; this app only asks it to."
        }
    }
}

/// Small coloured label for a state such as verified / failed / changed.
struct StateChip: View {
    let state: String

    var body: some View { Tag(text: label, tint: color) }

    private var label: String { Self.label(for: state) }

    static func label(for state: String) -> String {
        switch state {
        case "verified": "Proven"
        case "unproven": "No checksum"
        case "changed": "Changed"
        case "gone": "Gone"
        case "failed": "Failed"
        case "queued": "Queued"
        case "running": "Running"
        case "done": "Done"
        case "stopped": "Stopped"
        case "interrupted": "Interrupted"
        case "error": "Error"
        default: state.capitalized
        }
    }

    private var color: Color {
        switch state {
        case "verified", "done": FSPalette.hex(DesignToken.statusOk.light)
        case "failed", "error": FSPalette.hex(DesignToken.statusError.light)
        case "running", "queued": .blue
        case "changed", "unproven", "stopped", "interrupted": FSPalette.hex(DesignToken.statusWarn.light)
        default: .secondary
        }
    }
}

/// Shown instead of a screen while there is no database (SqlSwift's empty folder page).
struct EmptyState: View {
    let title: String
    let message: String
    var symbol = "externaldrive"
    var action: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundColor(.secondary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            if let action { Button(action.0, action: action.1) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
