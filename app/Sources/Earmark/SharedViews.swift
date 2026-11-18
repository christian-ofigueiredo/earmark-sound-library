import AppKit
import EarmarkCore
import SwiftUI

/// Waveform, play button and range selection for one file.
struct PlayerPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    let url: URL
    let knownDuration: Double?
    /// Sound effects show tenths of a second; songs don't need them.
    var precise = true

    @State private var waveform: WaveformData?
    @State private var loading = true
    @State private var selection: ClosedRange<Double>?

    private var player: AudioPlayer { model.player }
    private var length: Double { waveform?.duration ?? knownDuration ?? 0 }
    /// This file is playing or paused.
    private var isActive: Bool { player.isActive(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WaveformView(peaks: waveform?.peaks,
                         active: activeState != .inactive,
                         playhead: { [player, url, length] in
                             player.isActive(url) && length > 0 ? player.liveTime / length : nil
                         },
                         playing: player.plays(url),
                         selection: $selection,
                         onClick: click,
                         onScrub: { fraction, _ in if isActive { player.seek(to: fraction * length) } })
                .frame(height: 96)
                .overlay {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if waveform == nil {
                        Text("No waveform for this file").font(.dsCaption).foregroundStyle(.secondary)
                    }
                }
            HStack(spacing: 8) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: player.plays(url) ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .playerButtonStyle(prominent: true)
                .help(player.plays(url) ? "Pause (Space in the list)"
                      : selection == nil ? "Play (Space in the list)" : "Play the selection")
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill").frame(width: 16)
                }
                .playerButtonStyle()
                .disabled(!isActive)
                .help("Stop and go back to the start")
                PlayerTime(url: url, length: length, selection: selection, precise: precise)
                Spacer()
                if selection != nil {
                    Button("Clear Selection", action: clearSelection)
                        .buttonStyle(.dsLink)
                }
                Button {
                    model.addToResolve(url, range: secondsSelected)
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle").frame(width: 16)
                }
                .playerButtonStyle()
                .disabled(!FileManager.default.fileExists(atPath: url.path))
                .help(selection == nil ? "Add to the DaVinci Resolve timeline at its playhead (⌘T)"
                      : "Add the selection to the DaVinci Resolve timeline at its playhead, cut from the original file (⌘T)")
            }
            if player.url == url, let error = player.error {
                Text(error).font(.dsCaption).foregroundStyle(Color.dsInk)
            }
        }
        .onChange(of: selection) { model.playerSelection = secondsSelected.map { (url, $0) } }
        .task(id: url) {
            loading = true
            selection = nil
            let data = await Waveform.load(url)
            guard !Task.isCancelled else { return }
            waveform = data
            loading = false
        }
    }

    /// A click on the waveform moves the playhead there: playing keeps playing, paused stays
    /// paused, and if this file isn't loaded it starts playing from there.
    private func click(_ fraction: Double) {
        selection = nil
        let t = fraction * length
        if isActive {
            player.clearRange()
            player.seek(to: t)
        } else {
            player.play(url, from: t)
        }
    }

    /// Pause if playing. With a selection, play it (from the paused point if that's inside it);
    /// otherwise resume, or start from the beginning.
    private func togglePlayback() {
        if player.plays(url) {
            player.pause()
        } else if let sel = selection, length > 0 {
            let a = sel.lowerBound * length, b = sel.upperBound * length
            let t = player.currentTime
            player.play(url, from: isActive && t >= a && t < b ? t : a, to: b)
        } else if isActive {
            player.resume()
        } else {
            player.play(url)
        }
    }

    /// The selection in seconds.
    private var secondsSelected: ClosedRange<Double>? {
        guard let sel = selection, length > 0 else { return nil }
        return sel.lowerBound * length ... sel.upperBound * length
    }

    private func clearSelection() {
        selection = nil
        if player.url == url { player.clearRange() }
    }
}

/// The player's time while playing or paused; otherwise the selection, or the length. Its own
/// view, so the time's 40 changes a second don't rebuild the player panel.
private struct PlayerTime: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let length: Double
    let selection: ClosedRange<Double>?
    let precise: Bool

    var body: some View {
        TickingText(label).foregroundStyle(.secondary)
    }

    private var label: String {
        let player = model.player
        if player.isActive(url) {
            return "\(formatLength(player.currentTime, precise: precise)) / \(formatLength(length, precise: precise))"
        }
        if let sel = selection, length > 0 {
            let a = sel.lowerBound * length, b = sel.upperBound * length
            // Short, to fit beside the stop button and Clear Selection; the highlight says it's a selection.
            return "\(formatLength(a, precise: true))–\(formatLength(b, precise: true)) · \(formatLength(b - a, precise: true))"
        }
        return formatLength(length > 0 ? length : nil, precise: precise)
    }
}


