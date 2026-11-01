import SwiftUI
import AppKit
import Combine
import SQLDocCore

/// Unified Top Navigation, Banquet URL Bar, Display Mode Switcher, and 1-Click Action Toolbar.
public struct BanquetBarView: View {
    @ObservedObject public var appVM: AppViewModel
    public var activeTableVM: TableViewModel?
    public var palette: GridPalette

    @State private var text: String = ""
    @State private var isEditingURL: Bool = false
    @State private var didCancelEditing: Bool = false
    @State private var tableVMRevision: UInt64 = 0
    @FocusState private var isFocused: Bool

    public init(appVM: AppViewModel, activeTableVM: TableViewModel? = nil, palette: GridPalette) {
        self.appVM = appVM
        self.activeTableVM = activeTableVM
        self.palette = palette
    }

    private var canonicalURL: String {
        appVM.banquetURLString(for: activeTableVM)
    }

    /// Edit text is the full absolute URL so what you see is what you copy.
    private var compactDisplayURL: String {
        canonicalURL
    }

    public var body: some View {
        HStack(spacing: 8) {
            leftNavigationCluster
            banquetAddressField
            rightActionToolbar
        }
        .background(
            NavigationChangeObserver(
                appVM: appVM,
                isEditingURL: isEditingURL,
                onChange: syncTextFromViewModel
            )
        )
        .background(
            TableChangeObserver(
                activeTableVM: activeTableVM,
                isEditingURL: isEditingURL,
                tableVMRevision: $tableVMRevision,
                onChange: syncTextFromViewModel
            )
        )
        .background(
            EditingChangeObserver(
                appVM: appVM,
                isEditingURL: $isEditingURL,
                text: $text,
                didCancelEditing: $didCancelEditing,
                isFocused: $isFocused,
                compactDisplayURL: compactDisplayURL,
                canonicalURL: canonicalURL,
                syncTextFromViewModel: syncTextFromViewModel,
                beginEditingURL: beginEditingURL
            )
        )
    }

