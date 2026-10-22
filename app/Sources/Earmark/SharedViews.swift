import AppKit
import EarmarkCore
import SwiftUI

/// Waveform, play button and range selection for one file.
struct PlayerPanel: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let knownDuration: Double?
    /// Sound effects show tenths of a second; songs don't need them.
    var precise = true

    @State private var waveform: WaveformData?
    @State private var loading = true
    @State private var selection: ClosedRange<Double>?

    private var player: AudioPlayer { model.player }
    private var length: Double { waveform?.duration ?? knownDuration ?? 0 }
    private var isCurrent: Bool { player.url == url }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WaveformView(peaks: waveform?.peaks,
                         playhead: isCurrent && length > 0 ? player.currentTime / length : nil,
                         selection: $selection) { fraction in
                player.play(url, from: fraction * length)
            }
            .frame(height: 96)
            .overlay {
                if loading {
                    ProgressView().controlSize(.small)
                } else if waveform == nil {
                    Text("No waveform for this file").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: player.plays(url) ? "stop.fill" : "play.fill").frame(width: 16)
                }
                .help(selection == nil ? "Play (Space in the list)" : "Play the selection")
                Text(timeLabel).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if selection != nil {
                    Button("Clear Selection") { selection = nil }
                        .buttonStyle(.link)
                }
            }
            if isCurrent, let error = player.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: url) {
            loading = true
            let data = await Waveform.load(url)
            guard !Task.isCancelled else { return }
            waveform = data
            loading = false
        }
    }

    private func togglePlayback() {
        if player.plays(url) {
            player.stop()
        } else if let sel = selection, length > 0 {
            player.play(url, from: sel.lowerBound * length, to: sel.upperBound * length)
        } else {
            player.play(url)
        }
    }

    private var timeLabel: String {
        if let sel = selection, length > 0 {
            let a = sel.lowerBound * length, b = sel.upperBound * length
            return "Selection \(formatLength(a, precise: true))–\(formatLength(b, precise: true)) "
                + "(\(formatLength(b - a, precise: true)))"
        }
        if isCurrent && player.isPlaying {
            return "\(formatLength(player.currentTime, precise: precise)) / \(formatLength(length, precise: precise))"
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
        .onDrag { fileDragItem(url) }
        .help("Drag into DaVinci Resolve. Resolve uses this original file; nothing is copied.")
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
