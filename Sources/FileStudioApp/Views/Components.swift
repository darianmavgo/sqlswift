import SwiftUI
import FileStudioKit

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(.headline) }
                        if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 12)
                    accessory()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if loading { ProgressView().controlSize(.small) }
            }
            Text(detail.isEmpty ? " " : detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
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

    private static func clamp(_ f: Double) -> Double { max(0, min(1, f.isFinite ? f : 0)) }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if under > fraction {
                    Capsule().fill(tint.opacity(0.35)).frame(width: Self.clamp(under) * g.size.width)
                }
                Capsule().fill(tint).frame(width: Self.clamp(fraction) * g.size.width)
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
                .fill(model.workerHealthy ? Color.green : (model.workerStatus == .missingBinary ? .red : .orange))
                .frame(width: 8, height: 8)
            Text(model.workerLabel).font(.callout)
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

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var label: String {
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
        case "verified", "done": .green
        case "failed", "error": .red
        case "running", "queued": .blue
        case "changed", "unproven", "stopped", "interrupted": .orange
        default: .secondary
        }
    }
}

/// Shown instead of a screen while there is no database.
struct EmptyState: View {
    let title: String
    let message: String
    var symbol = "externaldrive"

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}
