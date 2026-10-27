import AppKit
import EarmarkCore
import SwiftUI

/// Settings that are set once rather than every time (⌘,).
struct Preferences: View {
    static let normalizeKey = "normalizePreview"
    static let loudnessKey = "previewLoudness"
    /// The streaming platforms' level (YouTube, Spotify, Tidal): the common one for media now.
    static let defaultLoudness = -14.0

    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(Preferences.normalizeKey) private var normalize = true
    @AppStorage(Preferences.loudnessKey) private var loudness = Preferences.defaultLoudness
    @AppStorage("autoplaySounds") private var autoplaySounds = false
    @AppStorage("autoplayMusic") private var autoplayMusic = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Play sound effects at the same loudness", isOn: $normalize)
                Picker("Loudness", selection: $loudness) {
                    Text("−14 LUFS · streaming (YouTube, Spotify)").tag(-14.0)
                    Text("−16 LUFS · Apple Music, podcasts").tag(-16.0)
                    Text("−23 LUFS · broadcast (EBU R128)").tag(-23.0)
                }
                .disabled(!normalize)
            } header: {
                Text("Preview")
            } footer: {
                Text("Only how loud Earmark plays them: files aren't changed, and Resolve gets the original. "
                    + "Peaks stay below −1 dBFS. Sounds not measured yet play as they are.")
                    .foregroundStyle(.secondary)
            }
            Section("Auto-play") {
                Toggle("Play sound effects as you select them", isOn: $autoplaySounds)
                Toggle("Play songs as you select them", isOn: $autoplayMusic)
            }
            Section {
                Picker("While you use the Mac", selection: Binding(
                    get: { model.analysis.mode == .idleOnly ? AnalysisGovernor.Mode.idleOnly : .automatic },
                    set: { model.analysis.mode = $0 }
                )) {
                    Text("Keep analysing gently").tag(AnalysisGovernor.Mode.automatic)
                    Text("Wait until the Mac is idle").tag(AnalysisGovernor.Mode.idleOnly)
                }
            } header: {
                Text("Analysis")
            } footer: {
                Text("Pause, resume or run at full speed from the Analysis menu.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance) { appearance.apply() }
        .onChange(of: normalize) { model.player.refreshGain() }
        .onChange(of: loudness) { model.player.refreshGain() }
    }
}

/// Earmark's own light or dark, or the Mac's (owner, 2026-10-27). For the whole app: every
/// window, the sound map too, follows `NSApp.appearance`.
enum Appearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The saved choice, at launch (before any window shows, so none flashes the other way).
    static var saved: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
