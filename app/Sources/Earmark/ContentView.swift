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
            // The switch is its own Liquid Glass control, not on the toolbar's shared glass, with
            // auto-play right after it (alone, the toolbar's flexible spaces left it floating).
            if #available(macOS 26, *) {
                ToolbarItem(placement: .principal) { HStack(spacing: 8) { SectionSwitch(); AutoPlayToggle() } }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { HStack(spacing: 8) { SectionSwitch(); AutoPlayToggle() } }
            }
        }
        .dsWindowBackground()
        .toolbarBackground(Color.dsBackground, for: .windowToolbar)
        .onChange(of: model.section) { _, section in
            model.player.stop()
            UserDefaults.standard.set(section.rawValue, forKey: "section")
        }
        .sheet(isPresented: $model.showWelcome) { WelcomeView().environment(model).dsSheet() }
        .sheet(item: $model.exportRequest) { ExportAnalysisSheet(request: $0).environment(model).dsSheet() }
        .sheet(item: $model.groupNaming) { GroupNameSheet(naming: $0).environment(model).dsSheet() }
        .sheet(item: $model.categoryChoosing) { choosing in
            let first = model.sound(id: choosing.sounds.first)
            UCSChooser(title: choosing.sounds.count == 1 ? "Category for “\(first?.displayName ?? "")”"
                                                          : "Category for \(choosing.sounds.count) sounds",
                       current: choosing.sounds.count == 1 ? first?.catID : nil) { catID in
                model.setCategory(choosing.sounds, to: catID)
            }
        }
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
        // The shown section's parts, faded out during a switch (`AppModel.show`).
        let soundsShown = !music && !model.sectionFaded, songsShown = music && !model.sectionFaded
        let sounds = model.soundBrowser, songs = model.musicBrowser
        // The detail pane is an inspector rather than a third split column: a three-column
        // NavigationSplitView ignores the content column's width and squeezes the table.
        NavigationSplitView {
            // The hidden sidebar is hidden in AppKit (`SectionViews`).
            ZStack {
                SoundSidebar()
                MusicSidebar()
            }
            // Behind both lists (each list's own would cover the other's, hidden in AppKit).
            .background(Color.dsSurface)
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ZStack {
                ZStack {
                    SoundTable()
                    SoundMapPane()
                }
                .edgeBar(.top, shown: soundsShown) { SoundViewBar() }
                .edgeBar(.bottom, shown: soundsShown) { StatusBar() }
                SongTable()
                    .edgeBar(.top, shown: songsShown) { MusicFilterBar() }
                    .edgeBar(.bottom, shown: songsShown) { StatusBar() }
            }
            // One stable binding: anything that changes here with the section reaches every
            // view below, and SwiftUI's own tables (Folder Categories) would pay for it per cell.
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
            .inspector(isPresented: .constant(true)) {
                DetailColumn(music: music)
                    .fixedMinimumSize(CGSize(width: 300, height: 300))
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 600)
            }
        }
        .onChange(of: model.section) { _, section in
            SectionViews.sync(showing: section, faded: model.sectionFaded, animated: false)
        }
        .onChange(of: model.sectionFaded) { _, faded in
            SectionViews.sync(showing: model.section, faded: faded, animated: true)
        }
        .onChange(of: model.hasLoaded) {
            // The sidebars' lists exist from now on: hide the other section's.
            syncOnceBuilt()
        }
        .onAppear {
            // As soon as the window has its lists (the next turn of the run loop).
            if model.hasLoaded {
                syncOnceBuilt()
            } else {
                DispatchQueue.main.async { SectionViews.sync(showing: model.section, faded: false, animated: false) }
            }
        }
        .task(id: sounds.filterKey(version: model.version, groups: model.groupsVersion)) { await sounds.refresh(from: model) }
        .task(id: songs.filterKey(version: model.songsVersion)) { songs.refresh(from: model) }
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

/// The detail pane: what's playing on top while it's something else, then the shown
/// section's details. The strip slides down into place and the details slide down with it
/// (up, when it goes).
struct DetailColumn: View {
    @Environment(AppModel.self) private var model
    let music: Bool
    /// The strip's height with its margins, measured once shown.
    @State private var stripHeight: CGFloat = 76
    /// Where the details are drawn, from where they were to 0, as the strip comes or goes.
    @State private var slide: CGFloat = 0

