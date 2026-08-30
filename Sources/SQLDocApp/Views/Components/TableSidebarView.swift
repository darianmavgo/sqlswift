import SwiftUI
import SQLDocCore

/// Optional left list of tables/views. Off by default (⌥⌘S) — the titlebar
/// picker is still the primary switcher.
public struct TableSidebarView: View {
    @ObservedObject var appVM: AppViewModel
    var palette: GridPalette

    public init(appVM: AppViewModel, palette: GridPalette) {
        self.appVM = appVM
        self.palette = palette
    }

    public var body: some View {
        let tables = appVM.activeDocEntry?.doc.tables.filter { !$0.hidden } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            Text("TABLES")
                .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(tables) { t in
                        row(t)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(width: 200)
        .background(palette.head)
        .overlay(Rectangle().frame(width: 1).foregroundColor(palette.rule), alignment: .trailing)
    }

    private func row(_ t: SQLDocCore.Table) -> some View {
        let selected = appVM.selectedTableName == t.name && !appVM.isGalleryView
        return Button {
            appVM.selectedTableName = t.name
            appVM.isGalleryView = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.isView ? "eye" : "tablecells")
                    .font(.system(size: 10))
                    .foregroundColor(selected ? .white : .secondary)
                Text(t.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .white : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
