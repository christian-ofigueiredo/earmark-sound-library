import EarmarkCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // Each section puts the status bar under its list (`edgeBar`), so the sidebar runs
        // the window's full height, as macOS 27 sidebars do.
        Group {
            if let error = model.startupError {
                ContentUnavailableView("Earmark can't start", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                LibraryView()
            }
        }
        .toolbar {
            // The switch is its own Liquid Glass control, not on the toolbar's shared glass.
            if #available(macOS 26, *) {
                ToolbarItem(placement: .principal) { SectionSwitch() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { SectionSwitch() }
            }
        }
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

/// Both sections in one split view, both kept built: changing section only shows one and
/// hides the other, where rebuilding a section (split view, tables, layout) took ~0.2 s.
/// The search field and the auto-play button are shared and follow the section shown.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoplaySounds") private var autoplaySounds = false
    @AppStorage("autoplayMusic") private var autoplayMusic = false

    var body: some View {
        @Bindable var model = model
        let music = model.section == .music
        let sounds = model.soundBrowser, songs = model.musicBrowser
        // The detail pane is an inspector rather than a third split column: a three-column
        // NavigationSplitView ignores the content column's width and squeezes the table.
        NavigationSplitView {
            ZStack {
                SoundSidebar().shown(!music)
                MusicSidebar().shown(music)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ZStack {
                SoundTable()
                    .edgeBar(.bottom) { StatusBar() }
                    .shown(!music)
                SongTable()
                    .edgeBar(.top) { MusicFilterBar() }
                    .edgeBar(.bottom) { StatusBar() }
                    .shown(music)
            }
            // One stable binding: anything that changes here with the section reaches every
            // table cell (each its own hosting view) and makes the switch slow.
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
            .inspector(isPresented: .constant(true)) {
                ZStack {
                    SoundDetailPane().shown(!music)
                    SongDetailPane().shown(music)
                }
                .inspectorColumnWidth(min: 300, ideal: 380, max: 600)
            }
        }
        .toolbar {
            ToolbarItem {
                let on = music ? autoplayMusic : autoplaySounds
                Toggle(isOn: Binding(get: { on }, set: { if music { autoplayMusic = $0 } else { autoplaySounds = $0 } })) {
                    Label("Auto-play", systemImage: on ? "play.circle.fill" : "play.circle")
                }
                .help(music ? "Play songs as you select them" : "Play sounds as you select them")
            }
        }
        .onChange(of: model.section) {
            // Keys mustn't go to the hidden list; the user clicks into the one shown.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .task(id: sounds.filterKey(version: model.version)) { sounds.refresh(from: model) }
        .task(id: songs.filterKey(version: model.version)) { songs.refresh(from: model) }
        .onChange(of: sounds.selection) { _, ids in
            guard autoplaySounds, !music, ids.count == 1, let s = model.sound(id: ids.first ?? nil),
                  model.isOnline(libraryId: s.libraryId) else { return }
            model.player.play(s.url)
        }
        .onChange(of: songs.selection) { _, ids in
            guard autoplayMusic, music, ids.count == 1, let s = model.song(id: ids.first ?? nil),
                  model.isOnline(libraryId: s.libraryId) else { return }
            model.player.play(s.url)
        }
    }
}

extension View {
    /// Keeps a section built but out of sight while the other is shown, which stays on top
    /// for clicks. Only opacity and order: `.disabled`, `.allowsHitTesting` and the like change
    /// the environment of every table cell (each its own hosting view) and cost ~0.5 s.
    func shown(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).zIndex(visible ? 1 : 0)
    }
}

/// Sound Effects / Music. On macOS 26 and later a Liquid Glass capsule whose blue glass pill
/// slides to the chosen section (`AppModel.show`).
struct SectionSwitch: View {
    @Environment(AppModel.self) private var model
    @Namespace private var pill

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer {
                    HStack(spacing: 0) {
                        ForEach(AppSection.allCases, id: \.self) { section in segment(section) }
                    }
                    .padding(3)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            } else {
                Picker("Section", selection: Binding(get: { model.section }, set: { model.show($0) })) {
                    ForEach(AppSection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .help("Switch between sound effects (⌘1) and music (⌘2)")
    }

    @available(macOS 26, *)
    private func segment(_ section: AppSection) -> some View {
        let chosen = section == model.section
        return Button {
            model.show(section)
        } label: {
            Text(section.title)
                .font(.body.weight(chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background {
                    if chosen {
                        Capsule()
                            .fill(Color.blue.gradient)
                            .glassEffect(.regular.tint(.blue).interactive(), in: .capsule)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
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
            } else if let guess = model.guessProgress {
                ProgressView(value: Double(guess.done), total: Double(max(1, guess.total))).frame(width: 120)
                Text("Guessing categories for folders: \(guess.done) of \(guess.total)").lineLimit(1)
            } else {
                Text(summary).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if !model.analysis.statusText.isEmpty {
                if let done = model.analysis.progress {
                    ProgressView(value: done)
                        .frame(width: 80)
                        .help("\(Int((done * 100).rounded(.down)))% of the slowest unfinished stage")
                }
                Label(model.analysis.statusText, systemImage: model.analysis.pace.isPaused ? "pause.circle" : "waveform.badge.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Divider().frame(height: 12)
            }
            // The reminder the owner asked for, shortened when the list is narrow.
            ViewThatFits(in: .horizontal) {
                Label("Analysis is much faster when you're not using the Mac. Leave Earmark open overnight.",
                      systemImage: "moon.zzz")
                Label("Faster while the Mac is idle", systemImage: "moon.zzz")
                Image(systemName: "moon.zzz")
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("Analysis is much faster when you're not using the Mac. Leave Earmark open overnight: "
                + "it analyses sounds in the background and slows down while you work.")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
