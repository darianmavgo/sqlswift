import SwiftUI
import AppKit
import SQLDocCore

/// Fully editable, native Banquet Address Bar.
/// Conforms to the Banquet URL specification (https://github.com/darianmavgo/banquet).
public struct BanquetBarView: View {
    @ObservedObject public var appVM: AppViewModel
    public var activeTableVM: TableViewModel?
    public var palette: GridPalette

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    public init(appVM: AppViewModel, activeTableVM: TableViewModel? = nil, palette: GridPalette) {
        self.appVM = appVM
        self.activeTableVM = activeTableVM
        self.palette = palette
    }

    private var canonicalURL: String {
        appVM.banquetURLString(for: activeTableVM)
    }

    public var body: some View {
        HStack(spacing: 6) {
            // Protocol badge
            HStack(spacing: 3) {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .bold))
                Text("banquet")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(isFocused ? .accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isFocused ? Color.accentColor.opacity(0.15) : Color(NSColor.quaternaryLabelColor).opacity(0.5))
            )
            .padding(.leading, 6)

            // Direct Native Editable TextField
            TextField("Banquet URL (e.g. sample.db/telemetry/+temperature[0:50])", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .focused($isFocused)
                .onSubmit {
                    submit()
                }
                .onExitCommand {
                    revert()
                }
                .frame(maxWidth: .infinity)

            // Clear button
            if isFocused && !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear address")
            }

            // Go Button
            if isFocused {
                Button(action: { submit() }) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Navigate to Banquet URL (Return)")
            }

            // Copy Banquet URL Button
            Button(action: {
                appVM.copyBanquetURL(for: activeTableVM)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: appVM.banquetCopiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(appVM.banquetCopiedFeedback ? .green : .secondary)

                    if appVM.banquetCopiedFeedback {
                        Text("Copied")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy Banquet URL (⌘⌥C)")
            .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isFocused ? Color.accentColor : Color(NSColor.separatorColor).opacity(0.7),
                    lineWidth: isFocused ? 1.5 : 1.0
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
        .onAppear {
            syncTextFromViewModel()
        }
        .onChange(of: appVM.activeDocEntry?.id) { _, _ in
            if !isFocused { syncTextFromViewModel() }
        }
        .onChange(of: appVM.selectedTableName) { _, _ in
            if !isFocused { syncTextFromViewModel() }
        }
        .onChange(of: activeTableVM?.sortColumn) { _, _ in
            if !isFocused { syncTextFromViewModel() }
        }
        .onChange(of: activeTableVM?.isSortDesc) { _, _ in
            if !isFocused { syncTextFromViewModel() }
        }
        .onChange(of: activeTableVM?.currentOffset) { _, _ in
            if !isFocused { syncTextFromViewModel() }
        }
        .onChange(of: activeTableVM?.filters) { _, _ in
            if !isFocused { syncTextFromViewModel() }
        }
        .onChange(of: appVM.isBanquetBarEditing) { _, editing in
            if editing {
                isFocused = true
            }
        }
        .onChange(of: isFocused) { _, focused in
            appVM.isBanquetBarEditing = focused
            if !focused {
                syncTextFromViewModel()
            }
        }
    }

    private func syncTextFromViewModel() {
        text = canonicalURL
    }

    private func submit() {
        isFocused = false
        appVM.isBanquetBarEditing = false
        appVM.openBanquet(urlString: text, activeTableVM: activeTableVM)
        syncTextFromViewModel()
    }

    private func revert() {
        isFocused = false
        appVM.isBanquetBarEditing = false
        syncTextFromViewModel()
    }
}
