import AppKit
import EarmarkCore
import SwiftUI

// MARK: shortcuts

/// The keyboard shortcuts (owner, 2026-10-26), each defined once: the menus use them and
/// Help ▸ Keyboard Shortcuts lists them.
enum Shortcuts {
    static let stop = KeyboardShortcut(".")
    static let showNowPlaying = KeyboardShortcut("l")
    static let autoplay = KeyboardShortcut("a", modifiers: [.command, .shift])
    static let search = KeyboardShortcut("f")
    static let findMatches = KeyboardShortcut("f", modifiers: [.command, .shift])
    static let showInFinder = KeyboardShortcut("r")
    static let addToResolve = KeyboardShortcut("t")
    static let copyPath = KeyboardShortcut("c", modifiers: [.command, .option])
    static let doubleTempo = KeyboardShortcut(.upArrow, modifiers: [.command, .option])
    static let halveTempo = KeyboardShortcut(.downArrow, modifiers: [.command, .option])
    static let relativeKey = KeyboardShortcut("k", modifiers: [.command, .option])

    /// How far ← and → move what's playing, seconds (Shift: `more`). Sound effects are short.
    static func skip(sound: Bool, more: Bool) -> TimeInterval {
        sound ? (more ? 5 : 1) : (more ? 15 : 5)
    }

    /// "⌥⌘↑", as menus write it.
    static func text(_ s: KeyboardShortcut) -> String {
        let m = s.modifiers
        var out = ""
        if m.contains(.control) { out += "⌃" }
        if m.contains(.option) { out += "⌥" }
        if m.contains(.shift) { out += "⇧" }
        if m.contains(.command) { out += "⌘" }
        switch s.key {
        case .upArrow: out += "↑"
        case .downArrow: out += "↓"
        case .leftArrow: out += "←"
        case .rightArrow: out += "→"
        case .space: out += "Space"
        case .return: out += "↩"
        default: out += String(s.key.character).uppercased()
        }
        return out
    }
}

// MARK: actions

extension AppModel {
    /// ← / → in a list: moves what's playing or paused back or forward; nothing when nothing is
    /// (the key then goes to the list). Returns whether it moved.
    func skip(forward: Bool, more: Bool) -> Bool {
        guard let url = player.url, player.isActive(url) else { return false }
        let step = Shortcuts.skip(sound: playingSound != nil, more: more)
        player.skip(by: forward ? step : -step)
        return true
    }

    /// Selects what's playing in its list and scrolls to it.
    func showNowPlaying() {
        switch section {
        case .sounds: if let sound = playingSound { soundBrowser.reveal(sound.id) }
        case .music: if let song = playingSong { musicBrowser.reveal(song.id) }
        }
    }

    /// Auto-play on or off for the section on screen (each has its own, as the toolbar button).
    func toggleAutoplay() {
        let key = switchSection == .music ? "autoplayMusic" : "autoplaySounds"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    /// The files selected in the section on screen.
    var selectedURLs: [URL] {
        switch section {
        case .sounds: soundBrowser.selection.compactMap { sound(id: $0)?.url }
        case .music: musicBrowser.selection.compactMap { song(id: $0)?.url }
        }
    }

    /// The one selected sound or song, or its waveform selection, onto Resolve's timeline.
    func addSelectionToResolve() {
        let urls = selectedURLs
        guard urls.count == 1, let url = urls.first else { return }
        let range = playerSelection.flatMap { $0.url == url ? $0.range : nil }
        addToResolve(url, range: range)
    }

    func showSelectionInFinder() {
        let urls = selectedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copySelectionPaths() {
        let paths = selectedURLs.map(\.path)
        if !paths.isEmpty { copyToPasteboard(paths.joined(separator: "\n")) }
    }

    /// Find Similar Sounds, or Find Songs That Mix With This, for the one selected item.
    func findMatchesForSelection() {
        switch section {
        case .sounds:
            if soundBrowser.selection.count == 1, let s = sound(id: soundBrowser.selection.first ?? nil) { findSimilar(to: s) }
        case .music:
            if musicBrowser.selection.count == 1, let s = song(id: musicBrowser.selection.first ?? nil),
               s.key != nil || s.bpm != nil { musicBrowser.findMixes(for: s) }
        }
    }

    /// A tempo or key correction for the selected songs, from the Song menu (Edit ▸ Undo takes it back).
    func editSelectedSongs(_ edit: SongEdit) {
        guard section == .music else { return }
        self.edit(edit, songs: Array(musicBrowser.selection), undo: Self.mainWindow?.undoManager)
    }

    /// Puts the keyboard in the toolbar's search field.
    func focusSearch() {
        guard let window = Self.mainWindow else { return }
        if let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
            return
        }
        func field(in view: NSView) -> NSSearchField? {
            if let f = view as? NSSearchField { return f }
            for v in view.subviews { if let f = field(in: v) { return f } }
            return nil
        }
        if let root = window.contentView?.superview, let f = field(in: root) { window.makeFirstResponder(f) }
    }

    static var mainWindow: NSWindow? { NSApp.windows.first { $0.title == "Earmark" && $0.contentView != nil } }
}

// MARK: menus

/// Playback: what's playing, wherever the keyboard is.
struct PlaybackMenu: View {
    let model: AppModel

    var body: some View {
        Button("Stop") { model.player.stop() }
            .keyboardShortcut(Shortcuts.stop)
        Button("Show Now Playing") { model.showNowPlaying() }
            .keyboardShortcut(Shortcuts.showNowPlaying)
        Divider()
        Button("Auto-play On or Off") { model.toggleAutoplay() }
            .keyboardShortcut(Shortcuts.autoplay)
    }
}

/// Song: corrections by hand for the selected songs (the detail pane's and list's Change menus).
struct SongMenu: View {
    let model: AppModel

