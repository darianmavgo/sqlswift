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

            CommandGroup(after: .textEditing) {
                Button("Find in Table…") {
                    appVM.isFindBarVisible.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appVM.activeDocEntry == nil)
            }

            CommandGroup(after: .toolbar) {
                Button("Toggle Gallery View") {
                    appVM.isGalleryView.toggle()
                }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(appVM.activeDocEntry == nil)

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

final class AppDelegate: NSObject, NSApplicationDelegate {
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
