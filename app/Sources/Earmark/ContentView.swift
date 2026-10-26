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
            // Lists are made transparent in AppKit (`SectionViews`), not with SwiftUI's opacity,
            // which makes SwiftUI update every row of a table (~75 ms a switch).
            ZStack {
                SoundSidebar()
                MusicSidebar()
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ZStack {
                SoundTable()
                    .edgeBar(.bottom, shown: !music) { StatusBar() }
                SongTable()
                    .edgeBar(.top, shown: music) { MusicFilterBar() }
                    .edgeBar(.bottom, shown: music) { StatusBar() }
            }
            // One stable binding: anything that changes here with the section reaches every
            // table cell (each its own hosting view) and makes the switch slow.
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
            .inspector(isPresented: .constant(true)) {
                ZStack {
                    // The hidden pane's own AppKit views (waveform, file drag) let clicks through.
                    SoundDetailPane().environment(\.sectionShown, !music).shown(!music)
                    SongDetailPane().environment(\.sectionShown, music).shown(music)
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
        .onChange(of: model.section) { _, section in
            SectionViews.sync(showing: section, focus: false)
            // The shown list takes the keyboard once the switch has animated, so the switch
            // doesn't wait for it; a key pressed sooner moves it there at once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if model.section == section { SectionEventRouter.shared.focusShownList() }
            }
        }
        .onChange(of: model.soundBrowser.sidebarGeneration) {
            // The sounds sidebar was rebuilt (a new AppKit list).
            SectionViews.sync(showing: model.section, focus: false)
        }
        .onAppear {
            // As soon as the window has its lists (the next turn of the run loop).
            DispatchQueue.main.async { SectionViews.sync(showing: model.section, focus: true) }
        }
        .task(id: sounds.filterKey(version: model.version)) { await sounds.refresh(from: model) }
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
    /// Keeps a section built but out of sight while the other is shown; `SectionViews` makes
    /// its AppKit lists let clicks through. Only opacity: `.disabled`, `.allowsHitTesting`,
    /// `.focused` and the like change the environment of every table cell (each its own hosting
    /// view) and cost ~0.4 s a switch, and hiding or moving a list makes AppKit rebuild its rows
    /// when it comes back (~0.1–0.3 s).
    func shown(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
    }
}

/// The two sections' AppKit views overlap (both stay built and laid out, so a switch costs
/// ~20 ms), and SwiftUI's opacity doesn't stop AppKit from sending the hidden ones clicks,
/// scrolling and keys; SwiftUI also hit-tests its views in the order they were made, whatever
/// their order in AppKit. So the hidden section's sidebar and filter fields are hidden in AppKit
/// (a few rows to lay out again: cheap). Its big list only turns transparent, as hiding it
/// would rebuild its rows on every switch (~0.1–0.3 s); `SectionEventRouter` passes the list's
/// clicks to the shown one, and gives the shown list the keyboard, so ↑↓ and Space work.
@MainActor enum SectionViews {
    static func sync(showing section: AppSection, focus: Bool) {
        guard let window = NSApp.windows.first(where: { $0.title == "Earmark" && $0.contentView != nil }),
              let content = window.contentView else { return }
        var tables: [(NSScrollView, NSTableView)] = [], sidebars: [NSScrollView] = [], fields: [NSView] = []
        func visit(_ view: NSView) {
            if let table = view as? NSTableView, let scroll = table.enclosingScrollView {
                if table is NSOutlineView, table.tableColumns.count == 1 { sidebars.append(scroll) }   // the sidebar lists
                else { tables.append((scroll, table)) }
                return
            }
            // The music filter bar's BPM fields: the only text fields in the window's content.
            if view is NSTextField { fields.append(view); return }
            view.subviews.forEach(visit)
        }
        visit(content)
        var shownLists: [NSView] = [], hiddenLists: [NSView] = [], shownTable: NSTableView?
        for (scroll, table) in tables {
            // Told apart by their columns: Name… for sounds, Title… for music.
            let titles = table.tableColumns.map(\.title)
            guard let owner: AppSection = titles.contains("Name") ? .sounds : titles.contains("Title") ? .music : nil else { continue }
            if owner == section { shownLists.append(scroll); shownTable = table } else { hiddenLists.append(scroll) }
        }
        for view in shownLists { view.alphaValue = 1 }
        for view in hiddenLists { view.alphaValue = 0 }
        // The sidebar lists come in the order LibraryView builds them: sounds, then music.
        if sidebars.count == 2 {
            sidebars[0].isHidden = section != .sounds
            sidebars[1].isHidden = section != .music
        }
        for field in fields { field.isHidden = section != .music }
        SectionEventRouter.shared.update(window: window, hidden: hiddenLists, shown: shownLists, list: shownTable)
        if focus { SectionEventRouter.shared.focusShownList() }
    }
}

private struct EventBox: @unchecked Sendable {
    let event: NSEvent?
}

/// Sends the mouse and scroll events that land on the hidden section's list (transparent, but
/// first in SwiftUI's hit-testing when it was made later) to the shown list underneath, as
/// AppKit would if the hidden one weren't there, and gives the shown list the keys the hidden
/// section had. Public API only: a local event monitor, and the views' own handlers.
@MainActor final class SectionEventRouter {
    static let shared = SectionEventRouter()
    private weak var window: NSWindow?
    private var hidden: [NSView] = []
    private var shown: [NSView] = []
    /// The shown section's list, which takes the keys the hidden section had.
    private weak var list: NSTableView?
    private var monitor: Any?
    /// The view a redirected mouse-down went to: its drags and mouse-up follow it, unless the
    /// list tracked them itself.
    private weak var tracking: NSView?

    func update(window: NSWindow, hidden: [NSView], shown: [NSView], list: NSTableView?) {
        self.window = window
        self.hidden = hidden
        self.shown = shown
        self.list = list
        guard monitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown,
                                            .otherMouseDown, .scrollWheel, .keyDown]
        // Local monitors run on the main thread; NSEvent isn't Sendable, hence the box.
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { event in
            let box = EventBox(event: event)
            return MainActor.assumeIsolated { EventBox(event: SectionEventRouter.shared.route(box.event)) }.event
        }
    }

    /// Whether the keyboard is with the hidden section, or with nothing in the window.
    private var focusIsHidden: Bool {
        guard let window else { return false }
        guard let responder = window.firstResponder as? NSView else { return true }
        return hidden.contains { responder.isDescendant(of: $0) }
    }

    /// Gives the shown list the keyboard, unless it is somewhere else in the shown section (the
    /// search field, the sidebar). Costs ~50–75 ms (SwiftUI walks the table's cells).
    func focusShownList() {
        guard let window, let list, focusIsHidden else { return }
        window.makeFirstResponder(list)
    }

    private func route(_ event: NSEvent?) -> NSEvent? {
        guard let event, let window, event.window === window else { return event }
        if event.type == .keyDown {
            // A key pressed before the shown list had the keyboard: it goes there instead.
            focusShownList()
            return event
        }
        switch event.type {
        case .leftMouseDown:
            // A list tracks its own drags (they never reach here): forget an earlier click.
            tracking = nil
        case .leftMouseDragged, .leftMouseUp:
            guard let target = tracking else { return event }
            if event.type == .leftMouseUp { tracking = nil; target.mouseUp(with: event) } else { target.mouseDragged(with: event) }
            return nil
        default: break
        }
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) else { return event }
        guard hidden.contains(where: { hit.isDescendant(of: $0) }) else { return event }
        // The shown list under the pointer.
        guard let target = shown.lazy.compactMap({ view -> NSView? in
            guard let parent = view.superview else { return nil }
            return view.hitTest(parent.convert(event.locationInWindow, from: nil))
        }).first else { return nil }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            // What the window does before a click: the keyboard goes to the clicked view, or
            // the nearest one around it that takes it (the list, for a click on a row).
            var responder: NSView? = target
            while let view = responder, !view.acceptsFirstResponder,
                  !shown.contains(where: { $0 === view }) { responder = view.superview }
            if let responder, responder.acceptsFirstResponder, window.firstResponder !== responder {
                window.makeFirstResponder(responder)
            }
        }
        switch event.type {
        case .leftMouseDown:
            tracking = target
            target.mouseDown(with: event)
        case .rightMouseDown: target.rightMouseDown(with: event)
        case .otherMouseDown: target.otherMouseDown(with: event)
        case .scrollWheel: target.scrollWheel(with: event)
        default: return event
        }
        return nil
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
                    .animation(.snappy(duration: 0.28), value: model.section)
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