/// Text that changes many times a second (the playing time), laid out by a stand-in with its
/// digits zeroed: the stand-in only changes when the number of digits does, so the views
/// around it aren't laid out again on every tick (the detail pane's scroll-if-needed measured
/// all of its content each time).
struct TickingText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(String(text.map { $0.isNumber ? "0" : $0 }))
            .monospacedDigit()
            .hidden()
            .overlay(alignment: .leading) { Text(text).monospacedDigit().fixedSize() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

/// The sound or song the player has, for `NowPlayingBar`.
struct NowPlaying: Equatable {
    var url: URL
    var name: String
    var duration: Double?
    /// Tenths of a second, for sound effects.
    var precise: Bool

    /// What's playing or paused, unless the detail pane is already showing it.
    @MainActor static func elsewhere(in model: AppModel) -> NowPlaying? {
        switch model.section {
        case .sounds:
            guard let sound = model.playingSound, model.soundBrowser.selection != [sound.id] else { return nil }
            return NowPlaying(url: sound.url, name: sound.displayName, duration: sound.duration, precise: true)
        case .music:
            guard let song = model.playingSong, model.musicBrowser.selection != [song.id] else { return nil }
            return NowPlaying(url: song.url, name: song.displayTitle, duration: song.duration, precise: false)
        }
    }

    /// Selects it in its list and scrolls to it.
    @MainActor func reveal(in model: AppModel) {
        switch model.section {
        case .sounds: if let sound = model.playingSound { model.soundBrowser.reveal(sound.id) }
        case .music: if let song = model.playingSong { model.musicBrowser.reveal(song.id) }
        }
    }
}

/// What's playing, at the top of the detail pane while it shows something else (owner,
/// 2026-10-26: after selecting another row, the playing one was hard to find). Show selects
/// it again and scrolls the list to it.
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    let item: NowPlaying

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(player.isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityLabel(player.isPlaying ? "Playing" : "Paused")
                (Text("Now playing: ").foregroundStyle(.secondary) + Text(item.name).fontWeight(.medium))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                NowPlayingTime(duration: item.duration, precise: item.precise)
                Spacer(minLength: 4)
                Button {
                    player.toggle(item.url)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 12)
                }
                .help(player.isPlaying ? "Pause" : "Play")
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill").frame(width: 12)
                }
                .help("Stop and go back to the start")
                Button("Show") { item.reveal(in: model) }
                    .buttonStyle(.dsLink)
                    .help("Select it in the list")
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsSelection))
        .padding([.horizontal, .top], 12)
    }
}

/// The playing time: its own view, as it changes many times a second.
private struct NowPlayingTime: View {
    @Environment(AppModel.self) private var model
    let duration: Double?
    let precise: Bool

    var body: some View {
        TickingText("\(formatLength(model.player.currentTime, precise: precise)) / \(formatLength(duration, precise: precise))")
            .font(.dsCaption)
            .foregroundStyle(.secondary)
    }
}

/// The original file, ready to drag into Resolve or Finder.
struct FileChip: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("Drag to Resolve").font(.dsCaption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.dsSunken))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dsLine, lineWidth: 1))
        // An AppKit drag area rather than .onDrag: inside the detail pane's scroll view,
        // .onDrag's hit area sat a toolbar's height too high, over the player's buttons.
        .overlay(FileDragArea(url: url, tooltip: "Drag into DaVinci Resolve. Resolve uses this original file; nothing is copied."))
    }
}

/// A transparent view that drags a file (the original, by reference) and shows a tooltip.
struct FileDragArea: NSViewRepresentable {
    @Environment(\.sectionShown) private var sectionShown
    let url: URL
    let tooltip: String

    func makeNSView(context: Context) -> FileDragView { FileDragView() }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.url = url
        view.toolTip = sectionShown ? tooltip : nil
        view.passesClicks = !sectionShown
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var url: URL?
    /// In the hidden section's detail pane (kept built under the shown one): clicks go through.
    var passesClicks = false
    private var mouseDownEvent: NSEvent?

