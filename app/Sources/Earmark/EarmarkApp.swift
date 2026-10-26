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
                .tint(.blue)
                .fixedMinimumSize(CGSize(width: 980, height: 600))
        }
        Settings {
            Preferences()
                .environment(model)
                .tint(.blue)
        }
        Window("Folder Categories", id: FolderMapView.windowID) {
            FolderMapView()
                .environment(model)
                .tint(.blue)
                .frame(minWidth: 900, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 680)
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
                Divider()
                MapFoldersButton()
            }
            CommandGroup(before: .toolbar) {
                Button("Sound Effects") { model.show(.sounds) }
                    .keyboardShortcut("1")
                Button("Music") { model.show(.music) }
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
        // "While you use the Mac" is in Preferences: set once, not every time.
    }
}

extension View {
    /// A fixed minimum size for a window's or a split view column's content. Otherwise SwiftUI
    /// works the minimum out by measuring every view, again after any change: with the detail
    /// pane's text (its grid) that was 10–20 ms, 40 times a second while something played
    /// (the playhead moves), so the main thread was always busy and animations dropped frames.
    /// This asks nothing of the content.
    func fixedMinimumSize(_ minimum: CGSize) -> some View {
        FixedMinimumLayout(minimum: minimum) { self }
    }
}

private struct FixedMinimumLayout: Layout {
    let minimum: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Smallest: the minimum; largest (an infinite proposal): unlimited; else what's offered.
        func length(_ proposed: CGFloat?, _ least: CGFloat) -> CGFloat {
            guard let proposed else { return least }
            return proposed.isInfinite ? proposed : max(proposed, least)
        }
        return CGSize(width: length(proposal.width, minimum.width), height: length(proposal.height, minimum.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    // No alignment guides of its own: by default a layout gets them by placing its content,
    // which measures all of it again (a stack around a split view column asks).
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