    @ViewBuilder
    private var leftNavigationCluster: some View {
        HStack(spacing: 6) {
            // Left Sidebar Toggle
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
            if let _ = activeTableVM {
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

    private func beginEditingURL() {
        didCancelEditing = false
        if !isEditingURL {
            let base = compactDisplayURL.isEmpty ? canonicalURL : compactDisplayURL
            text = base
            isEditingURL = true
        }
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    // MARK: - Hybrid Clickable + Editable Banquet URL Bar

    @ViewBuilder
    private var banquetAddressField: some View {
        HStack(spacing: 4) {
            if isEditingURL {
                editingAddressField
            } else {
                tokenAddressField
            }

            copyURLButton

            if Bundle.main.bundleIdentifier == "com.mavgo.sqlswift.dev" {
                devBadge
            }
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isEditingURL ? Color.accentColor : Color(NSColor.separatorColor).opacity(0.7),
                    lineWidth: isEditingURL ? 1.5 : 1.0
                )
        )
    }

    @ViewBuilder
    private var editingAddressField: some View {
        Image(systemName: "pencil.line")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.leading, 8)

        TextField("Banquet URL or SQLite path (e.g. 1/markov.db/equity_curve[0:100])", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .focused($isFocused)
            .onSubmit { submit() }
            .onExitCommand { revert() }
            .frame(maxWidth: .infinity)

        Button(action: { submit() }) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .help("Navigate to Banquet URL (Return)")
    }

    @ViewBuilder
    private var tokenAddressField: some View {
        HStack(spacing: 2) {
            folderTokenSegment

            if let entry = appVM.activeDocEntry {
                tableLevelTokens(entry: entry)
            }

        }
        .padding(.leading, 6)
        .fixedSize(horizontal: false, vertical: false)

        Color.clear
            .frame(minWidth: 16, maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.iBeam.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture {
                beginEditingURL()
            }
            .help("Click anywhere in the bar (or press ⌘L or /) to edit Banquet URL")

        if let tableVM = activeTableVM {
            TableTelemetryPillView(tableVM: tableVM)
                .onTapGesture { beginEditingURL() }
        }
    }

    @ViewBuilder
    private func tableLevelTokens(entry: DocEntry) -> some View {
        let relFolder = relativeSubfolder(for: entry.path)
        if !relFolder.isEmpty {
            slashDivider
            subfolderTokenSegment(relFolder)
        }

        slashDivider
        DatabaseTokenMenu(appVM: appVM, entry: entry, activeTableVM: activeTableVM)

        slashDivider
        TableTokenMenu(appVM: appVM, entry: entry, activeTableVM: activeTableVM)

        if let tableVM = activeTableVM {
            TableQueryTokensView(
                appVM: appVM,
                tableVM: tableVM,
                onEditURL: { beginEditingURL() }
            )
        }
    }

    private var copyURLButton: some View {
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

    // MARK: - Interactive Path & Query Token Helpers

    private var slashDivider: some View {
        Button(action: { beginEditingURL() }) {
            Text("/")
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.65))
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to edit Banquet URL")
    }

    private var folderTokenSegment: some View {
        let folderName = appVM.currentFolderPath.isEmpty ? "Folders" : appVM.currentFolderPath
        let isBrowserActive = appVM.isFolderBrowserVisible || appVM.activeDocEntry == nil
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                if appVM.currentFolderPath.isEmpty {
                    appVM.showOpenFolderPanel()
                } else if appVM.activeDocEntry != nil {
                    appVM.selectedSubfolder = nil
                    appVM.isFolderBrowserVisible.toggle()
                } else {
                    appVM.selectedSubfolder = nil
                    appVM.isFolderBrowserVisible = true
                }
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isBrowserActive ? .white : .accentColor)
                Text(folderName)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(isBrowserActive ? .white : .primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isBrowserActive ? Color.accentColor : Color.secondary.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("View All \(appVM.folderFiles.count) SQLite Files in '\(folderName)'") {
                appVM.selectedSubfolder = nil
                appVM.isFolderBrowserVisible = true
            }
            Button("Switch Workspace Folder…") {
                appVM.showOpenFolderPanel()
            }
            Button("Edit Banquet URL Text…") {
                beginEditingURL()
            }
        }
        .help("Click to browse all \(appVM.folderFiles.count) SQLite files in \(appVM.currentFolderPath.isEmpty ? "folder" : appVM.currentFolderPath) (right-click to switch folder)")
    }

    private func relativeSubfolder(for dbPath: String) -> String {
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
        let root = appVM.currentFolderPath
        guard !root.isEmpty, dir.hasPrefix(root) else { return "" }
        let rel = String(dir.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel
    }

    private func subfolderTokenSegment(_ subfolder: String) -> some View {
        let isSelectedSub = appVM.isFolderBrowserVisible && appVM.selectedSubfolder == subfolder
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                if appVM.isFolderBrowserVisible && appVM.selectedSubfolder == subfolder && appVM.activeDocEntry != nil {
                    appVM.isFolderBrowserVisible = false
                } else {
                    appVM.selectedSubfolder = subfolder
                    appVM.isFolderBrowserVisible = true
                }
            }
        }) {
            Text(subfolder)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(isSelectedSub ? .white : .secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelectedSub ? Color.accentColor : Color.secondary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            let dbsInSub = appVM.folderFiles.filter { $0.relativeFolder == subfolder }
            if !dbsInSub.isEmpty {
                Section("SQLite Files in '\(subfolder)' (\(dbsInSub.count))") {
                    ForEach(dbsInSub) { dbFile in
                        Button(dbFile.name) {
                            appVM.open(path: dbFile.path, targetTable: appVM.selectedTableName.isEmpty ? nil : appVM.selectedTableName)
                        }
                    }
                }
                Divider()
            }
            if !appVM.folderSummaries.isEmpty {
                Section("Switch Subfolder") {
                    ForEach(appVM.folderSummaries) { summary in
                        Button("\(summary.relativeFolder.isEmpty ? "(root)" : summary.relativeFolder) (\(summary.fileCount))") {
                            appVM.selectedSubfolder = summary.relativeFolder.isEmpty ? nil : summary.relativeFolder
                            appVM.isFolderBrowserVisible = true
                        }
                    }
                }
            }
        }
        .help("Click to view all SQLite files in '\(subfolder)' (right-click for quick DB list)")
    }

    // MARK: - Toolbar Button Helper

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

    private func syncTextFromViewModel() {
        text = isEditingURL ? canonicalURL : compactDisplayURL
    }

    private func submit() {
        isFocused = false
        isEditingURL = false
        appVM.isBanquetBarEditing = false
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
        appVM.openBanquet(urlString: resolvedURL, activeTableVM: activeTableVM)
        syncTextFromViewModel()
    }

    private func revert() {
        didCancelEditing = true
        isFocused = false
        isEditingURL = false
        appVM.isBanquetBarEditing = false
        syncTextFromViewModel()
    }
}

// MARK: - Live Observed Table Query, Slice [start:end], and Parameter Tokens

private struct TableQueryTokensView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var tableVM: TableViewModel
    let onEditURL: () -> Void
    @State private var showSlicePopover: Bool = false

    private var slashDivider: some View {
        Button(action: { onEditURL() }) {
            Text("/")
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.65))
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to edit Banquet URL")
    }

