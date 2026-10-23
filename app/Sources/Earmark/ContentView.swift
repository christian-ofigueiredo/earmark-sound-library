import EarmarkCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let error = model.startupError {
                ContentUnavailableView("Earmark can't start", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                switch model.section {
                case .sounds: SoundsView()
                case .music: MusicView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $model.section) {
                    Text("Sound Effects").tag(AppSection.sounds)
                    Text("Music").tag(AppSection.music)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between sound effects (⌘1) and music (⌘2)")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .onChange(of: model.section) { _, section in
            model.player.stop()
            UserDefaults.standard.set(section.rawValue, forKey: "section")
        }
        .sheet(isPresented: $model.showWelcome) { WelcomeView().environment(model) }
        .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { alert in
            if let actionTitle = alert.actionTitle {
                Button(actionTitle, role: alert.isDestructive ? ButtonRole.destructive : nil) { alert.action?() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    private var alertShown: Binding<Bool> {
        let shownID = model.alert?.id
        return Binding(
            get: { model.alert != nil },
            set: { if !$0, model.alert?.id == shownID { model.alert = nil } }
        )
    }
}

/// Bottom bar: what Earmark is doing, and the reminder that it works fastest while the Mac is idle.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let activity = model.activity {
                if let progress = model.progress {
                    ProgressView(value: progress).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(activity).lineLimit(1).truncationMode(.middle)
            } else {
                Text(summary).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if !model.analysis.statusText.isEmpty {
                Label(model.analysis.statusText, systemImage: model.analysis.pace.isPaused ? "pause.circle" : "waveform.badge.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Divider().frame(height: 12)
            }
            Label("Analysis is much faster when you're not using the Mac. Leave Earmark open overnight.",
                  systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Earmark analyses sounds in the background and slows down while you work.")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Totals for both sections; the current one says "N of M" while a filter or search hides some.
    private var summary: String {
        let sounds = count(model.soundIndex.shownCount, shown: model.soundBrowser.visible.count,
                           current: model.section == .sounds, noun: "sound")
        let songs = count(model.songs.count, shown: model.musicBrowser.visible.count,
                          current: model.section == .music, noun: "song")
        return "\(sounds) · \(songs)"
    }

    private func count(_ total: Int, shown: Int, current: Bool, noun: String) -> String {
        let all = "\(total.formatted()) \(noun)\(total == 1 ? "" : "s")"
        return current && shown != total ? "\(shown.formatted()) of \(all)" : all
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome to Earmark").font(.largeTitle.weight(.bold))
            WelcomePoint(icon: "lock.shield", title: "Your files are never changed",
                         text: "Earmark only reads your sound effects and music. It never writes to, renames or moves "
                             + "them. Everything it learns is kept in its own database in "
                             + "~/Library/Application Support/Earmark.")
            WelcomePoint(icon: "moon.zzz", title: "Analysis is much faster when you're not using the Mac",
                         text: "Earmark listens to your sounds in the background to sort and group them. It slows down "
                             + "while you work, so leave it open overnight to get through a large library.")
            WelcomePoint(icon: "film", title: "Drag into DaVinci Resolve",
                         text: "Drag any sound or song from the list into Resolve's media pool or timeline. Resolve "
                             + "uses the original file; nothing is copied.")
            HStack {
                Button("Add Sound Library…") {
                    model.finishWelcome()
                    model.chooseLibrary(.sounds)
                }
                Button("Add Music Folder…") {
                    model.finishWelcome()
                    model.chooseLibrary(.music)
                }
                Spacer()
                Button("Get Started") { model.finishWelcome() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 580)
        .interactiveDismissDisabled()
    }
}

private struct WelcomePoint: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