    var body: some View {
        let playing = NowPlaying.elsewhere(in: model)
        VStack(spacing: 0) {
            if let playing {
                NowPlayingBar(item: playing)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)   // over the details while they slide
            }
            ZStack {
                // The hidden pane's own AppKit views (waveform, file drag) let clicks through.
                SoundDetailPane().environment(\.sectionShown, !music).shown(!music && !model.sectionFaded)
                SongDetailPane().environment(\.sectionShown, music).shown(music && !model.sectionFaded)
            }
            .offset(y: slide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.dsSurface)
        .animation(Self.motion, value: playing != nil)
        .onChange(of: playing != nil) { _, shown in
            // The details usually change too (another row selected), so there's no old
            // position for SwiftUI to animate from: start them where the old ones were.
            slide = shown ? -stripHeight : stripHeight
            DispatchQueue.main.async { withAnimation(Self.motion) { slide = 0 } }
        }
    }

    private static let motion = Animation.snappy(duration: 0.3)
}

extension View {
    /// Keeps part of a section built but out of sight while the other is shown. Only opacity:
    /// SwiftUI controls at opacity 0 don't take clicks, but AppKit views do (`SectionViews`,
    /// `RecordTable`, `sectionShown`).
    func shown(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
    }
}

extension LibraryView {
    /// `SectionViews.sync` for the section shown at the time, again every 0.1 s (3 s at most)
    /// until both sidebar lists exist: SwiftUI sometimes makes them a few turns after the
    /// library has loaded, and then both sidebars stayed on screen, one over the other (1 launch
    /// in 8 with the sound map drawing, 2026-10-26).
    func syncOnceBuilt(attempts: Int = 30) {
        DispatchQueue.main.async {
            let found = SectionViews.sync(showing: model.section, faded: model.sectionFaded, animated: false)
            if !found, attempts > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { syncOnceBuilt(attempts: attempts - 1) }
            }
        }
    }
}

/// The two sections' views overlap (both stay built and laid out, so a switch is quick), and
/// SwiftUI's opacity doesn't stop AppKit from sending the hidden ones clicks, scrolling and
/// keys; SwiftUI also hit-tests its views in the order they were made, whatever their order
/// in AppKit. So the hidden section's sidebar and BPM fields are hidden in AppKit (a few rows
/// to lay out again: cheap). The big lists hide themselves (`RecordTable`).
@MainActor enum SectionViews {
    /// `faded`: the shown sidebar is transparent too, during a switch; `animated` fades it.
    /// False if the sidebar lists aren't both there yet (neither could be hidden).
    @discardableResult
    static func sync(showing section: AppSection, faded: Bool, animated: Bool) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "Earmark" && $0.contentView != nil }),
              let content = window.contentView else { return false }
        var sidebars: [NSScrollView] = [], fields: [NSView] = []
        func visit(_ view: NSView) {
            if let table = view as? NSTableView {
                // The sidebar lists: one-column outlines. (Nothing inside a list: its cells' labels.)
                if table is NSOutlineView, table.tableColumns.count == 1, let scroll = table.enclosingScrollView {
                    sidebars.append(scroll)
                }
                return
            }
            // The music filter bar's BPM fields: the only other text fields in the window's content.
            if view is NSTextField { fields.append(view); return }
            view.subviews.forEach(visit)
        }
        visit(content)
        var shown: [NSView] = [], hidden: [NSView] = []
        // The sidebar lists come in the order LibraryView builds them: sounds, then music.
        if sidebars.count == 2 {
            shown.append(sidebars[section == .sounds ? 0 : 1])
            hidden.append(sidebars[section == .sounds ? 1 : 0])
        }
        if section == .music { shown += fields } else { hidden += fields }
        for view in shown where view.isHidden {
            view.alphaValue = faded ? 0 : 1
            view.isHidden = false
        }
        if sidebars.count == 2 {
            fade(sidebars[section == .sounds ? 0 : 1], to: faded ? 0 : 1, animated: animated)
        }
        // As `RecordTable` does: hidden after SwiftUI's update, without the keyboard (hiding
        // the view that has it makes AppKit ask SwiftUI for the next one, which can hang).
        DispatchQueue.main.async {
            if let responder = window.firstResponder as? NSView, hidden.contains(where: { responder.isDescendant(of: $0) }) {
                window.makeFirstResponder(nil)
            }
            for view in hidden { view.isHidden = true }
        }
        return sidebars.count == 2
    }

    /// Fades an AppKit view with Core Animation, which runs off the main thread.
    static func fade(_ view: NSView, to alpha: CGFloat, animated: Bool) {
        guard view.alphaValue != alpha || animated else { return }
        guard animated else { view.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.22 : 0.15
            context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
            view.animator().alphaValue = alpha
        }
    }
}