    private var explicitSelectColumns: [String] {
        if !tableVM.hiddenColumns.isEmpty {
            return tableVM.columns.filter { !tableVM.hiddenColumns.contains($0.name) }.map(\.name)
        }
        if tableVM.banquetSelect != ["*"] && !tableVM.banquetSelect.isEmpty {
            return tableVM.banquetSelect
        }
        return []
    }

    var body: some View {
        let start = Int(tableVM.currentOffset)
        let end = start + tableVM.pageLimit
        let sliceText = "[\(start):\(end)]"

        HStack(spacing: 2) {
            // 1. Sort & Column Projection Path Modifier (`/-col,col1,col2`)
            if tableVM.sortColumn != nil || !explicitSelectColumns.isEmpty {
                slashDivider
                if let sortCol = tableVM.sortColumn {
                    Button(action: {
                        tableVM.sortBy(column: sortCol)
                    }) {
                        Text((tableVM.isSortDesc ? "-" : "+") + sortCol)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Flip Sort Direction (\(tableVM.isSortDesc ? "ASC" : "DESC"))") {
                            tableVM.sortBy(column: sortCol)
                        }
                        Button("Clear Sort") {
                            tableVM.setSort(column: nil, desc: false)
                        }
                    }
                    .help("Sorted by \(sortCol) (\(tableVM.isSortDesc ? "DESC" : "ASC")) — click to flip, right-click to clear")
                }

                if !explicitSelectColumns.isEmpty {
                    let colsLabel = explicitSelectColumns.joined(separator: ",")
                    Button(action: onEditURL) {
                        Text(tableVM.sortColumn != nil ? ",\(colsLabel)" : colsLabel)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 180)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Show All Columns (*)") {
                            tableVM.banquetSelect = ["*"]
                            tableVM.showAllColumns()
                        }
                        Button("Edit Columns in URL…") {
                            onEditURL()
                        }
                    }
                    .help("Projected columns: \(colsLabel)")
                }
            }

            // 2. Banquet Slice Notation `[start:end]` (Pure SwiftUI Button + Popover so it never truncates!)
            Button(action: {
                showSlicePopover.toggle()
            }) {
                Text(sliceText)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .popover(isPresented: $showSlicePopover, arrowEdge: .bottom) {
                let nextStart = start + Int(tableVM.currentPage?.rows.count ?? tableVM.pageLimit)
                let nextEnd = nextStart + tableVM.pageLimit
                let prevStart = max(0, start - tableVM.pageLimit)
                let prevEnd = prevStart + tableVM.pageLimit

                VStack(alignment: .leading, spacing: 8) {
                    Text("BANQUET SLICE \(sliceText)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        Button("⇤ [0:\(tableVM.pageLimit)]") {
                            appVM.paginateFirst(tableVM: tableVM)
                        }
                        .disabled(start <= 0)

                        Button("◀ [\(prevStart):\(prevEnd)]") {
                            appVM.paginatePrevious(tableVM: tableVM)
                        }
                        .disabled(start <= 0)

                        Button("[\(nextStart):\(nextEnd)] ▶") {
                            appVM.paginateNext(tableVM: tableVM)
                        }

                        Button("Last ⇥") {
                            appVM.paginateLast(tableVM: tableVM)
                        }
                    }
                    .controlSize(.small)

                    Divider()

                    HStack(spacing: 6) {
                        Text("Page size:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        ForEach([50, 100, 250, 500], id: \.self) { size in
                            Button("\(size)") {
                                appVM.executeBanquetSlice(offset: Int64(start), limit: size, tableVM: tableVM)
                                showSlicePopover = false
                            }
                            .buttonStyle(.bordered)
                            .tint(tableVM.pageLimit == size ? .accentColor : .secondary)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    Button("Edit Raw Banquet URL…") {
                        showSlicePopover = false
                        onEditURL()
                    }
                    .controlSize(.small)
                }
                .padding(10)
            }
            .contextMenu {
                Button("Next Slice (Page Down)") { appVM.paginateNext(tableVM: tableVM) }
                Button("Previous Slice (Page Up)") { appVM.paginatePrevious(tableVM: tableVM) }
                    .disabled(start <= 0)
                Button("First Slice [0:\(tableVM.pageLimit)]") { appVM.paginateFirst(tableVM: tableVM) }
                    .disabled(start <= 0)
                Divider()
                ForEach([50, 100, 250, 500], id: \.self) { size in
                    Button("Slice Size: \(size) rows") {
                        appVM.executeBanquetSlice(offset: Int64(start), limit: size, tableVM: tableVM)
                    }
                }
            }
            .help("Banquet row slice \(sliceText) — click to paginate or change slice size")

            // 3. Query Parameters (`?where=...`, `&groupby=...`, `&having=...`)
            let b = appVM.banquet(for: tableVM)
            if let whereClause = b.whereClause, !whereClause.isEmpty {
                Button(action: onEditURL) {
                    Text("?where=\(whereClause)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.orange.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit in URL…") { onEditURL() }
                    Button("Clear WHERE / Filters") { tableVM.clearFilters() }
                }
                .help("Active WHERE clause — click to edit in URL, right-click to clear")
            }

            if let groupBy = b.groupBy, !groupBy.isEmpty {
                Button(action: onEditURL) {
                    Text("\(b.whereClause == nil ? "?" : "&")groupby=\(groupBy)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.purple.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit in URL…") { onEditURL() }
                    Button("Clear groupby") { tableVM.banquetGroupBy = nil }
                }
            }

            if let having = b.having, !having.isEmpty {
                Button(action: onEditURL) {
                    Text("&having=\(having)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.purple.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit in URL…") { onEditURL() }
                    Button("Clear having") { tableVM.banquetHaving = nil }
                }
            }

            let effectiveExtras = !tableVM.extraQueryParams.isEmpty ? tableVM.extraQueryParams : appVM.extraQueryParams
            ForEach(effectiveExtras, id: \.self) { extra in
                let hasWhere = (b.whereClause != nil && !b.whereClause!.isEmpty)
                let hasGroupBy = (b.groupBy != nil && !b.groupBy!.isEmpty)
                let hasHaving = (b.having != nil && !b.having!.isEmpty)
                let isFirst = !hasWhere && !hasGroupBy && !hasHaving && (effectiveExtras.first == extra)
                CustomQueryParamTokenView(
                    param: extra,
                    isFirstQueryParam: isFirst,
                    onEdit: onEditURL,
                    onRemove: {
                        tableVM.removeExtraQueryParam(extra)
                        appVM.extraQueryParams.removeAll { $0 == extra }
                    }
                )
            }
        }
    }
}

