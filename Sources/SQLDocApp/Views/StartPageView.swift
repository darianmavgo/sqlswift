import SwiftUI
import AppKit
import SQLDocCore

/// Full-featured Folder & SQLite Database Explorer shown on launch and whenever the user
/// opens a directory or clicks the "Folders & DBs" button in the toolbar.
public struct StartPageView: View {
    @ObservedObject var appVM: AppViewModel
    @State private var pathInput: String = ""
    @State private var expandedFilePaths: Set<String> = []
    @State private var previewTableByPath: [String: String] = [:]

    private var displayedFiles: [SQLiteFileEntry] {
        let q = appVM.folderSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = appVM.folderFiles.filter { entry in
            if let sub = appVM.selectedSubfolder, entry.relativeFolder != sub {
                return false
            }
            guard !q.isEmpty else { return true }
            if entry.name.lowercased().contains(q) { return true }
            if entry.relativeFolder.lowercased().contains(q) { return true }
            if entry.tables.contains(where: { $0.lowercased().contains(q) }) { return true }
            if entry.views.contains(where: { $0.lowercased().contains(q) }) { return true }
            return false
        }

        return appVM.folderSort.sorted(base)
    }

    private var totalBytesInView: Int64 {
        displayedFiles.reduce(0) { $0 + $1.size }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main List of SQLite Files
            if appVM.isScanningFolder && appVM.folderFiles.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning folder for SQLite databases…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedFiles.isEmpty {
                emptyFolderState
            } else {
                sqliteFilesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            pathInput = appVM.currentFolderPath
            if appVM.folderFiles.isEmpty && !appVM.currentFolderPath.isEmpty {
                appVM.openFolder(path: appVM.currentFolderPath, showBrowser: true)
            }
        }
        .onChange(of: appVM.currentFolderPath) { _, newPath in
            pathInput = newPath
        }
    }

    // MARK: - 1. Folder Header & Quick Presets

