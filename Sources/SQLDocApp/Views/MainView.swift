import SwiftUI
import Combine
import SQLDocCore
import UniformTypeIdentifiers

public struct MainView: View {
    @ObservedObject public var appVM: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeTableVM: TableViewModel?
    @State private var uiCommands = UICommandRunner()

    public init(appVM: AppViewModel = AppViewModel()) {
        self._appVM = ObservedObject(wrappedValue: appVM)
    }

    private var palette: GridPalette {
        let accent = appVM.activeDocEntry.map { AppTheme.color(from: $0.doc.style.accent) } ?? .accentColor
        return GridPalette.resolve(dark: colorScheme == .dark, accent: accent)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Unified Title Bar + Banquet Toolbar (Browser / Xcode Style)
            HStack(spacing: 8) {
                BanquetBarView(appVM: appVM, activeTableVM: activeTableVM, palette: palette)
                if appVM.isFindBarVisible, let activeTableVM {
                    FindBarView(tableVM: activeTableVM) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            appVM.isFindBarVisible = false
                            activeTableVM.cancelFind()
                        }
                    }
                    .transition(.opacity)
                }
            }
                .padding(.leading, 76) // Clear macOS traffic lights (🔴 🟡 🟢)
                .padding(.trailing, 10)
                .padding(.top, 5)
                .padding(.bottom, 6)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)
                .zIndex(10) // the suggestion dropdown hangs below the bar, over the content

            HStack(spacing: 0) {
                if appVM.showSidebar, appVM.activeDocEntry != nil {
                    TableSidebarView(appVM: appVM, palette: palette)
                }
                contentArea
            }

            // Status Bar
            if let activeTableVM, !appVM.isFolderBrowserVisible {
                StatusBarView(appVM: appVM, tableVM: activeTableVM)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .accentColor(appVM.activeDocEntry != nil ? AppTheme.color(from: appVM.activeDocEntry!.doc.style.accent) : Color.accentColor)
        .preferredColorScheme(appVM.effectiveColorScheme)
        .onAppear {
            syncActiveTableVM()
            uiCommands.start(appVM: appVM)
            // banquet-bar-style rule 2: the bar is focused on launch.
            DispatchQueue.main.async { appVM.isBanquetBarEditing = true }
        }
        // Debounced so a burst of view-model changes writes one snapshot.
        .onReceive(appVM.objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
            guard UILog.isEnabled else { return }
            UILog.writeSnapshot(appVM.uiStateSnapshot())
        }
        .onChange(of: appVM.selectedTableName) { _, _ in
            appVM.isTableListVisible = false   // picking a table in the sidebar leaves the list
            syncActiveTableVM()
        }
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
        HStack(spacing: 0) {
            gridArea
            if appVM.showRowDetail, appVM.isThinTable, !appVM.isFolderBrowserVisible,
               let activeTableVM {
                RowDetailPanel(appVM: appVM, tableVM: activeTableVM)
            }
        }
    }

    private var gridArea: some View {
        ZStack {
            ZStack {
                if appVM.isFolderBrowserVisible || appVM.activeDocEntry == nil {
                    StartPageView(appVM: appVM)
                } else if appVM.isTableListVisible, let entry = appVM.activeDocEntry {
                    TableListView(doc: entry.doc)
                } else if let activeTableVM {
                    VirtualizedGridView(appVM: appVM, tableVM: activeTableVM)
                } else if appVM.activeDocEntry?.doc.tables.isEmpty == true {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 38))
                            .foregroundColor(.secondary)
                        Text("This database has no tables or views.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ProgressView("Loading schema…")
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
    }


    /// The lifecycle logic lives in `AppViewModel.syncActiveTableVM` (so tests can
    /// drive it); this just mirrors the result into view state.
    private func syncActiveTableVM() {
        appVM.syncActiveTableVM()
        activeTableVM = appVM.activeTableVM
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
