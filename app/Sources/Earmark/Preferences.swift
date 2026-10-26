import EarmarkCore
import SwiftUI

/// Settings that are set once rather than every time (⌘,).
struct Preferences: View {
    static let normalizeKey = "normalizePreview"
    static let loudnessKey = "previewLoudness"
    /// The streaming platforms' level (YouTube, Spotify, Tidal): the common one for media now.
    static let defaultLoudness = -14.0

    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.normalizeKey) private var normalize = true
    @AppStorage(Preferences.loudnessKey) private var loudness = Preferences.defaultLoudness
    @AppStorage("autoplaySounds") private var autoplaySounds = false
    @AppStorage("autoplayMusic") private var autoplayMusic = false

    var body: some View {
        Form {
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
        .onChange(of: normalize) { model.player.refreshGain() }
        .onChange(of: loudness) { model.player.refreshGain() }
    }
}
