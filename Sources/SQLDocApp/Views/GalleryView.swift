import SwiftUI
import SQLDocCore

public struct GalleryView: View {
    @ObservedObject var appVM: AppViewModel

    public var body: some View {
        guard let doc = appVM.activeDocEntry?.doc else {
            return AnyView(EmptyView())
        }

        let visibleTables = doc.tables.filter { !$0.hidden }

        return AnyView(
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 540), spacing: 16)], spacing: 16) {
                    ForEach(visibleTables) { table in
                        GalleryTableCard(
                            doc: doc,
                            table: table,
                            zoomScale: appVM.zoomScale,
                            onSelect: {
                                appVM.selectedTableName = table.name
                                appVM.isGalleryView = false
                            }
                        )
                    }
                }
                .padding(20)
            }
            .background(Color(NSColor.windowBackgroundColor))
        )
    }
}

public struct GalleryTableCard: View {
    let doc: Doc
    let table: SQLDocCore.Table
    let zoomScale: Double
    let onSelect: () -> Void

    @State private var samplePage: Page?
    @State private var rowCount: TableCount = .unknown

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: table.isView ? "eye" : "tablecells")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 13))

                Text(table.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                if table.isView {
                    Text("VIEW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }

                Spacer()

                Text(rowCount.displayString + " rows")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Mini table preview
            if let page = samplePage, !page.rows.isEmpty {
                VStack(spacing: 0) {
                    // Mini header
                    HStack(spacing: 0) {
                        ForEach(page.columns.prefix(4)) { col in
                            Text(col.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                    Divider()

                    // Mini rows
                    ForEach(Array(page.rows.prefix(4).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.prefix(4).enumerated()), id: \.offset) { _, cell in
                                Text(cell.displayText)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                            }
                        }
                        Divider()
                    }
                }
            } else {
                Text("Loading preview…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(16)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onAppear {
            self.rowCount = doc.count(for: table.name)
            if let p = try? doc.rows(window: Window(table: table.name, limit: 4)) {
                self.samplePage = p
            }
        }
    }
}
