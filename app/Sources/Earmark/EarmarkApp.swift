import AppKit
import EarmarkCore
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
            CommandMenu("Analysis") { AnalysisMenu(analysis: model.analysis) }
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

/// The Analysis menu. Titles are fixed: menu commands don't reliably refresh when
/// the engine's state changes, so nothing here depends on it except the picker.
struct AnalysisMenu: View {
    let analysis: AnalysisEngine

    var body: some View {
        Button("Pause Analysis") { analysis.mode = .paused }
            .keyboardShortcut("p", modifiers: [.command, .option])
        Button("Resume Analysis") { analysis.mode = .automatic }
            .keyboardShortcut("r", modifiers: [.command, .option])
        Button("Run at Full Speed Now") { analysis.mode = .fullSpeed }
        Divider()
        Picker("While You Use the Mac", selection: Binding(
            get: { analysis.mode == .idleOnly ? AnalysisGovernor.Mode.idleOnly : .automatic },
            set: { analysis.mode = $0 }
        )) {
            Text("Keep Analysing Gently").tag(AnalysisGovernor.Mode.automatic)
            Text("Wait Until the Mac Is Idle").tag(AnalysisGovernor.Mode.idleOnly)
        }
    }
}
