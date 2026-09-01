import SwiftUI
import SQLDocCore
import UniformTypeIdentifiers

public struct MainView: View {
    @ObservedObject public var appVM: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var tableVMCache: [String: TableViewModel] = [:]
    @State private var activeTableVM: TableViewModel?

    public init(appVM: AppViewModel = AppViewModel()) {
        self._appVM = ObservedObject(wrappedValue: appVM)
    }

    private var palette: GridPalette {
        let accent = appVM.activeDocEntry.map { AppTheme.color(from: $0.doc.style.accent) } ?? .accentColor
        return GridPalette.resolve(dark: colorScheme == .dark, accent: accent)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Banquet Address Bar
            BanquetBarView(appVM: appVM, activeTableVM: activeTableVM, palette: palette)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)

            if let activeTableVM, appVM.showFilterBar, !appVM.isGalleryView {
                FilterBarView(tableVM: activeTableVM, palette: palette)
            }

            HStack(spacing: 0) {
                if appVM.showSidebar, appVM.activeDocEntry != nil {
                    TableSidebarView(appVM: appVM, palette: palette)
                }
                contentArea
            }

            // Status Bar
            if let activeTableVM {
                StatusBarView(appVM: appVM, tableVM: activeTableVM)
            }
        }
        .accentColor(appVM.activeDocEntry != nil ? AppTheme.color(from: appVM.activeDocEntry!.doc.style.accent) : Color.accentColor)
        .preferredColorScheme(appVM.effectiveColorScheme)
        .onAppear { syncActiveTableVM() }
        .onChange(of: appVM.selectedTableName) { _, _ in syncActiveTableVM() }
        .onChange(of: appVM.activeDocEntry?.id) { _, _ in syncActiveTableVM() }
        .sheet(item: $appVM.inspectingCell) { info in
            DataInspectorView(info: info) { appVM.inspectingCell = nil }
                .padding()
                .frame(minWidth: 540, minHeight: 400)
        }
        .sheet(isPresented: $appVM.showSchemaSheet) {
            if let entry = appVM.activeDocEntry, !appVM.selectedTableName.isEmpty {
                SchemaSheetView(doc: entry.doc, tableName: appVM.selectedTableName) {
                    appVM.showSchemaSheet = false
                }
            }
        }
        .sheet(isPresented: $appVM.showQueryConsole) {
            if let entry = appVM.activeDocEntry {
                QueryConsoleView(doc: entry.doc, seedTable: appVM.selectedTableName) {
                    appVM.showQueryConsole = false
                }
            }
        }
        .sheet(isPresented: $appVM.showJumpToRow) {
            if let activeTableVM {
                JumpToRowView(tableVM: activeTableVM) { appVM.showJumpToRow = false }
            }
        }
        .onDrop(of: [.fileURL, .data], isTargeted: $appVM.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .alert("Error", isPresented: Binding(
            get: { appVM.errorMessage != nil },
            set: { if !$0 { appVM.errorMessage = nil } }
        )) {
            Button("OK") { appVM.errorMessage = nil }
        } message: {
            Text(appVM.errorMessage ?? "")
        }
    }

    private var contentArea: some View {
        ZStack {
            ZStack {
                if appVM.activeDocEntry != nil {
                    if appVM.isGalleryView {
                        GalleryView(appVM: appVM)
                    } else if let activeTableVM {
                        VirtualizedGridView(appVM: appVM, tableVM: activeTableVM)
                    } else {
                        ProgressView("Loading schema…")
                    }
                } else {
                    StartPageView(appVM: appVM)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if appVM.isDropTargeted {
                ZStack {
                    Color.black.opacity(0.4)
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 48)).foregroundColor(.white)
                        Text("Drop a file to open")
                            .font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                    }
                    .padding(32)
                    .background(Color.accentColor.opacity(0.9))
                    .cornerRadius(16)
                }
                .transition(.opacity)
            }

            if appVM.isBusy {
                BusyOverlayView(
                    title: appVM.busyTitle,
                    message: appVM.busyMessage,
                    progress: appVM.busyProgress,
                    onCancel: appVM.cancelBusyAction
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if appVM.isFindBarVisible, let activeTableVM {
                FindBarView(tableVM: activeTableVM) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        appVM.isFindBarVisible = false
                        activeTableVM.cancelFind()
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 14)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
    }


    /// Resolves the table view-model for the current doc + table selection.
    /// Runs from lifecycle callbacks, never during `body` evaluation, and evicts
    /// view-models for databases that are no longer open (freeing their pages and
    /// background observers).
    private func syncActiveTableVM() {
        let openIDs = Set(appVM.openDocuments.map { $0.id })
        for (key, vm) in tableVMCache where !openIDs.contains(String(key.split(separator: ":").first ?? "")) {
            vm.dispose()
            tableVMCache.removeValue(forKey: key)
        }

        guard let entry = appVM.activeDocEntry, !appVM.selectedTableName.isEmpty else {
            activeTableVM = nil
            return
        }
        let key = "\(entry.id):\(appVM.selectedTableName)"
        if let existing = tableVMCache[key] {
            activeTableVM = existing
            return
        }
        let vm = TableViewModel(doc: entry.doc, tableName: appVM.selectedTableName, docID: entry.id)
        tableVMCache[key] = vm
        activeTableVM = vm
    }


    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let fileURL = url {
                        Task { @MainActor in
                            appVM.open(url: fileURL)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}
