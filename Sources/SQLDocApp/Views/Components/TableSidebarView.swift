import SwiftUI
import SQLDocCore

/// Left navigator sidebar:
/// 1. Folder & SQLite Files Browser (grouped by subfolder, with 1-click switch to full Folder Explorer)
/// 2. Active Database Tables & Views with live row-count pills
public struct TableSidebarView: View {
    @ObservedObject var appVM: AppViewModel
    var palette: GridPalette
    @State private var filterText: String = ""
    @State private var showFolderFilesSection: Bool = true

    public init(appVM: AppViewModel, palette: GridPalette) {
        self.appVM = appVM
        self.palette = palette
    }

    private var allVisibleTables: [SQLDocCore.Table] {
        appVM.activeDocEntry?.doc.tables.filter { !$0.hidden } ?? []
    }

    private var filteredTables: [SQLDocCore.Table] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = allVisibleTables.filter { !$0.isView }
        guard !q.isEmpty else { return base }
        return base.filter { $0.name.lowercased().contains(q) || $0.label.lowercased().contains(q) }
    }

    private var filteredViews: [SQLDocCore.Table] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = allVisibleTables.filter { $0.isView }
        guard !q.isEmpty else { return base }
        return base.filter { $0.name.lowercased().contains(q) || $0.label.lowercased().contains(q) }
    }

    private var filteredFolderFiles: [SQLiteFileEntry] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return appVM.folderFiles }
        return appVM.folderFiles.filter {
            $0.name.lowercased().contains(q)
                || $0.relativeFolder.lowercased().contains(q)
                || $0.tables.contains(where: { $0.lowercased().contains(q) })
                || $0.views.contains(where: { $0.lowercased().contains(q) })
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Prominent "All SQLite Files & Folders" Switcher Button

            Divider()

            // 2. Unified Filter Box (filters tables, views, AND SQLite files in sidebar)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Filter tables, views, or .db files…", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !filterText.isEmpty {
                    Button(action: { filterText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // 3. Scrollable Tables, Views & Folder SQLite Files
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let activeEntry = appVM.activeDocEntry {
                        HStack {
                            Image(systemName: "cylinder.split.1x2.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                            Text(activeEntry.name.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 4)

                        if !filteredTables.isEmpty {
                            sectionHeader(title: "TABLES", count: filteredTables.count)
                            ForEach(filteredTables) { t in
                                tableRow(t)
                                    .padding(.horizontal, 8)
                            }
                        }

                        if !filteredViews.isEmpty {
                            sectionHeader(title: "VIEWS & PIPELINES", count: filteredViews.count)
                                .padding(.top, 6)
                            ForEach(filteredViews) { v in
                                tableRow(v)
                                    .padding(.horizontal, 8)
                            }
                        }
                    }

                    // 4. All SQLite Files in Current Folder (Grouped by Subfolder)
                    folderFilesTreeSection
                        .padding(.top, 8)
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 255)
        .background(palette.head)
        .overlay(Rectangle().frame(width: 1).foregroundColor(palette.rule), alignment: .trailing)
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func tableRow(_ t: SQLDocCore.Table) -> some View {
        let selected = appVM.selectedTableName == t.name && !appVM.isFolderBrowserVisible
        let est = appVM.activeDocEntry?.doc.estimateRows(for: t.name) ?? .unknown

        return Button {
            appVM.selectedTableName = t.name
            appVM.isFolderBrowserVisible = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.isView ? "eye.fill" : "tablecells")
                    .font(.system(size: 10))
                    .foregroundColor(selected ? .white : (t.isView ? .purple : .accentColor))
                    .frame(width: 14)

                Text(t.name)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(selected ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if est.known {
                    Text(Self.compactCount(est.rows))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(selected ? .white.opacity(0.9) : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12))
                        )
                } else if t.isView {
                    Text("VIEW")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(selected ? .white.opacity(0.9) : .purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selected ? Color.white.opacity(0.18) : Color.purple.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear)
            .cornerRadius(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.name)
    }

    // MARK: - Folder SQLite Files Tree in Sidebar

    @ViewBuilder
    private var folderFilesTreeSection: some View {
        let files = filteredFolderFiles
        if !files.isEmpty {
            Divider().padding(.vertical, 4)

            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showFolderFilesSection.toggle() } }) {
                HStack {
                    Image(systemName: showFolderFilesSection ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text("SQLITE FILES IN FOLDER")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(files.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFolderFilesSection {
                ForEach(files) { file in
                    let isCurrent = appVM.activeDocEntry?.path == file.path && !appVM.isFolderBrowserVisible
                    Button(action: {
                        appVM.open(path: file.path)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: isCurrent ? "cylinder.split.1x2.fill" : "externaldrive")
                                .font(.system(size: 10))
                                .foregroundColor(isCurrent ? .accentColor : .secondary)
                                .frame(width: 14)

                            HStack(spacing: 0) {
                                if file.relativeFolder != "." && !file.relativeFolder.isEmpty {
                                    Text(file.relativeFolder + "/")
                                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                        .foregroundColor(isCurrent ? .accentColor.opacity(0.8) : .secondary)
                                        .lineLimit(1)
                                }
                                Text(file.name)
                                    .font(.system(size: 11, weight: isCurrent ? .semibold : .medium, design: .monospaced))
                                    .foregroundColor(isCurrent ? .accentColor : .primary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            Text(BenchmarkRunner.formatBytes(file.size))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isCurrent ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .help(file.path)
                }
            }
        }
    }

    private static func compactCount(_ rows: Int64) -> String {
        if rows >= 1_000_000 {
            return String(format: "%.1fM", Double(rows) / 1_000_000.0)
        }
        if rows >= 10_000 {
            return String(format: "%.1fk", Double(rows) / 1_000.0)
        }
        return SQLiteValue.integer(rows).displayText
    }
}