private struct CustomQueryParamTokenView: View {
    let param: String
    let isFirstQueryParam: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let prefix = isFirstQueryParam ? "?" : "&"
        Button(action: onEdit) {
            Text("\(prefix)\(param)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.teal)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.teal.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Parameter in URL…") { onEdit() }
            Divider()
            Button("Remove Parameter '\(param)'") { onRemove() }
        }
        .help("Custom parameter \(prefix)\(param) — click to edit in URL, right-click to remove")
    }
}

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

// MARK: - Inline Database & Table Token Menus inside Banquet Bar

private struct DatabaseTokenMenu: View {
    @ObservedObject var appVM: AppViewModel
    let entry: DocEntry
    var activeTableVM: TableViewModel?

    var body: some View {
        let currentTable = appVM.selectedTableName
        let siblingMatches = appVM.folderFiles.filter {
            !currentTable.isEmpty && ($0.tables.contains(currentTable) || $0.views.contains(currentTable))
        }

        Menu {
            if siblingMatches.count > 1 {
                Section("Compare '\(currentTable)' Across Databases (\(siblingMatches.count))") {
                    ForEach(siblingMatches) { dbFile in
                        Button {
                            appVM.open(path: dbFile.path, targetTable: currentTable)
                        } label: {
                            Label(
                                dbFile.relativePath,
                                systemImage: dbFile.path == entry.path ? "checkmark.circle.fill" : "arrow.left.arrow.right.square"
                            )
                        }
                    }
                }
                Divider()
            }

            if !appVM.folderFiles.isEmpty {
                Section("All SQLite Files in Folder (\(appVM.folderFiles.count))") {
                    ForEach(appVM.folderFiles) { dbFile in
                        Button {
                            appVM.open(path: dbFile.path, targetTable: currentTable.isEmpty ? nil : currentTable)
                        } label: {
                            Label(
                                "\(dbFile.relativePath) (\(BenchmarkRunner.formatBytes(dbFile.size)))",
                                systemImage: dbFile.path == entry.path ? "checkmark" : "cylinder.split.1x2"
                            )
                        }
                    }
                }
                Divider()
            }

            Button("Browse All SQLite Files & Folders…") {
                appVM.isFolderBrowserVisible = true
            }
            Button("Open Another Database…") {
                appVM.showOpenPanel()
            }
        } label: {
            HStack(spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.11))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("Click to switch SQLite database file (\(entry.path))")
    }
}