    var body: some View {
        Button("Double Tempo") { model.editSelectedSongs(.doubleTempo) }
            .keyboardShortcut(Shortcuts.doubleTempo)
        Button("Halve Tempo") { model.editSelectedSongs(.halveTempo) }
            .keyboardShortcut(Shortcuts.halveTempo)
        Button("Use Relative Key") { model.editSelectedSongs(.relativeKey) }
            .keyboardShortcut(Shortcuts.relativeKey)
        Divider()
        Button("Revert to Analysed Values") { model.editSelectedSongs(.revertAll) }
    }
}

/// File ▸ Show in Finder and Edit ▸ Copy Path, Search, Find Similar: for the selection.
struct SelectionCommands: View {
    let model: AppModel
    let part: Part

    enum Part { case file, pasteboard, find }

    var body: some View {
        switch part {
        case .file:
            Button("Show in Finder") { model.showSelectionInFinder() }
                .keyboardShortcut(Shortcuts.showInFinder)
            Button("Add to DaVinci Resolve Timeline") { model.addSelectionToResolve() }
                .keyboardShortcut(Shortcuts.addToResolve)
        case .pasteboard:
            Button("Copy Path") { model.copySelectionPaths() }
                .keyboardShortcut(Shortcuts.copyPath)
        case .find:
            Button("Search") { model.focusSearch() }
                .keyboardShortcut(Shortcuts.search)
            Button(model.switchSection == .music ? "Find Songs That Mix With This" : "Find Similar Sounds") {
                model.findMatchesForSelection()
            }
            .keyboardShortcut(Shortcuts.findMatches)
        }
    }
}

/// Help: the welcome sheet and the shortcuts page.
struct HelpMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Welcome to Earmark") { model.showWelcome = true }
        Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.windowID) }
        Divider()
        Button("Connect an AI Agent…") { openWindow(id: ConnectAgentView.windowID) }
    }
}

// MARK: Help ▸ Keyboard Shortcuts

/// Every shortcut on one page, the list's own keys too (menus can't show bare Space and arrows
/// without taking them from the search field).
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"

    private struct Group: Identifiable {
        var title: String
        var rows: [(keys: String, what: String)]
        var id: String { title }
    }

    private static func s(_ k: KeyboardShortcut) -> String { Shortcuts.text(k) }

    private let groups: [Group] = [
        Group(title: "In the List", rows: [
            ("Space  ↩", "Play or pause (double-click too)"),
            ("↑ ↓", "Previous or next row"),
            ("← →", "Back or forward \(Int(Shortcuts.skip(sound: false, more: false))) s in a song, "
                + "\(Int(Shortcuts.skip(sound: true, more: false))) s in a sound effect"),
            ("⇧← ⇧→", "Back or forward \(Int(Shortcuts.skip(sound: false, more: true))) s in a song, "
                + "\(Int(Shortcuts.skip(sound: true, more: true))) s in a sound effect"),
        ]),
        Group(title: "On the Sound Map", rows: [
            ("Click", "Select a sound (double-click plays or pauses it)"),
            ("⌘-click  ⇧-click", "Add a sound to the selection, or take it out"),
            ("Drag", "Select the sounds in an area"),
            ("Space  ↩  ← →", "Play or pause, back or forward, as in the list"),
            ("Pinch  Scroll wheel", "Zoom (⌘ and two fingers on a trackpad)"),
            ("Two fingers  ⌥-drag", "Move around"),
            ("Esc", "Clear the selection"),
        ]),
        Group(title: "Playback", rows: [
            (s(Shortcuts.stop), "Stop and go back to the start"),
            (s(Shortcuts.showNowPlaying), "Show what's playing in its list"),
            (s(Shortcuts.autoplay), "Auto-play on or off"),
        ]),
        Group(title: "Selection", rows: [
            (s(Shortcuts.search), "Search"),
            (s(Shortcuts.findMatches), "Find similar sounds, or songs that mix with the selected song"),
            (s(Shortcuts.showInFinder), "Show in Finder"),
            (s(Shortcuts.addToResolve), "Add to the DaVinci Resolve timeline at its playhead (the waveform's selection, or all)"),
            (s(Shortcuts.copyPath), "Copy path"),
        ]),
        Group(title: "Songs", rows: [
            (s(Shortcuts.doubleTempo), "Double tempo"),
            (s(Shortcuts.halveTempo), "Halve tempo"),
            (s(Shortcuts.relativeKey), "Use the relative key"),
            ("⌘Z  ⇧⌘Z", "Undo or redo a correction"),
        ]),
        Group(title: "Window", rows: [
            ("⌘1  ⌘2", "Sound effects or music"),
            ("⇧⌘M", "Sound effects as a map or a list"),
            ("⌘O  ⇧⌘O", "Add a sound library or a music folder"),
            ("⇧⌘R", "Rescan all folders"),
            ("⌥⌘P  ⌥⌘R", "Pause or resume analysis"),
        ]),
    ]

    var body: some View {
        // Sized to its content, the whole list showing (the window follows it).
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(groups) { group in
                GridRow {
                    Text(group.title).font(.headline).gridCellColumns(2)
                }
                .padding(.top, group.id == groups.first?.id ? 0 : 10)
                ForEach(group.rows, id: \.what) { row in
                    GridRow {
                        // The system font, as menus write ⌥⇧⌘ (a monospaced one drew them badly).
                        Text(row.keys)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.what)
                    }
                }
            }
        }
        .padding(24)
        .fixedSize()
    }
}
