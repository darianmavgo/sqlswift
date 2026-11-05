import SwiftUI
import AppKit
import SQLDocCore

/// Top bar: navigator toggles, the Banquet URL field, and action buttons.
///
/// The URL field is always an editable text field — there is no separate
/// "display" mode. The grid is the source of truth: whenever anything that feeds
/// `AppViewModel.banquetURLString` changes, the field is rewritten (see
/// `BanquetAddressField.syncFromGrid`).
public struct BanquetBarView: View {
    @ObservedObject public var appVM: AppViewModel
    public var activeTableVM: TableViewModel?
    public var palette: GridPalette

    public init(appVM: AppViewModel, activeTableVM: TableViewModel? = nil, palette: GridPalette) {
        self.appVM = appVM
        self.activeTableVM = activeTableVM
        self.palette = palette
    }

    public var body: some View {
        HStack(spacing: 8) {
            leftNavigationCluster
            BanquetURLSource(appVM: appVM, tableVM: activeTableVM) { url in
                BanquetAddressField(appVM: appVM, tableVM: activeTableVM, url: url)
            }
            rightActionToolbar
        }
    }

    @ViewBuilder
    private var leftNavigationCluster: some View {
        HStack(spacing: 6) {
            toolbarIconButton(
                icon: "sidebar.left",
                label: nil,
                isActive: appVM.showSidebar,
                help: "Toggle Navigator Sidebar (⌥⌘S)"
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appVM.showSidebar.toggle()
                }
            }

            toolbarIconButton(
                icon: "folder.badge.plus",
                label: nil,
                isActive: false,
                help: "Open Folder… (⇧⌘O)"
            ) {
                appVM.showOpenFolderPanel()
            }
        }
    }

    @ViewBuilder
    private var rightActionToolbar: some View {
        HStack(spacing: 4) {
            if activeTableVM != nil {
                toolbarIconButton(
                    icon: "magnifyingglass",
                    label: nil,
                    isActive: appVM.isFindBarVisible,
                    help: "Find in Table (⌘F)"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appVM.isFindBarVisible.toggle()
                    }
                }

                toolbarIconButton(
                    icon: "info.circle",
                    label: "Schema",
                    isActive: appVM.showSchemaSheet,
                    help: "Inspect Table DDL & Indexes (⌘I)"
                ) {
                    appVM.showSchemaSheet = true
                }
            }

            if appVM.activeDocEntry != nil {
                toolbarIconButton(
                    icon: "terminal",
                    label: "SQL",
                    isActive: appVM.showQueryConsole,
                    help: "Open SQL Query Console (⇧⌘K)"
                ) {
                    appVM.showQueryConsole = true
                }
            }
        }
    }

    private func toolbarIconButton(
        icon: String,
        label: String?,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, label != nil ? 8 : 7)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.16) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor.opacity(0.6) : Color(NSColor.separatorColor).opacity(0.65), lineWidth: 1)
            )
            .foregroundColor(isActive ? .accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Grid → bar

/// Recomputes the canonical URL whenever the app or table view-model publishes
/// anything. Observing the objects directly (rather than a hand-kept list of
/// properties) is what keeps the bar from drifting behind the grid.
private struct BanquetURLSource<Content: View>: View {
    @ObservedObject var appVM: AppViewModel
    let tableVM: TableViewModel?
    let content: (String) -> Content

    var body: some View {
        if let tableVM {
            TableObservedURL(appVM: appVM, tableVM: tableVM, content: content)
        } else {
            content(appVM.banquetURLString(for: nil))
        }
    }
}

private struct TableObservedURL<Content: View>: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel
    let content: (String) -> Content

    var body: some View {
        content(appVM.banquetURLString(for: tableVM))
    }
}

// MARK: - The field

private struct BanquetAddressField: View {
    @ObservedObject var appVM: AppViewModel
    let tableVM: TableViewModel?
    /// Canonical URL for the grid's current state.
    let url: String

