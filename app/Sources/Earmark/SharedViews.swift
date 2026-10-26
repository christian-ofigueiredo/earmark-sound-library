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
        VStack(alignment: .leading, spacing: 8) {
            WaveformView(peaks: waveform?.peaks,
                         active: activeState != .inactive,
                         playhead: isActive && length > 0 ? player.currentTime / length : nil,
                         selection: $selection,
                         onClick: click,
                         onScrub: { fraction, _ in if isActive { player.seek(to: fraction * length) } })
                .frame(height: 96)
                .overlay {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if waveform == nil {
                        Text("No waveform for this file").font(.caption).foregroundStyle(.secondary)
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
                Text(timeLabel).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if selection != nil {
                    Button("Clear Selection", action: clearSelection)
                        .buttonStyle(.link)
                }
            }
            if player.url == url, let error = player.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
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

    private func clearSelection() {
        selection = nil
        if player.url == url { player.clearRange() }
    }

    /// The time while playing or paused; otherwise the selection, or the length.
    private var timeLabel: String {
        if isActive {
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
            Text("Drag to Resolve").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
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
    var id: String { label }
}

struct InfoGrid: View {
    let rows: [InfoRow]

    init(_ pairs: [(String, String?)]) {
        rows = pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return InfoRow(label: label, value: value)
        }
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)   // wrap long paths instead of truncating
                }
            }
        }
        .font(.callout)
    }
}

struct FileActions: View {
    let url: URL
    let online: Bool

    var body: some View {
        HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(!online)
            Button("Copy Path") { copyToPasteboard(url.path) }
        }
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
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
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
                        Text("Offline").font(.caption).foregroundStyle(.secondary)
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
            safeAreaBar(edge: edge, spacing: 0) { bar().background(.bar).shown(visible) }
        } else {
            safeAreaInset(edge: edge, spacing: 0) {
                bar()
                    .background(.bar)
                    .overlay(alignment: edge == .top ? .bottom : .top) { Divider() }
                    .shown(visible)
            }
        }
    }

    /// Player buttons: round Liquid Glass buttons on macOS 26 and later; `prominent` (play)
    /// is tinted glass in the app's blue.
    @ViewBuilder func playerButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
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
