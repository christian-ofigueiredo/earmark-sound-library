import AppKit
import EarmarkCore
import SwiftUI

enum MusicScope: Hashable, Sendable {
    case all
    case library(Int64)
    /// Songs with a tempo, key or beats per bar set by hand.
    case corrected
}

/// What the song list shows: scope, search, tempo/key filters, sort and selection.
@MainActor @Observable
final class MusicBrowser {
    var scope: MusicScope? = .all
    var search = ""
    var selection: Set<SongRecord.ID> = []
    var sortOrder = [KeyPathComparator(\SongRecord.displayTitle)]
    var bpmMin: Double?
    var bpmMax: Double?
    /// Also match songs at half or double the tempo (a 70 BPM song fits a 140 BPM edit).
    var halfDouble = true
    var key: MusicKey?
    /// Match the key's Camelot neighbours and its relative, not just the key itself.
    var compatibleKeys = true
    private(set) var visible: [SongRecord] = []
    /// Counts the refreshes of `visible`, so the list knows when to reload.
    private(set) var generation = 0
    /// Bumped by `reveal`: the list scrolls to the selection.
    private(set) var revealRequest = 0

    /// Selects this song and scrolls the list to it, showing all songs if the list hides it.
    func reveal(_ id: SongRecord.ID) {
        if !visible.contains(where: { $0.id == id }) {
            search = ""
            scope = .all
            clearFilters()
        }
        selection = [id]
        revealRequest += 1
    }

    struct FilterKey: Hashable {
        var scope: MusicScope?
        var search: String
        var sortOrder: [KeyPathComparator<SongRecord>]
        var bpmMin: Double?
        var bpmMax: Double?
        var halfDouble: Bool
        var key: MusicKey?
        var compatibleKeys: Bool
        var version: Int
    }

    func filterKey(version: Int) -> FilterKey {
        FilterKey(scope: scope, search: search, sortOrder: sortOrder, bpmMin: bpmMin, bpmMax: bpmMax,
                  halfDouble: halfDouble, key: key, compatibleKeys: compatibleKeys, version: version)
    }

    var hasFilters: Bool { bpmMin != nil || bpmMax != nil || key != nil }

    func clearFilters() {
        bpmMin = nil
        bpmMax = nil
        key = nil
    }

    /// Songs that would cut well with this one: compatible key, tempo within 6%.
    func findMixes(for song: SongRecord) {
        key = song.key
        compatibleKeys = true
        halfDouble = true
        if let bpm = song.bpm {
            bpmMin = (bpm * 0.94).rounded(.down)
            bpmMax = (bpm * 1.06).rounded(.up)
        } else {
            bpmMin = nil
            bpmMax = nil
        }
    }

    func matchesTempo(_ bpm: Double?) -> Bool {
        guard bpmMin != nil || bpmMax != nil else { return true }
        guard let bpm else { return false }
        let lo = bpmMin ?? 0, hi = bpmMax ?? .infinity
        let tempos = halfDouble ? [bpm, bpm * 2, bpm / 2] : [bpm]
        return tempos.contains { $0 >= lo && $0 <= hi }
    }

    func matchesKey(_ songKey: MusicKey?) -> Bool {
        guard let key else { return true }
        guard let songKey else { return false }
        return compatibleKeys ? key.mixesWith.contains(songKey) : songKey == key
    }

    func refresh(from model: AppModel) {
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace)
        let scope = self.scope ?? .all
        let songs = model.songs, haystacks = model.songIndex.haystacks
        let found = songs.indices.filter { i in
            let s = songs[i]
            if case .library(let id) = scope, s.libraryId != id { return false }
            if scope == .corrected, s.correction == nil { return false }
            return matchesTempo(s.bpm) && matchesKey(s.key) && terms.allSatisfy { haystacks[i].contains($0) }
        }
        visible = FastSort.sorted(found.map { songs[$0] }, by: sortOrder)
        generation += 1
        // Drop selected songs the new filter hides, so the detail pane doesn't show them.
        let kept = selection.intersection(visible.map(\.id))
        if kept != selection { selection = kept }
    }
}