    @State private var text: String = ""
    @State private var lastSynced: String = ""
    @State private var liveApplyTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isFocused ? .accentColor : .secondary)
                .padding(.leading, 6)

            TextField("Banquet URL or SQLite path (e.g. 1/markov.db/equity_curve[0:100])", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .focused($isFocused)
                .onSubmit { submit() }
                .onExitCommand { revert() }
                .frame(maxWidth: .infinity)

            if let tableVM {
                TableTelemetryPillView(tableVM: tableVM)
            }

            copyURLButton

            if Bundle.main.bundleIdentifier == "com.mavgo.sqlswift.dev" {
                devBadge
            }
        }
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isFocused ? Color.accentColor : Color(NSColor.separatorColor).opacity(0.7),
                    lineWidth: isFocused ? 1.5 : 1.0
                )
        )
        .onChange(of: url, initial: true) { _, new in syncFromGrid(new) }
        .onChange(of: text, initial: true) { _, newValue in
            appVM.banquetBarText = newValue
            flattenNewlines(newValue)
            scheduleLiveApply(newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if appVM.isBanquetBarEditing != focused { appVM.isBanquetBarEditing = focused }
            // Leaving the field: whatever wasn't applied is dropped; the bar shows the grid.
            if !focused, text != lastSynced { text = lastSynced }
        }
        .onChange(of: appVM.isBanquetBarEditing) { _, editing in
            if isFocused != editing { isFocused = editing }
        }
        .onChange(of: appVM.banquetBarInjectedText) { _, injected in
            guard let injected else { return }
            // Focus first, text on the next turn: a real keystroke always arrives
            // in an already-focused field, and live-apply requires focus.
            isFocused = true
            appVM.banquetBarInjectedText = nil
            DispatchQueue.main.async { text = injected }
        }
        .onChange(of: appVM.banquetBarPendingPaste) { _, pending in
            guard let pending, !pending.isEmpty else { return }
            applyPaste(pending)
            appVM.banquetBarPendingPaste = nil
        }
    }

    /// The grid changed: show its URL. Skipped when the URL is unchanged so
    /// unrelated publishes (row counts, timings) never clobber what's being typed.
    private func syncFromGrid(_ new: String) {
        guard new != lastSynced else { return }
        // "Dirty" = text differs from the last grid URL. Blur resets it, so this only
        // happens mid-edit — and doesn't depend on window focus (which needn't be key).
        let wasDirty = text != lastSynced
        lastSynced = new
        // Don't rewrite text the user is in the middle of typing; the blur handler
        // restores the canonical form.
        if !wasDirty { text = new }
        UILog.event("bar", "sync from grid", ["url": new, "skippedWhileTyping": wasDirty])
    }

    // MARK: - Bar → grid

    /// Debounced: applies the typed URL to the open table once it is a complete,
    /// valid query for that table. Anything that would switch documents/tables or
    /// reference columns that don't exist yet waits for Return.
    private func scheduleLiveApply(_ value: String) {
        liveApplyTask?.cancel()
        guard value != lastSynced else { return }
        liveApplyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            liveApply(value)
        }
    }

    private func liveApply(_ value: String) {
        guard let tableVM, let entry = appVM.activeDocEntry,
              let b = try? BanquetParser.parse(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }

        let resolved = FolderScanner.resolveLocalPath(b.dataSetPath)
        let sameDoc = b.dataSetPath.isEmpty
            || entry.doc.path == resolved
            || (entry.doc.path as NSString).lastPathComponent == b.dataSetPath
        guard sameDoc, !b.isCollection, b.table == tableVM.tableName else { return }

        let known = Set(tableVM.rawColumns.map { $0.name.lowercased() })
        if let sort = b.sortColumn, !sort.isEmpty, !known.contains(sort.lowercased()) { return }
        if b.select != ["*"], b.select.contains(where: { !known.contains($0.lowercased()) }) { return }

        UILog.event("bar", "live apply", ["text": value])
        tableVM.applyBanquet(b)
    }

    private func flattenNewlines(_ value: String) {
        guard value.contains("\n") || value.contains("\r") else { return }
        text = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func applyPaste(_ pending: String) {
        let base = text
        if base.isEmpty || pending.hasPrefix(base) {
            text = pending
        } else if base.hasSuffix("/") {
            text = base + pending
        } else {
            text = base + "/" + pending
        }
        isFocused = true
    }

    private func submit() {
        isFocused = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let isStandaloneSQL = lower.hasPrefix("select ") || lower.hasPrefix("with ") || lower.hasPrefix("pragma ") || lower.hasPrefix("explain ")
        let resolvedURL: String
        if !isStandaloneSQL,
           !trimmed.hasPrefix("/"),
           !trimmed.hasPrefix("~"),
           !trimmed.contains("://"),
           !appVM.currentFolderPath.isEmpty {
            resolvedURL = appVM.currentFolderPath + "/" + trimmed
        } else {
            resolvedURL = trimmed
        }
        UILog.event("bar", "submit", ["text": trimmed])
        appVM.openBanquet(urlString: resolvedURL, activeTableVM: tableVM)
        let fresh = appVM.banquetURLString(for: tableVM)
        lastSynced = fresh
        text = fresh
    }

    private func revert() {
        UILog.event("bar", "cancel edit")
        isFocused = false
        text = lastSynced
    }

    private var copyURLButton: some View {
        Button(action: {
            appVM.copyBanquetURL(for: tableVM)
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
        .padding(.trailing, 5)
    }

    private var devBadge: some View {
        HStack(spacing: 2.5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
            Text("DEV")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color.orange.opacity(0.18))
        )
        .padding(.trailing, 6)
        .help("SqlSwift Development Instance (Hot-Reload active)")
    }
}

// MARK: - Row count / timing pill

private struct TableTelemetryPillView: View {
    @ObservedObject var tableVM: TableViewModel

    var body: some View {
        HStack(spacing: 5) {
            let rowCountText: String = {
                if tableVM.isCustomBanquetQuery, let count = tableVM.customQueryRowCount {
                    return "\(count) " + (count == 1 ? "row" : "rows")
                }
                return tableVM.tableCount.displayString + (tableVM.tableCount.rows == 1 ? " row" : " rows")
            }()
            Text(rowCountText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)

            if tableVM.lastTimingMicros > 0 {
                let us = tableVM.lastTimingMicros
                let label = us < 1000 ? "\(us) µs" : String(format: "%.1f ms", Double(us) / 1000.0)
                Text("⚡ \(label)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(us < 2000 ? .green : .secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}
