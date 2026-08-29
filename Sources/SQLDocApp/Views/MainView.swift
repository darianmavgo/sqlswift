import SwiftUI
import SQLDocCore
import UniformTypeIdentifiers

public struct MainView: View {
    @ObservedObject public var appVM: AppViewModel
    @State private var tableVMs: [String: TableViewModel] = [:]

    public init(appVM: AppViewModel = AppViewModel()) {
        self._appVM = ObservedObject(wrappedValue: appVM)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Navigation Bar
            topBarView

            // Main Content Area (Grid / Gallery / Start with Floating Find Bar)
            ZStack(alignment: .topTrailing) {
                if appVM.activeDocEntry != nil {
                    if appVM.isGalleryView {
                        GalleryView(appVM: appVM)
                    } else if let activeTableVM = currentTableVM {
                        VirtualizedGridView(appVM: appVM, tableVM: activeTableVM)
                    } else {
                        ProgressView("Loading schema…")
                    }
                } else {
                    StartPageView(appVM: appVM)
                }

                // Floating Find Bar Overlay matching sqldoc
                if appVM.isFindBarVisible, let activeTableVM = currentTableVM {
                    FindBarView(tableVM: activeTableVM) {
                        withAnimation(.easeOut(duration: 0.15)) {
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
                    .zIndex(30)
                }

                // Drop Overlay
                if appVM.isDropTargeted {
                    ZStack {
                        Color.black.opacity(0.4)
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.white)
                            Text("Drop SQLite Database to Open")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(32)
                        .background(Color.accentColor.opacity(0.9))
                        .cornerRadius(16)
                    }
                    .transition(.opacity)
                }

                // Busy Progress Overlay
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status Bar
            if let activeTableVM = currentTableVM {
                StatusBarView(appVM: appVM, tableVM: activeTableVM)
            }
        }
        .accentColor(appVM.activeDocEntry != nil ? AppTheme.color(from: appVM.activeDocEntry!.doc.style.accent) : Color.accentColor)
        .preferredColorScheme(appVM.effectiveColorScheme)
        .sheet(item: $appVM.inspectingCell) { info in
            DataInspectorView(info: info) {
                appVM.inspectingCell = nil
            }
            .padding()
            .frame(minWidth: 540, minHeight: 400)
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

    private var currentTableVM: TableViewModel? {
        guard let entry = appVM.activeDocEntry, !appVM.selectedTableName.isEmpty else { return nil }
        let key = "\(entry.id):\(appVM.selectedTableName)"
        if let existing = tableVMs[key] {
            return existing
        }
        let vm = TableViewModel(doc: entry.doc, tableName: appVM.selectedTableName, docID: entry.id)
        tableVMs[key] = vm
        return vm
    }

    private var topBarView: some View {
        HStack(spacing: 8) {
            // Home / Open Button
            Button(action: { appVM.showOpenPanel() }) {
                Image(systemName: "house")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Open database (⌘O)")

            // Document Tabs / Picker
            if !appVM.openDocuments.isEmpty {
                Menu {
                    ForEach(appVM.openDocuments) { doc in
                        Button(action: { appVM.selectDoc(id: doc.id) }) {
                            HStack {
                                Text(doc.name)
                                if doc.id == appVM.activeDocEntry?.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 11))
                        Text(appVM.activeDocEntry?.name ?? "Databases")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 180)

                Button(action: { appVM.closeCurrentDoc() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close this database (⌘W)")

                Divider().frame(height: 16)
            }

            // Table Selector
            if let entry = appVM.activeDocEntry {
                let tables = entry.doc.tables.filter { !$0.hidden }
                Picker("", selection: $appVM.selectedTableName) {
                    ForEach(tables) { table in
                        Text(table.label + (table.isView ? " (view)" : "")).tag(table.name)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                // Gallery Button
                Button(action: { appVM.isGalleryView.toggle() }) {
                    Image(systemName: appVM.isGalleryView ? "tablecells" : "square.grid.2x2")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(appVM.isGalleryView ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help("Toggle multi-table gallery overview (⌘G)")

                Spacer()

                // Find Button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appVM.isFindBarVisible.toggle()
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(appVM.isFindBarVisible ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help("Find in table (⌘F)")

                // Zoom controls
                Button(action: { appVM.zoomOut() }) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Zoom out (⌘−)")

                Button(action: { appVM.zoomIn() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Zoom in (⌘+)")

                // Theme Menu
                Menu {
                    Button("System Appearance") {
                        appVM.setThemeMode(.system)
                    }
                    Button("Light Mode") {
                        appVM.setThemeMode(.light)
                    }
                    Button("Dark Mode") {
                        appVM.setThemeMode(.dark)
                    }
                } label: {
                    Image(systemName: appVM.themeMode == .dark ? "moon.fill" : (appVM.themeMode == .light ? "sun.max.fill" : "circle.lefthalf.filled"))
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .help("Change Theme")

                // CSV Export Button
                Button(action: { appVM.exportCurrentTable() }) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Export this table as CSV (⌘E)")
            } else {
                Spacer()

                // Theme Menu on start page
                Menu {
                    Button("System Appearance") {
                        appVM.setThemeMode(.system)
                    }
                    Button("Light Mode") {
                        appVM.setThemeMode(.light)
                    }
                    Button("Dark Mode") {
                        appVM.setThemeMode(.dark)
                    }
                } label: {
                    Image(systemName: appVM.themeMode == .dark ? "moon.fill" : (appVM.themeMode == .light ? "sun.max.fill" : "circle.lefthalf.filled"))
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .help("Change Theme")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
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