private struct TableTokenMenu: View {
    @ObservedObject var appVM: AppViewModel
    let entry: DocEntry
    var activeTableVM: TableViewModel?

    var body: some View {
        let visibleTables = entry.doc.tables.filter { !$0.hidden }
        let currentObj = visibleTables.first(where: { $0.name == appVM.selectedTableName })
        let isView = currentObj?.isView ?? false

        Menu {
            let tablesOnly = visibleTables.filter { !$0.isView }
            if !tablesOnly.isEmpty {
                Section("Tables (\(tablesOnly.count))") {
                    ForEach(tablesOnly) { t in
                        let est = entry.doc.estimateRows(for: t.name)
                        let suffix = est.known ? " (\(est.displayString))" : ""
                        Button {
                            appVM.selectedTableName = t.name
                            appVM.isFolderBrowserVisible = false
                        } label: {
                            Label(t.name + suffix, systemImage: appVM.selectedTableName == t.name ? "checkmark" : "tablecells")
                        }
                    }
                }
            }

            let viewsOnly = visibleTables.filter { $0.isView }
            if !viewsOnly.isEmpty {
                Section("Views (\(viewsOnly.count))") {
                    ForEach(viewsOnly) { v in
                        Button {
                            appVM.selectedTableName = v.name
                            appVM.isFolderBrowserVisible = false
                        } label: {
                            Label(v.name, systemImage: appVM.selectedTableName == v.name ? "checkmark" : "eye")
                        }
                    }
                }
            }
        } label: {
            let tableTitle = appVM.selectedTableName.isEmpty ? "Select Table" : appVM.selectedTableName
            HStack(spacing: 3) {
                Text(tableTitle)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(isView ? .purple : .accentColor)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isView ? .purple.opacity(0.8) : .accentColor.opacity(0.8))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill((isView ? Color.purple : Color.accentColor).opacity(0.13))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("Click to switch table or view in \(entry.name)")
    }
}

// MARK: - Dedicated Banquet Bar Synchronization Observers

private struct NavigationChangeObserver: View {
    @ObservedObject var appVM: AppViewModel
    let isEditingURL: Bool
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                onChange()
            }
            .onChange(of: appVM.activeDocEntry?.id) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: appVM.selectedTableName) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: appVM.isFolderBrowserVisible) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: appVM.selectedSubfolder) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: appVM.folderSortOrder) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: appVM.folderSearchQuery) { _, _ in
                if !isEditingURL { onChange() }
            }
    }
}

