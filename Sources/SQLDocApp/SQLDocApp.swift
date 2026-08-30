import SwiftUI
import AppKit
import SQLDocCore

@main
struct SQLDocApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appVM = AppViewModel()

    var body: some Scene {
        WindowGroup {
            MainView(appVM: appVM)
                .frame(minWidth: 700, minHeight: 450)
                .onOpenURL { url in
                    appVM.open(url: url)
                }
                .onAppear {
                    // Maximize window to fill screen on launch (matching fillScreen behavior)
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                            if let screen = window.screen ?? NSScreen.main {
                                window.setFrame(screen.visibleFrame, display: true, animate: false)
                            }
                        }
                    }

                    // Check if files were passed via command line arguments
                    let cliArgs = Array(CommandLine.arguments.dropFirst())
                    for arg in cliArgs where !arg.hasPrefix("-") {
                        let path = (arg as NSString).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: path) {
                            appVM.open(path: path)
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppIdentity.displayName)") { Self.showAboutPanel() }
            }

            // Help menu: version line + one-click copy for bug reports.
            CommandGroup(replacing: .help) {
                Button("\(AppIdentity.displayName) \(BuildInfo.summary)") { Self.showAboutPanel() }
                Button("Copy Version Info") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString("\(AppIdentity.displayName) \(AppIdentity.version) · \(BuildInfo.detail)", forType: .string)
                }
                Divider()
                Button("Project Homepage") {
                    if let url = URL(string: AppIdentity.homepage) { NSWorkspace.shared.open(url) }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Database…") {
                    appVM.showOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Export Table as CSV…") {
                    appVM.exportCurrentTable()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)

                Button("Close Database") {
                    appVM.closeCurrentDoc()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Paste File Path to Open") {
                    appVM.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Find in Table…") {
                    appVM.isFindBarVisible.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)

                Button("Filter Columns") {
                    appVM.showFilterBar.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(appVM.activeDocEntry == nil)

                Button("Jump to Row…") {
                    appVM.showJumpToRow = true
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)
            }

            CommandGroup(after: .toolbar) {
                Button("Table Schema…") {
                    appVM.showSchemaSheet = true
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(appVM.selectedTableName.isEmpty)

                Button("Query Console…") {
                    appVM.showQueryConsole = true
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(appVM.activeDocEntry == nil)

                Button("Toggle Table Sidebar") {
                    appVM.showSidebar.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(appVM.activeDocEntry == nil)

                Divider()

                Button("Toggle Gallery View") {
                    appVM.isGalleryView.toggle()
                }
                .keyboardShortcut("g", modifiers: [.option, .command])
                .disabled(appVM.activeDocEntry == nil)

                Divider()

                Menu("Appearance") {
                    Button("Match System") {
                        appVM.setThemeMode(.system)
                    }
                    Button("Light Mode") {
                        appVM.setThemeMode(.light)
                    }
                    Button("Dark Mode") {
                        appVM.setThemeMode(.dark)
                    }
                }

                Divider()

                Button("Zoom In") {
                    appVM.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    appVM.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    appVM.zoomReset()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

extension SQLDocApp {
    /// Standard macOS About panel, populated with the marketing version and the
    /// exact build revision.
    static func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.displayName,
            .applicationVersion: AppIdentity.version,
            .version: "\(BuildInfo.commit)\(BuildInfo.dirty ? " (modified)" : "")",
            .init(rawValue: "Copyright"): AppIdentity.copyright,
            .credits: NSAttributedString(
                string: "\(AppIdentity.tagline)\n\n\(BuildInfo.detail)",
                attributes: [.font: NSFont.systemFont(ofSize: 10)]
            )
        ])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure window bounds to screen visible frame on launch
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true, animate: false)
                }
            }
        }
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let path = (filename as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                Task { @MainActor in
                    _ = try? SessionManager.shared.open(path: path)
                }
            }
        }
    }
}