/// Play sounds (or songs) as you select them, each section with its own setting: a round
/// button after the section switch, sunk in and bright while on (as a pressed chip).
struct AutoPlayToggle: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoplaySounds") private var autoplaySounds = false
    @AppStorage("autoplayMusic") private var autoplayMusic = false

    var body: some View {
        let music = model.switchSection == .music
        let on = music ? autoplayMusic : autoplaySounds
        Button {
            if music { autoplayMusic.toggle() } else { autoplaySounds.toggle() }
        } label: {
            if #available(macOS 26, *) {
                // Drawn like the switch: its glass, sunk in while on.
                // Drawn like the switch: its glass, red glass while on.
                Image(systemName: on ? "play.fill" : "play.circle")
                    .font(on ? .body : .title3)
                    .foregroundStyle(on ? Color.dsSeashell : Color.dsInkMuted)
                    .frame(width: 34, height: 34)
                    .glassEffect(on ? .regular.tint(Color.dsRuby).interactive() : .regular.interactive(), in: .circle)
                    .contentShape(Circle())
            } else {
                Label("Auto-play", systemImage: on ? "play.circle.fill" : "play.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .help(music ? "Auto-play: play songs as you select them" : "Auto-play: play sounds as you select them")
        .accessibilityLabel("Auto-play")
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Sound Effects / Music. On macOS 26 and later a Liquid Glass capsule whose sunken pill slides
/// to the chosen section (`AppModel.show`), as the design system's pressed chip.
struct SectionSwitch: View {
    /// How long the pill slides, seconds; the section changes after it (`AppModel.show`).
    static let slide = 0.28
    @Environment(AppModel.self) private var model
    /// Where each segment is, for the pill to move to.
    @State private var segments: [AppSection: CGRect] = [:]

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer {
                    HStack(spacing: 0) {
                        ForEach(AppSection.allCases, id: \.self) { section in segment(section) }
                    }
                    // One pill that moves and resizes, behind both labels. (Each segment had its
                    // own pill, cross-faded by a matched geometry effect: going left, the new one
                    // came in under the old one and the two glass shapes blended mid-way, which
                    // stuttered in that direction only.)
                    .background(alignment: .topLeading) {
                        if let frame = segments[model.switchSection] {
                            // The chosen section's key: red glass to the switch's own edge (no pill
                            // inside a pill), Ruby Red in both modes (Milano was too bright as glass).
                            Color.clear
                                .glassEffect(.regular.tint(Color.dsRuby), in: .capsule)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                        }
                    }
                    .coordinateSpace(.named(Self.space))
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .animation(.snappy(duration: Self.slide), value: model.switchSection)
                }
            } else {
                Picker("Section", selection: Binding(get: { model.switchSection }, set: { model.show($0) })) {
                    ForEach(AppSection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .help("Switch between sound effects (⌘1) and music (⌘2)")
    }

    private nonisolated static let space = "sectionSwitch"

    @available(macOS 26, *)
    private func segment(_ section: AppSection) -> some View {
        let chosen = section == model.switchSection
        return Button {
            model.show(section)
        } label: {
            // The same weight either way (bold made the label jump); the chosen one is light, on red.
            Text(section.title)
                .font(.dsLabel)
                .foregroundStyle(chosen ? Color.dsSeashell : Color.dsInkMuted)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { segments[section] = $0 }
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
            } else if let grouping = model.groupProgress {
                ProgressView(value: Double(grouping.done), total: Double(max(1, grouping.total))).frame(width: 120)
                Text("Grouping similar sounds: \(grouping.done) of \(grouping.total) subcategories").lineLimit(1)
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
        .font(.dsBodySm)
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

/// The introduction, shown at first launch and from Help: five short pages on what Earmark
/// does, the last with the buttons that add a first library.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0

    private struct Page {
        let icon: String
        let eyebrow: String
        let title: String
        let text: String
        var points: [(String, String)] = []
    }

    private static let pages: [Page] = [
        Page(icon: "waveform", eyebrow: "Welcome to Earmark", title: "Your sounds and music, sorted by ear",
             text: "Earmark reads your sound effect and music folders, listens to every file and sorts them, "
                 + "so you find the right sound quickly and send it to your edit.",
             points: [("lock.shield", "Your files are never changed. Earmark only reads them: no renaming, no moving, no writing."),
                      ("moon.zzz", "It listens in the background and is much faster while the Mac is idle. Leave it open overnight for a large library.")]),
        Page(icon: "magnifyingglass", eyebrow: "Find", title: "Browse by category, search, or by what sounds alike",
             text: "Every sound gets a category, from its file, its folder or how it sounds.",
             points: [("sidebar.left", "The sidebar lists the categories. Inside each, sounds that sound alike are grouped."),
                      ("waveform.path.ecg", "Find Similar Sounds shows the sounds closest to the one you picked."),
                      ("circle.grid.cross", "Map draws the whole library as dots, similar sounds close together.")]),
        Page(icon: "play.fill", eyebrow: "Listen", title: "Hear a sound before you use it",
             text: "Select a sound and press Space, or turn on auto-play in the toolbar to hear each one as you select it.",
             points: [("cursorarrow.click", "Click the waveform to play from there."),
                      ("arrow.left.and.right", "Drag across the waveform to select only the part you want.")]),
        Page(icon: "film", eyebrow: "Use", title: "Send it to DaVinci Resolve",
             text: "Resolve uses your original file. Nothing is copied.",
             points: [("hand.draw", "Drag a sound or song from the list into Resolve's media pool or timeline."),
                      ("plus.rectangle.on.rectangle", "Or press ⌘T to add it to the timeline at the playhead (Resolve Studio). With a part selected, only that part is added.")]),
        Page(icon: "music.note", eyebrow: "Music", title: "Tempo and key for every song",
             text: "The Music section works out each song's tempo and key, so you can filter by BPM or key and find songs that mix well together.",
             points: [("slider.horizontal.3", "If a tempo or key is wrong, correct it: Earmark keeps your correction.")]),
    ]

    var body: some View {
        let current = Self.pages[page], last = page == Self.pages.count - 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                Image(systemName: current.icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.dsSeashell)
                    .frame(width: 68, height: 68)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.dsAccent))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.25), .clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
                    .keyShadow(0.8)
                VStack(alignment: .leading, spacing: 10) {
                    Text(current.eyebrow).overlineStyle()
                    Text(current.title).font(.dsTitle2).fixedSize(horizontal: false, vertical: true)
                    Text(current.text).font(.dsBody).foregroundStyle(Color.dsInkPrint)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(current.points.enumerated()), id: \.offset) { index, point in
                            if index > 0 { Rectangle().fill(Color.dsLine).frame(height: 1) }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: point.0).foregroundStyle(Color.dsInk).frame(width: 22)
                                Text(point.1).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
            .id(page)
            .transition(.opacity)
            HStack(spacing: 10) {
                // Where you are: the current page's light is red.
                HStack(spacing: 7) {
                    ForEach(Self.pages.indices, id: \.self) { index in
                        Circle().fill(index == page ? Color.dsAccent : Color.dsInk.opacity(0.16)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Page \(page + 1) of \(Self.pages.count)")
                Spacer()
                if last {
                    Button("Add Sound Library…") {
                        model.finishWelcome()
                        model.chooseLibrary(.sounds)
                    }
                    .buttonStyle(.dsGhost)
                    Button("Add Music Folder…") {
                        model.finishWelcome()
                        model.chooseLibrary(.music)
                    }
                    .buttonStyle(.dsGhost)
                    Button("Get Started") { model.finishWelcome() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.dsPrimary)
                } else {
                    Button("Skip") { model.finishWelcome() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.dsLink)
                        .padding(.trailing, 6)
                    if page > 0 {
                        Button("Back") { go(to: page - 1) }.buttonStyle(.dsGhost)
                    }
                    Button("Next") { go(to: page + 1) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.dsPrimary)
                }
            }
            .padding(.top, 22)
        }
        .padding(30)
        .frame(width: 640)
        .interactiveDismissDisabled()
        .onKeyPress(.leftArrow) { if page > 0 { go(to: page - 1) }; return .handled }
        .onKeyPress(.rightArrow) { if !last { go(to: page + 1) }; return .handled }
    }

    private func go(to index: Int) {
        withAnimation(.easeOut(duration: 0.2)) { page = index }
    }
}
