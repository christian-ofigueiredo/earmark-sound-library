import AppKit
import AVFoundation
import EarmarkCore
import SwiftUI

// MARK: File ▸ Save as Timeline File… (docs/timeline-file-plan.md)

extension AppModel {
    /// The selected sounds or songs (or the one's waveform selection) as an FCPXML timeline file, one
    /// after another in list order, for the free DaVinci Resolve, Resolve Studio or Final Cut Pro.
    func saveSelectionAsTimelineFile() {
        let urls = selectedURLsInListOrder
        guard !urls.isEmpty else { return }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            alert = AppAlert(title: missing.count == 1 ? "“\(missing[0].lastPathComponent)” isn't there" : "\(missing.count) files aren't there",
                             message: "Connect their drive, then try again.")
            return
        }
        let range = urls.count == 1 ? playerSelection.flatMap { $0.url == urls[0] ? $0.range : nil } : nil

        let panel = NSSavePanel()
        panel.allowedContentTypes = [TimelineFileSettings.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Earmark sounds"
        panel.message = "In DaVinci Resolve: File ▸ Import ▸ Timeline…  In Final Cut Pro: File ▸ Import ▸ XML…"
        let accessory = NSHostingView(rootView: TimelineFileSettings())
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let lib = AnalysisFile.library(containing: url.deletingLastPathComponent(), in: soundLibraries + musicLibraries) {
            alert = AppAlert(title: "Choose a folder outside your libraries",
                             message: "That folder is inside “\(lib.name)”. Earmark never writes anything inside your libraries.")
            return
        }
        let rate = TimelineFile.Rate.named(TimelineFileSettings.rate) ?? TimelineFile.Rate.all[2]
        let startTimecode = TimelineFileSettings.startTimecode
        let name = url.deletingPathExtension().lastPathComponent
        Task {
            do {
                let placed = try await Task.detached(priority: .userInitiated) {
                    let clips = try urls.map { try Self.timelineClip($0, range: range) }
                    let file = try TimelineFile.fcpxml(clips, rate: rate, startTimecode: startTimecode, name: name)
                    try Data(file.xml.utf8).write(to: url, options: .atomic)
                    return file.placements
                }.value
                let lanes = Set(placed.map(\.lane)).count
                alert = AppAlert(
                    title: "Saved “\(url.lastPathComponent)”",
                    message: "\(placed.count == 1 ? "One sound" : "\(placed.count) sounds") on \(lanes == 1 ? "one track" : "\(lanes) tracks"), "
                        + "\(rate.name) fps, from \(placed.first?.start ?? startTimecode).\n\nIn DaVinci Resolve: File ▸ Import ▸ Timeline…, "
                        + "then copy the clips into your timeline. In Final Cut Pro: File ▸ Import ▸ XML…",
                    actionTitle: "Show in Finder"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                show(error, title: "Couldn't save the timeline file")
            }
        }
    }

    /// The selection in the order the list shows it.
    var selectedURLsInListOrder: [URL] {
        switch section {
        case .sounds:
            let ids = soundBrowser.selection
            return soundBrowser.visible.filter { ids.contains($0.id) }.map(\.url)
        case .music:
            let ids = musicBrowser.selection
            return musicBrowser.visible.filter { ids.contains($0.id) }.map(\.url)
        }
    }

    /// The file's exact length, rate and channels (AVAudioFile reads MP3 and AAC as well as WAV).
    nonisolated static func timelineClip(_ url: URL, range: ClosedRange<Double>?) throws -> TimelineFile.Clip {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        return TimelineFile.Clip(path: url.path, name: url.deletingPathExtension().lastPathComponent,
                                 length: Double(file.length) / format.sampleRate, sampleRate: Int(format.sampleRate),
                                 channels: Int(format.channelCount), timeReference: MetadataReader.timeReference(url: url),
                                 start: range?.lowerBound, end: range?.upperBound)
    }
}

/// The save panel's frame rate and start timecode, remembered.
struct TimelineFileSettings: View {
    static let contentType = UTType(filenameExtension: "fcpxml", conformingTo: .xml) ?? .xml
    @AppStorage("timelineFileRate") private var rate = "25"
    @AppStorage("timelineFileStart") private var start = "01:00:00:00"

    static var rate: String { UserDefaults.standard.string(forKey: "timelineFileRate") ?? "25" }
    static var startTimecode: String { UserDefaults.standard.string(forKey: "timelineFileStart") ?? "01:00:00:00" }

    var body: some View {
        Form {
            Picker("Frame rate:", selection: $rate) {
                ForEach(TimelineFile.Rate.all) { Text($0.name).tag($0.name) }
            }
            TextField("Starts at:", text: $start)
                .frame(width: 110)
            Text("Use your timeline's frame rate.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .fixedSize()
    }
}