    override func hitTest(_ point: NSPoint) -> NSView? { passesClicks ? nil : super.hitTest(point) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let url, let down = mouseDownEvent else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let p = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

struct InfoRow: Identifiable {
    let label: String
    let value: String
    /// A path: shown on one line, cut at the start, with a button that copies `copy`.
    var copy: String?
    var id: String { label }

    /// A folder, shortened to its last two levels; the whole of it in the tooltip, and a button
    /// that copies `full`.
    static func folder(_ folder: String, full: String, label: String = "Folder") -> InfoRow? {
        guard !folder.isEmpty else { return nil }
        let parts = folder.split(separator: "/")
        let short = parts.count > 2 ? "… / " + parts.suffix(2).joined(separator: " / ") : parts.joined(separator: " / ")
        return InfoRow(label: label, value: short, copy: full)
    }
}

/// A titled block of facts in the detail pane: a printed title, then one fact a line with
/// hairlines between, labels in one column.
struct InfoGrid: View {
    let title: String?
    let rows: [InfoRow]

    init(_ title: String? = nil, _ pairs: [(String, String?)], then extra: [InfoRow?] = []) {
        self.title = title
        rows = pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return InfoRow(label: label, value: value)
        } + extra.compactMap { $0 }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title).overlineStyle().padding(.bottom, 8)
                    Rectangle().fill(Color.dsLinePrint).frame(height: 1)
                }
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label).font(.dsCaption).foregroundStyle(Color.dsInkMuted)
                            .frame(width: 92, alignment: .leading)
                        if let copy = row.copy {
                            Text(row.value).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(copy)
                            CopyButton(text: copy)
                        } else {
                            Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 8)
                    if row.id != rows.last?.id { Rectangle().fill(Color.dsLine).frame(height: 1) }
                }
            }
            .font(.dsBodySm)
        }
    }
}

/// Copies a text; a tick for a moment once it has.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Color.dsAccent : Color.dsInkMuted)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy the path")
        .accessibilityLabel("Copy the path")
    }
}

struct FileActions: View {
    let url: URL
    let online: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(!online)
            Button("Copy Path") { copyToPasteboard(url.path) }
                .help("Copy the file's whole path")
        }
        .buttonStyle(.dsGhost)
    }
}

struct OfflineNotice: View {
    let library: Library?

    var body: some View {
        Label("“\(library?.name ?? "This folder")” is offline. Connect the drive to play this file.",
              systemImage: "externaldrive.badge.xmark")
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.dsSunken))
    }
}

struct LibraryRow: View {
    let library: Library
    let count: Int
    let scanning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(library.name).lineLimit(1)
                    if !library.isOnline {
                        Text("Offline").font(.dsCaption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: library.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder")
            }
            if scanning {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .badge(count)
        .opacity(library.isOnline ? 1 : 0.55)
        .help(library.path)
    }
}

struct LibraryMenu: View {
    @Environment(AppModel.self) private var model
    let library: Library

    var body: some View {
        Button("Rescan") { model.startScan(library) }
            .disabled(!library.isOnline || model.isScanning(library))
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.url]) }
            .disabled(!library.isOnline)
        Button("Export Analysis…") { model.chooseExport([library]) }
        Divider()
        Button("Remove from Earmark…", role: .destructive) { model.confirmRemove(library) }
    }
}

/// The detail pane's content, scrolling only when it doesn't fit. Inside a ScrollView under
/// the toolbar, with AppKit views in it (waveform, drag area), SwiftUI hit-tested the player's
/// buttons a few points off what's drawn, so clicks on Play or Clear Selection were lost.
struct DetailScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.frame(maxHeight: .infinity, alignment: .top)
            ScrollView { content }
        }
    }
}

extension View {
    /// A bar along the top or bottom of a list. On macOS 26 and later it's the system's kind
    /// (no divider; the list's rows end above it) on the bar material, since tables don't
    /// draw the scroll edge effect under it. Earlier, an inset with a bar background and a divider.
    /// `shown: false` makes the whole bar, background too, transparent (`shown(_:)`).
    @ViewBuilder func edgeBar<Bar: View>(_ edge: VerticalEdge, shown visible: Bool = true,
                                         @ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: 0) { bar().background(Color.dsBackground).shown(visible) }
        } else {
            safeAreaInset(edge: edge, spacing: 0) {
                bar()
                    .background(Color.dsBackground)
                    .shown(visible)
            }
        }
    }

    /// Player buttons: round Liquid Glass buttons on macOS 26 and later; `prominent` (play) is
    /// the screen's one red key, the others plain glass.
    @ViewBuilder func playerButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large).tint(.dsAccent)
            } else {
                buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            }
        } else {
            self
        }
    }
}

extension EnvironmentValues {
    /// False in the section kept built under the one shown (`LibraryView`): its own AppKit
    /// views let clicks through. Set only on the detail panes, never above a list.
    @Entry var sectionShown = true
}
