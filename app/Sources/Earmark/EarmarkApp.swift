import AppKit
import SwiftUI

@main
struct EarmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Earmark", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Sound Library…") { model.chooseLibrary(.sounds) }
                    .keyboardShortcut("o")
                Button("Add Music Folder…") { model.chooseLibrary(.music) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Import Phase 0 Music Analysis…") { model.choosePhase0Import() }
                Divider()
                Button("Rescan All Folders") { model.rescanAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                Button("Sound Effects") { model.section = .sounds }
                    .keyboardShortcut("1")
                Button("Music") { model.section = .music }
                    .keyboardShortcut("2")
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Earmark") { model.showWelcome = true }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when Earmark runs as a plain executable (Xcode or `swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
