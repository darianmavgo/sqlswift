import SwiftUI
import SQLDocCore

public struct BusyOverlayView: View {
    let title: String
    let message: String
    let progress: Double?
    let onCancel: (() -> Void)?

    @State private var pulsePhase: Double = 0.0

    public init(title: String, message: String, progress: Double? = nil, onCancel: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.progress = progress
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            // Backdrop blur & tint
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Card Panel
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(title.isEmpty ? "Working…" : title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                }

                // Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background rule
                        Capsule()
                            .fill(Color(NSColor.separatorColor).opacity(0.4))
                            .frame(height: 5)

                        // Fill
                        if let prog = progress {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(8, geo.size.width * CGFloat(min(1.0, max(0.0, prog)))), height: 5)
                                .animation(.linear(duration: 0.1), value: prog)
                        } else {
                            // Indeterminate pulsing highlight
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color.accentColor.opacity(0.3),
                                            Color.accentColor,
                                            Color.accentColor.opacity(0.3)
                                        ]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * 0.4, height: 5)
                                .offset(x: (geo.size.width * 0.6) * CGFloat(sin(pulsePhase)))
                        }
                    }
                }
                .frame(height: 5)
                .frame(width: 260)

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }

                if let cancel = onCancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsePhase = .pi
            }
        }
    }
}