private struct TableChangeObserver: View {
    var activeTableVM: TableViewModel?
    let isEditingURL: Bool
    @Binding var tableVMRevision: UInt64
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: activeTableVM?.sortColumn) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: activeTableVM?.isSortDesc) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: activeTableVM?.currentOffset) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onChange(of: activeTableVM?.filters) { _, _ in
                if !isEditingURL { onChange() }
            }
            .onReceive(
                activeTableVM?.objectWillChange.eraseToAnyPublisher()
                    ?? Empty<ObservableObjectPublisher.Output, Never>().eraseToAnyPublisher()
            ) { _ in
                Task { @MainActor in
                    tableVMRevision &+= 1
                    if !isEditingURL {
                        onChange()
                    }
                }
            }
    }
}

private struct EditingChangeObserver: View {
    @ObservedObject var appVM: AppViewModel
    @Binding var isEditingURL: Bool
    @Binding var text: String
    @Binding var didCancelEditing: Bool
    @FocusState.Binding var isFocused: Bool
    let compactDisplayURL: String
    let canonicalURL: String
    let syncTextFromViewModel: () -> Void
    let beginEditingURL: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: text) { _, newValue in
                if newValue.contains("\n") || newValue.contains("\r") {
                    let flattened = newValue
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if flattened != newValue {
                        text = flattened
                    }
                }
            }
            .onChange(of: appVM.banquetBarPendingPaste) { _, pending in
                guard let pending, !pending.isEmpty else { return }
                didCancelEditing = false
                if isEditingURL {
                    if text.isEmpty || text.hasSuffix("/") {
                        text += pending
                    } else {
                        text += "/" + pending
                    }
                } else {
                    let base = compactDisplayURL.isEmpty ? canonicalURL : compactDisplayURL
                    if base.isEmpty || pending.hasPrefix(base) {
                        text = pending
                    } else if base.hasSuffix("/") {
                        text = base + pending
                    } else {
                        text = base + "/" + pending
                    }
                    isEditingURL = true
                }
                appVM.banquetBarPendingPaste = nil
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            .onChange(of: appVM.isBanquetBarEditing) { _, editing in
                if editing && !isEditingURL {
                    beginEditingURL()
                }
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    appVM.isBanquetBarEditing = true
                } else {
                    if didCancelEditing {
                        didCancelEditing = false
                        isEditingURL = false
                        appVM.isBanquetBarEditing = false
                        syncTextFromViewModel()
                    } else if isEditingURL {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed == compactDisplayURL || trimmed == canonicalURL {
                            isEditingURL = false
                            appVM.isBanquetBarEditing = false
                            syncTextFromViewModel()
                        }
                    }
                }
            }
    }
}