struct MusicSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Built once the library has been read, as the sound sidebar (see SoundSidebar).
        if model.hasLoaded { list } else { Color.clear }
    }

    private var list: some View {
        @Bindable var browser = model.musicBrowser
        return List(selection: $browser.scope) {
            Label("All Music", systemImage: "music.note.list")
                .badge(model.songs.count)
                .tag(MusicScope.all)
            Section("Folders") {
                ForEach(model.musicLibraries) { lib in
                    LibraryRow(library: lib, count: model.songIndex.libraryCounts[lib.id ?? -1] ?? 0,
                               scanning: model.isScanning(lib))
                        .tag(MusicScope.library(lib.id ?? -1))
                        .contextMenu { LibraryMenu(library: lib) }
                }
                Button {
                    model.chooseLibrary(.music)
                } label: {
                    Label("Add Music Folder…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Section("Tempo and Key") {
                // The songs whose tempo, key or beats per bar you set by hand, to review them.
                Label("Corrected by You", systemImage: "pencil.line")
                    .badge(model.songIndex.corrected)
                    .tag(MusicScope.corrected)
                Text("\(model.songIndex.analysed.formatted()) of \(model.songs.count.formatted()) songs analysed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    model.choosePhase0Import()
                } label: {
                    Label("Import Phase 0 Results…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

struct MusicFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var b = model.musicBrowser
        HStack(spacing: 8) {
            Text("BPM").foregroundStyle(.secondary)
            TextField("from", value: $b.bpmMin, format: .number).frame(width: 52)
            Text("to").foregroundStyle(.secondary)
            TextField("to", value: $b.bpmMax, format: .number).frame(width: 52)
            Toggle("Half/double time", isOn: $b.halfDouble)
                .help("Also match songs at half or double the tempo")
            Divider().frame(height: 16)
            Picker("Key", selection: $b.key) {
                Text("Any").tag(MusicKey?.none)
                Divider()
                ForEach(MusicKey.wheel, id: \.self) { key in
                    Text(verbatim: "\(key.camelot)  \(key.name)").tag(MusicKey?.some(key))
                }
            }
            .fixedSize()
            Toggle("Compatible keys", isOn: $b.compatibleKeys)
                .disabled(b.key == nil)
                .help("The same key, its relative, and one step either way on the Camelot wheel")
            Spacer()
            if b.hasFilters {
                Button("Clear Filters") { b.clearFilters() }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct SongTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var browser = model.musicBrowser
        let shown = model.section == .music
        let faded = model.sectionFaded
        let playing = model.playingSong
        RecordTable(rows: browser.visible, rowsVersion: browser.generation, filter: browser.filterKey(version: 0),
                    columns: Self.columns, selection: $browser.selection, sortOrder: $browser.sortOrder,
                    shown: shown, autosaveName: "Songs", accessibilityLabel: "Songs", url: \.url,
                    menu: { ids in menu(for: ids) },
                    primaryAction: { ids in if let s = model.song(id: ids.first ?? nil) { model.player.toggle(s.url) } },
                    playing: playing?.id, playingPaused: !model.player.isPlaying, revealRequest: browser.revealRequest, faded: faded)
        .overlay {
            Group {
                if model.musicLibraries.isEmpty {
                    ContentUnavailableView {
                        Label("No Music Folders Yet", systemImage: "music.note")
                    } description: {
                        Text("Add a music folder, then import the tempo and key results from Phase 0. "
                            + "Earmark only reads the files.")
                    } actions: {
                        Button("Add Music Folder…") { model.chooseLibrary(.music) }
                    }
                } else if browser.visible.isEmpty && !browser.search.isEmpty {
                    ContentUnavailableView.search(text: browser.search)
                } else if browser.visible.isEmpty && browser.hasFilters {
                    ContentUnavailableView {
                        Label("No Songs Match", systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button("Clear Filters") { browser.clearFilters() }
                    }
                }
            }
            .shown(shown && !faded)
        }
    }

    private static let columns: [RecordColumn<SongRecord>] = [
        RecordColumn(id: "title", title: "Title", width: 240, sort: KeyPathComparator(\.displayTitle),
                     canHide: false, typeSelect: true, marksPlaying: true) { $0.displayTitle },
        RecordColumn(id: "artist", title: "Artist", width: 170, sort: KeyPathComparator(\.artistText)) { $0.artistText },
        RecordColumn(id: "bpm", title: "BPM", minWidth: 40, width: 52, maxWidth: 70, sort: KeyPathComparator(\.bpmValue),
                     digits: true) { $0.bpm.map(formatBPM) ?? "" },
        RecordColumn(id: "key", title: "Key", minWidth: 70, width: 86, sort: KeyPathComparator(\.keyOrder)) { $0.key?.name ?? "" },
        RecordColumn(id: "camelot", title: "Camelot", minWidth: 48, width: 58, maxWidth: 70,
                     sort: KeyPathComparator(\.keyOrder), digits: true) { $0.key?.camelot ?? "" },
        RecordColumn(id: "relative", title: "Or Relative", minWidth: 70, width: 86, sort: KeyPathComparator(\.relativeOrder),
                     secondary: true) { $0.key?.relative.name ?? "" },
        RecordColumn(id: "length", title: "Length", minWidth: 44, width: 54, maxWidth: 70,
                     sort: KeyPathComparator(\.durationValue), digits: true) { formatLength($0.duration, precise: false) },
        RecordColumn(id: "folder", title: "Folder", width: 200, sort: KeyPathComparator(\.folder)) { $0.folder },
    ]

    private func menu(for ids: Set<SongRecord.ID>) -> [RecordMenuItem] {
        let browser = model.musicBrowser
        let picked = ids.compactMap { model.song(id: $0) }
        var items: [RecordMenuItem] = []
        if picked.count == 1, let s = picked.first {
            items.append(.action("Play") { model.player.play(s.url) })
            items.append(.action("Find Songs That Mix With This", enabled: s.key != nil || s.bpm != nil) { browser.findMixes(for: s) })
            items.append(.divider)
        }
        if !picked.isEmpty {
            // Corrections by hand, for every selected song they apply to (Edit ▸ Undo takes them back).
            let ids = picked.map(\.id), undo = undoManager, one = picked.count == 1 ? picked.first : nil
            func run(_ e: SongEdit) -> () -> Void { { model.edit(e, songs: ids, undo: undo) } }
            func any(_ e: SongEdit) -> Bool { picked.contains { $0.allows(e) } }
            func keys(_ group: ArraySlice<MusicKey>) -> [RecordMenuItem] {
                group.map { k in .action("\(k.name) · \(k.camelot)", checked: one?.key == k, run(.setKey(k))) }
            }
            items.append(.action("Double Tempo", enabled: any(.doubleTempo), run(.doubleTempo)))
            items.append(.action("Halve Tempo", enabled: any(.halveTempo), run(.halveTempo)))
            items.append(.action("Use Relative Key", enabled: any(.relativeKey), run(.relativeKey)))
            items.append(.submenu("Set Key", keys(MusicKey.all.prefix(12)) + [.divider] + keys(MusicKey.all.suffix(12))))
            items.append(.submenu("Beats per Bar", [2, 3, 4, 6].map { n in
                .action("\(n)", checked: one?.beatsPerBar == n, run(.setBeatsPerBar(n)))
            }))
            items.append(.action("Revert to Analysed Values", enabled: any(.revertAll), run(.revertAll)))
            items.append(.divider)
            items.append(.action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url)) })
            items.append(.action(picked.count == 1 ? "Copy Path" : "Copy Paths") {
                copyToPasteboard(picked.map(\.path).joined(separator: "\n"))
            })
        }
        return items
    }
}

struct SongDetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.musicBrowser.selection
        if ids.count == 1, let song = model.song(id: ids.first ?? nil) {
            SongDetail(song: song).id(song.id).transition(.identity)
        } else if ids.count > 1 {
            ContentUnavailableView("\(ids.count) Songs Selected", systemImage: "square.stack").transition(.identity)
        } else {
            ContentUnavailableView("No Song Selected", systemImage: "music.note",
                                   description: Text("Select a song to hear it and see its tempo and key."))
                .transition(.identity)
        }
    }
}

struct SongDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let song: SongRecord
    @State private var settingTempo = false
    @State private var tempoText = ""

    var body: some View {
        let online = model.isOnline(libraryId: song.libraryId)
        DetailScroll {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.displayTitle)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    if let artist = song.artist, !artist.isEmpty {
                        Text(artist).foregroundStyle(.secondary)
                    }
                }
                if online {
                    PlayerPanel(url: song.url, knownDuration: song.duration, precise: false)
                    FileChip(url: song.url)
                } else {
                    OfflineNotice(library: model.library(id: song.libraryId))
                }
                let unreadable = song.id.flatMap { model.analysis.unreadableSongs[$0] }
                if let why = unreadable {
                    Text("Earmark couldn't read this file to work out its tempo and key. It tries again next time it opens.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(why)
                } else if !song.isAnalysed && song.correction == nil {
                    Text(model.analysis.musicUnavailable == "model not installed"
                         ? "Not analysed yet. Earmark's tempo and key models aren't installed; you can import "
                           + "Phase 0's results instead (File ▸ Import Phase 0 Music Analysis…)."
                         : "Not analysed yet. Earmark works out its tempo and key in the background.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Shown once there's something to show or correct (an unreadable file can be set by hand).
                if unreadable != nil || song.isAnalysed || song.correction != nil {
                    HStack(alignment: .top, spacing: 28) {
                        tempo
                        key
                    }
                    Button("Find Songs That Mix With This") { model.musicBrowser.findMixes(for: song) }
                        .disabled(song.bpm == nil && song.key == nil)
                }
                InfoGrid([
                    ("Album", song.album),
                    ("Length", formatLength(song.duration, precise: false)),
                    ("Analysis", analysisText),
                    ("Folder", song.folder),
                    ("File", song.fileName),
                ])
                FileActions(url: song.url, online: online)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Set Tempo", isPresented: $settingTempo) {
            TextField("BPM", text: $tempoText)
            Button("Set") { if let bpm = typedTempo { edit(.setTempo(bpm)) } }
                .disabled(typedTempo == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            // The field starts empty (an alert's text field doesn't take a starting value on macOS).
            Text((song.bpm.map { "Now \(formatBPM($0)) BPM. " } ?? "")
                 + "Between \(Int(SongEdit.tempoRange.lowerBound)) and \(Int(SongEdit.tempoRange.upperBound)) BPM.")
        }
    }

    private func edit(_ e: SongEdit) { model.edit(e, songs: [song.id], undo: undoManager) }

    private var typedTempo: Double? {
        let text = tempoText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(text).flatMap { SongEdit.tempoRange.contains($0) ? $0 : nil }
    }

    /// "Phase 0 · tempo and key corrected by you".
    private var analysisText: String? {
        guard let c = song.correction else { return song.analysisSource }
        let parts = [c.correctsTempo ? "tempo" : nil, c.correctsKey ? "key" : nil, c.correctsBeatsPerBar ? "beats per bar" : nil]
            .compactMap { $0 }
        let what = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.joined()
        return [song.analysisSource, "\(what) corrected by you"].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Set by you · Phase 0 found 61.8 BPM".
    private func setByYou(found: String) -> String {
        guard song.isAnalysed, let source = song.analysisSource else { return "Set by you" }
        return "Set by you · \(source) found \(found)"
    }

    private var tempo: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Tempo").font(.caption).foregroundStyle(.secondary)
                ChangeMenu { tempoMenu }
            }
            Text(song.bpm.map { "\(formatBPM($0)) BPM" } ?? "No steady beat")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            if song.correction?.correctsTempo == true {
                Text(setByYou(found: song.analysed?.bpm.map { "\(formatBPM($0)) BPM" } ?? "no steady beat"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if song.tempoStability == "variable", let lo = song.bpmLow, let hi = song.bpmHigh {
                Text("Changes: \(formatBPM(lo))–\(formatBPM(hi))").font(.callout).foregroundStyle(.secondary)
            }
            if let beats = song.beatsPerBar {
                Text("\(beats) beats per bar" + (song.correction?.correctsBeatsPerBar == true ? " · set by you" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var tempoMenu: some View {
        if let bpm = song.bpm {
            Button("Double: \(formatBPM(bpm * 2)) BPM") { edit(.doubleTempo) }
                .disabled(!song.allows(.doubleTempo))
            Button("Half: \(formatBPM(bpm / 2)) BPM") { edit(.halveTempo) }
                .disabled(!song.allows(.halveTempo))
        }
        Button("Set Tempo…") {
            tempoText = ""
            settingTempo = true
        }
        Picker("Beats per Bar", selection: Binding(get: { song.beatsPerBar }, set: { if let n = $0 { edit(.setBeatsPerBar(n)) } })) {
            ForEach([2, 3, 4, 6], id: \.self) { Text("\($0)").tag(Optional($0)) }
        }
        .pickerStyle(.menu)
        if let c = song.correction, c.correctsTempo || c.correctsBeatsPerBar {
            Divider()
            if c.correctsTempo {
                Button("Revert to \(song.analysed?.bpm.map { "\(formatBPM($0)) BPM" } ?? "No Steady Beat")") { edit(.revertTempo) }
            }
            if c.correctsBeatsPerBar {
                Button("Revert to \(song.analysed?.beatsPerBar.map { "\($0) Beats per Bar" } ?? "No Beats per Bar")") {
                    edit(.revertBeatsPerBar)
                }
            }
        }
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Key").font(.caption).foregroundStyle(.secondary)
                ChangeMenu { keyMenu }
            }
            if let k = song.key {
                Text("\(k.name) · \(k.camelot)").font(.title3.weight(.semibold))
                if song.correction?.correctsKey == true {
                    Text(setByYou(found: song.analysed?.key.map { "\($0.name) (\($0.camelot))" } ?? "no key"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Or \(k.relative.name) (\(k.relative.camelot)), its relative key: same notes, and the most common mix-up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Unknown").font(.title3.weight(.semibold))
            }
        }
    }

    @ViewBuilder private var keyMenu: some View {
        if let k = song.key {
            Button("Use Relative Key: \(k.relative.name) · \(k.relative.camelot)") { edit(.relativeKey) }
        }
        Picker("Set Key", selection: Binding(get: { song.key }, set: { if let k = $0 { edit(.setKey(k)) } })) {
            ForEach(MusicKey.all.prefix(12), id: \.self) { k in Text("\(k.name) · \(k.camelot)").tag(Optional(k)) }
            Divider()
            ForEach(MusicKey.all.suffix(12), id: \.self) { k in Text("\(k.name) · \(k.camelot)").tag(Optional(k)) }
        }
        .pickerStyle(.menu)
        if song.correction?.correctsKey == true {
            Divider()
            Button("Revert to \(song.analysed?.key?.name ?? "Unknown")") { edit(.revertKey) }
        }
    }
}

/// The small "Change" menu beside a tempo or key the user can correct.
private struct ChangeMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Text("Change").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Correct it by hand (Edit ▸ Undo takes it back)")
    }
}