    private var folderHeaderBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("SQLite Folders & Databases")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                    Text("\(appVM.folderFiles.count) SQLite files across \(max(1, appVM.folderSummaries.count)) folders in \(appVM.currentFolderPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let activeDoc = appVM.activeDocEntry {
                    Button(action: { appVM.isFolderBrowserVisible = false }) {
                        HStack(spacing: 5) {
                            Image(systemName: "tablecells.fill")
                                .font(.system(size: 11))
                            Text("Back to \(activeDoc.name)")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Quick Folder Presets + Direct Folder Path Input
            HStack(spacing: 8) {
                // Up to parent directory button
                Button(action: {
                    let parent = (appVM.currentFolderPath as NSString).deletingLastPathComponent
                    if !parent.isEmpty && parent != appVM.currentFolderPath {
                        appVM.openFolder(path: parent, showBrowser: true)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                        Text("Parent")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Go to parent folder")

                // Preset workspace folders
                ForEach(AppViewModel.quickFolders(), id: \.path) { preset in
                    let isCurrent = appVM.currentFolderPath == preset.path
                    Button(action: {
                        appVM.openFolder(path: preset.path, showBrowser: true)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isCurrent ? "folder.fill" : "folder")
                                .font(.system(size: 10))
                            Text(preset.label)
                                .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isCurrent ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                        )
                        .foregroundColor(isCurrent ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(preset.path)
                }

                // Editable folder path field
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("Paste or type any folder or .db path…", text: $pathInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit {
                            if !pathInput.isEmpty {
                                appVM.open(path: pathInput)
                            }
                        }
                    Button("Go") {
                        if !pathInput.isEmpty {
                            appVM.open(path: pathInput)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor), lineWidth: 1))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
    }

    // MARK: - 2. Subfolder Filter Pills

    private var subfolderFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("FOLDERS:")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 2)

                let allSelected = appVM.selectedSubfolder == nil
                Button(action: { appVM.selectedSubfolder = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 10))
                        Text("All (\(appVM.folderFiles.count))")
                            .font(.system(size: 11, weight: allSelected ? .semibold : .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(allSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                    )
                    .foregroundColor(allSelected ? .white : .primary)
                }
                .buttonStyle(.plain)

                ForEach(appVM.folderSummaries) { summary in
                    let isSelected = appVM.selectedSubfolder == summary.relativeFolder
                    let label = summary.relativeFolder == "." ? "root (/)" : summary.relativeFolder
                    Button(action: {
                        if isSelected {
                            appVM.selectedSubfolder = nil
                        } else {
                            appVM.selectedSubfolder = summary.relativeFolder
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                            Text(label)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                            Text("\(summary.fileCount)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isSelected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.14))
                                )
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                        )
                        .foregroundColor(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .help("\(summary.folderPath) · \(BenchmarkRunner.formatBytes(summary.totalSize))")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 3. Search & Sort Bar

    private var filterAndSortBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("Filter by database name, subfolder, or table/view name (e.g. regime, markov, signal_trace, daily_bars)…", text: $appVM.folderSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !appVM.folderSearchQuery.isEmpty {
                    Button(action: { appVM.folderSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))

            Text("\(displayedFiles.count) files · \(BenchmarkRunner.formatBytes(totalBytesInView))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)

            Button(action: {
                appVM.openFolder(path: appVM.currentFolderPath, selectSubfolder: appVM.selectedSubfolder, showBrowser: true)
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor)))
            }
            .buttonStyle(.plain)
            .help("Rescan folder")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - 4. SQLite Files List

    // MARK: - 4a. Catalog table (default, banquet-db-list-style)

    private enum Col {
        static let folder: CGFloat = 150
        static let tables: CGFloat = 64
        static let views: CGFloat = 52
        static let modified: CGFloat = 118
        static let size: CGFloat = 84
        static let open: CGFloat = 64
    }

    /// One row per database, one column per property; the headers sort. Sort state is
    /// `appVM.folderSort`, the same state as the clause in the Banquet bar.
    private var catalogTable: some View {
        VStack(spacing: 0) {
            catalogHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayedFiles.enumerated()), id: \.element.id) { i, item in
                        catalogRow(item, striped: i % 2 == 1)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private var catalogHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 22, height: 1)
            headerCell("Name", .name, width: nil, align: .leading)
            headerCell("Folder", .location, width: Col.folder, align: .leading)
            headerCell("Tables", .tableCount, width: Col.tables, align: .trailing)
            Text("Views").frame(width: Col.views, alignment: .trailing)
            headerCell("Modified", .modified, width: Col.modified, align: .trailing)
            headerCell("Size", .size, width: Col.size, align: .trailing)
            Color.clear.frame(width: Col.open, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func headerCell(_ title: String, _ key: FolderSortKey, width: CGFloat?, align: Alignment) -> some View {
        let active = appVM.folderSort.key == key
        return Button {
            appVM.folderSort = appVM.folderSort.toggled(to: key)
        } label: {
            HStack(spacing: 3) {
                if align == .trailing { Spacer(minLength: 0) }
                Text(title)
                if active {
                    Image(systemName: appVM.folderSort.descending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                if align == .leading { Spacer(minLength: 0) }
            }
            .foregroundColor(active ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: align)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
        .help("Sort by \(title.lowercased()); click again to reverse")
    }

    private func catalogRow(_ item: SQLiteFileEntry, striped: Bool) -> some View {
        let isOpen = appVM.openDocuments.contains(where: { $0.path == item.path })
        let isCurrent = appVM.activeDocEntry?.path == item.path
        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "cylinder.split.1x2.fill" : "externaldrive.fill")
                .font(.system(size: 13))
                .foregroundColor(isCurrent ? .accentColor : (isOpen ? .green : .accentColor.opacity(0.85)))
                .frame(width: 22)
            HStack(spacing: 6) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                if isCurrent {
                    Text("ACTIVE")
                        .font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.2)))
                        .foregroundColor(.accentColor)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                appVM.selectedSubfolder = appVM.selectedSubfolder == item.relativeFolder ? nil : item.relativeFolder
            } label: {
                Text(item.relativeFolder == "." ? "root" : item.relativeFolder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .buttonStyle(.plain)
            .frame(width: Col.folder, alignment: .leading)
            .help("Filter to folder '\(item.relativeFolder)'")
            Text("\(item.tables.count)").frame(width: Col.tables, alignment: .trailing)
            Text("\(item.views.count)").frame(width: Col.views, alignment: .trailing)
            Text(item.modified > Date.distantPast ? Self.dateFormatter.string(from: item.modified) : "")
                .frame(width: Col.modified, alignment: .trailing)
            Text(BenchmarkRunner.formatBytes(item.size))
                .fontWeight(.semibold)
                .foregroundColor(item.size > 100_000_000 ? .orange : .primary)
                .frame(width: Col.size, alignment: .trailing)
            Button { appVM.open(path: item.path) } label: {
                HStack(spacing: 3) {
                    Text("Open").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .frame(width: Col.open, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isCurrent ? Color.accentColor.opacity(0.08)
                    : (striped ? Color(NSColor.controlBackgroundColor).opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { appVM.open(path: item.path) }
        .contextMenu { fileMenu(item) }
    }

    // MARK: - 4b. Catalog cards

    private var layoutPicker: some View {
        Picker("Layout", selection: $appVM.folderListStyle) {
            ForEach(FolderListStyle.allCases, id: \.self) { style in
                Text(style.rawValue).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 130)
        .help("Table: one column per property. Cards: each database as a catalog card.")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FolderSortKey.allCases, id: \.self) { key in
                Button {
                    appVM.folderSort = appVM.folderSort.key == key ? appVM.folderSort.toggled(to: key) : FolderSort(key: key)
                } label: {
                    if appVM.folderSort.key == key {
                        Label("\(key.label) \(appVM.folderSort.descending ? "↓" : "↑")", systemImage: "checkmark")
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            Text("Sort: \(appVM.folderSort.key.label)\(appVM.folderSort.key == .scan ? "" : (appVM.folderSort.descending ? " ↓" : " ↑"))")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Same as the sort clause in the Banquet bar")
    }

    /// One slim row above the list: layout, sort (cards only; the table sorts from its headers),
    /// totals, and the active folder filter.
    private var catalogToolbar: some View {
        HStack(spacing: 12) {
            layoutPicker
            if appVM.folderListStyle == .catalogCards { sortMenu }
            Text("\(displayedFiles.count) databases · \(BenchmarkRunner.formatBytes(totalBytesInView))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            if let sub = appVM.selectedSubfolder {
                Button { appVM.selectedSubfolder = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(sub == "." ? "root" : sub).font(.system(size: 11, design: .monospaced))
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.15)))
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Showing only this folder; click to show all")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private var sqliteFilesList: some View {
        VStack(spacing: 0) {
            catalogToolbar
            Divider()
            switch appVM.folderListStyle {
            case .catalogTable: catalogTable
            case .catalogCards: catalogCards
            }
        }
    }

    private var catalogCards: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(displayedFiles) { item in
                    sqliteFileRow(item)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func sqliteFileRow(_ item: SQLiteFileEntry) -> some View {
        let isOpen = appVM.openDocuments.contains(where: { $0.path == item.path })
        let isCurrent = appVM.activeDocEntry?.path == item.path

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Database Icon
                Image(systemName: isCurrent ? "cylinder.split.1x2.fill" : "externaldrive.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isCurrent ? .accentColor : (isOpen ? .green : .accentColor.opacity(0.85)))
                    .frame(width: 22)

                // Subfolder Pill (clickable to filter or drill into subfolder)
                Button(action: {
                    if appVM.selectedSubfolder == item.relativeFolder {
                        appVM.selectedSubfolder = nil
                    } else {
                        appVM.selectedSubfolder = item.relativeFolder
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(item.relativeFolder == "." ? "root" : item.relativeFolder)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Filter to folder '\(item.relativeFolder)'")

                // Database File Name (click to open)
                Button(action: {
                    appVM.open(path: item.path)
                }) {
                    Text(item.name)
                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)

                if isCurrent {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.2)))
                        .foregroundColor(.accentColor)
                }

                Spacer()

                // Object count summary
                if item.totalObjects > 0 {
                    Text("\(item.tables.count) tables · \(item.views.count) views")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Modified Date
                if item.modified > Date.distantPast {
                    Text(Self.dateFormatter.string(from: item.modified))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 115, alignment: .trailing)
                }

                // File Size
                Text(BenchmarkRunner.formatBytes(item.size))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(item.size > 100_000_000 ? .orange : .primary)
                    .frame(width: 82, alignment: .trailing)

                // Inline Peek Toggle Button
                if item.totalObjects > 0 {
                    let isExpanded = expandedFilePaths.contains(item.path)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if isExpanded {
                                expandedFilePaths.remove(item.path)
                            } else {
                                expandedFilePaths.insert(item.path)
                            }
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: isExpanded ? "chevron.up" : "eye")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(isExpanded ? "Hide" : "Peek")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isExpanded ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                        .foregroundColor(isExpanded ? .accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .help("Peek inside \(item.name) inline without leaving the folder list")
                }

                // Open Button
                Button(action: {
                    appVM.open(path: item.path)
                }) {
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }

            // Second line: Clickable Table & View Pills inside this SQLite file!
            if !item.tables.isEmpty || !item.views.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(item.tables.prefix(12), id: \.self) { tbl in
                            Button(action: {
                                appVM.open(path: item.path, targetTable: tbl)
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "tablecells")
                                        .font(.system(size: 8.5))
                                    Text(tbl)
                                        .font(.system(size: 10.5, design: .monospaced))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.1)))
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(item.name) directly at table '\(tbl)'")
                        }

                        ForEach(item.views.prefix(10), id: \.self) { vw in
                            Button(action: {
                                appVM.open(path: item.path, targetTable: vw)
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "eye.fill")
                                        .font(.system(size: 8.5))
                                    Text(vw)
                                        .font(.system(size: 10.5, design: .monospaced))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.12)))
                                .foregroundColor(.purple)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(item.name) directly at view '\(vw)'")
                        }

                        let remaining = (item.tables.count + item.views.count) - (min(12, item.tables.count) + min(10, item.views.count))
                        if remaining > 0 {
                            Text("+\(remaining) more")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 32)
                }
            }

            // Third section: Expandable Inline Table Preview!
            if expandedFilePaths.contains(item.path) {
                InlineDatabasePeekView(
                    item: item,
                    selectedTable: Binding(
                        get: { previewTableByPath[item.path] ?? item.tables.first ?? item.views.first ?? "" },
                        set: { previewTableByPath[item.path] = $0 }
                    ),
                    onOpenFull: { tbl in
                        appVM.open(path: item.path, targetTable: tbl)
                    }
                )
                .padding(.leading, 32)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            appVM.open(path: item.path)
        }
        .contextMenu { fileMenu(item) }
    }

    @ViewBuilder
    private func fileMenu(_ item: SQLiteFileEntry) -> some View {
        Button("Open Database") {
            appVM.open(path: item.path)
        }
        Button("Browse Enclosing Folder (\(item.relativeFolder))") {
            appVM.openFolder(path: item.folderPath, showBrowser: true)
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
        Button("Copy Full File Path") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(item.path, forType: .string)
        }
    }

    private var emptyFolderState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(appVM.folderSearchQuery.isEmpty
                 ? "No SQLite files (.db, .sqlite, .sqlite3) found in this folder."
                 : "No SQLite files match '\(appVM.folderSearchQuery)'.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                if !appVM.folderSearchQuery.isEmpty || appVM.selectedSubfolder != nil {
                    Button("Clear Filter") {
                        appVM.folderSearchQuery = ""
                        appVM.selectedSubfolder = nil
                    }
                }
                Button("Choose Another Folder…") {
                    appVM.showOpenFolderPanel()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm"
        return df
    }()
}

// MARK: - Inline Expandable Database Peek View

private struct InlineDatabasePeekView: View {
    let item: SQLiteFileEntry
    @Binding var selectedTable: String
    let onOpenFull: (String) -> Void

    @State private var previewPage: Page?
    @State private var orderedCols: [Column] = []
    @State private var rowCount: TableCount = .unknown

    private var allObjects: [String] {
        item.tables + item.views
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("PREVIEW:")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary)

                ForEach(allObjects.prefix(8), id: \.self) { obj in
                    let active = selectedTable == obj
                    Button(action: {
                        selectedTable = obj
                        loadPreview(table: obj)
                    }) {
                        Text(obj)
                            .font(.system(size: 10.5, weight: active ? .semibold : .regular, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.12))
                            )
                            .foregroundColor(active ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if rowCount.known {
                    Text("\(rowCount.displayString) rows")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button(action: { onOpenFull(selectedTable) }) {
                    Text("Open '\(selectedTable)' Full View ↗")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }

            if let page = previewPage, !page.rows.isEmpty {
                let colsToShow = Array((orderedCols.isEmpty ? page.columns : orderedCols).prefix(8))
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        ForEach(colsToShow) { col in
                            Text(col.name)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: col.isNumeric ? .trailing : .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                    .background(Color.secondary.opacity(0.1))

                    Divider()

                    // First 5 rows
                    ForEach(Array(page.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(colsToShow) { col in
                                let colIdx = page.columns.firstIndex(where: { $0.name == col.name }) ?? 0
                                let val = colIdx < row.count ? row[colIdx] : .null
                                let kind = CellFormat.kind(forColumn: col.name, isNumeric: col.isNumeric)
                                let text = CellFormat.pretty(value: val, kind: kind) ?? val.displayText
                                let tone = CellFormat.tone(value: val, kind: kind)

                                Text(val.isNull ? "NULL" : text)
                                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                                    .foregroundColor(
                                        val.isNull ? .secondary.opacity(0.6) :
                                        (tone == .positive ? Color(red: 0.06, green: 0.62, blue: 0.38) :
                                         (tone == .negative ? Color(red: 0.86, green: 0.24, blue: 0.24) : .primary))
                                    )
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: col.isNumeric ? .trailing : .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                        }
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 1))
            } else {
                Text("Loading preview…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.windowBackgroundColor).opacity(0.7)))
        .onAppear {
            loadPreview(table: selectedTable)
        }
    }

    private func loadPreview(table: String) {
        guard !table.isEmpty else { return }
        let path = item.path
        Task.detached(priority: .userInitiated) {
            guard let doc = try? Doc.open(path: path) else { return }
            defer { doc.close() }
            let count = doc.estimateRows(for: table)
            let page = try? doc.rows(window: Window(table: table, limit: 5))
            let ordered = page.map { QueryStyle.orderColumns(columns: $0.columns) } ?? []
            await MainActor.run {
                self.rowCount = count
                self.previewPage = page
                self.orderedCols = ordered
            }
        }
    }
}
