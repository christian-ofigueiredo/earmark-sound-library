import AppKit
import EarmarkCore
import SwiftUI

enum MusicScope: Hashable, Sendable {
    case all
    case library(Int64)
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
        visible = songs.indices.filter { i in
            let s = songs[i]
            if case .library(let id) = scope, s.libraryId != id { return false }
            return matchesTempo(s.bpm) && matchesKey(s.key) && terms.allSatisfy { haystacks[i].contains($0) }
        }
        .map { songs[$0] }
        .sorted(using: sortOrder)
        // Drop selected songs the new filter hides, so the detail pane doesn't show them.
        let kept = selection.intersection(visible.map(\.id))
        if kept != selection { selection = kept }
    }
}

struct MusicView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoplayMusic") private var autoplay = false

    var body: some View {
        @Bindable var browser = model.musicBrowser
        // Detail as an inspector, as in SoundsView, so the table gets the window's width.
        NavigationSplitView {
            MusicSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            SongTable()
                .safeAreaInset(edge: .top, spacing: 0) { MusicFilterBar() }
                .searchable(text: $browser.search, placement: .toolbar, prompt: "Title, artist, file")
                .inspector(isPresented: .constant(true)) {
                    SongDetailPane()
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 600)
                }
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $autoplay) {
                    Label("Auto-play", systemImage: autoplay ? "play.circle.fill" : "play.circle")
                }
                .help("Play songs as you select them")
            }
        }
        .task(id: browser.filterKey(version: model.version)) { model.musicBrowser.refresh(from: model) }
        .onChange(of: browser.selection) { _, ids in
            guard autoplay, ids.count == 1, let s = model.song(id: ids.first ?? nil),
                  model.isOnline(libraryId: s.libraryId) else { return }
            model.player.play(s.url)
        }
    }
}

struct MusicSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.musicBrowser
        List(selection: $browser.scope) {
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
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SongTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.musicBrowser
        Table(of: SongRecord.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Title", value: \.displayTitle)
            TableColumn("Artist", value: \.artistText)
            TableColumn("BPM", value: \.bpmValue) { s in
                Text(s.bpm.map(formatBPM) ?? "").monospacedDigit()
            }
            .width(min: 40, ideal: 52, max: 70)
            TableColumn("Key", value: \.keyOrder) { s in
                Text(s.key?.name ?? "")
            }
            .width(min: 70, ideal: 86)
            TableColumn("Camelot", value: \.keyOrder) { s in
                Text(s.key?.camelot ?? "").monospacedDigit()
            }
            .width(min: 48, ideal: 58, max: 70)
            TableColumn("Or Relative", value: \.relativeOrder) { s in
                Text(s.key?.relative.name ?? "").foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 86)
            TableColumn("Length", value: \.durationValue) { s in
                Text(formatLength(s.duration, precise: false)).monospacedDigit()
            }
            .width(min: 44, ideal: 54, max: 70)
            TableColumn("Folder", value: \.folder)
        } rows: {
            ForEach(browser.visible) { s in
                TableRow(s).itemProvider { fileDragItem(s.url) }
            }
        }
        .contextMenu(forSelectionType: SongRecord.ID.self) { ids in
            let picked = ids.compactMap { model.song(id: $0) }
            if picked.count == 1, let s = picked.first {
                Button("Play") { model.player.play(s.url) }
                Button("Find Songs That Mix With This") { browser.findMixes(for: s) }
                    .disabled(s.key == nil && s.bpm == nil)
                Divider()
            }
            if !picked.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url)) }
                Button(picked.count == 1 ? "Copy Path" : "Copy Paths") {
                    copyToPasteboard(picked.map(\.path).joined(separator: "\n"))
                }
            }
        } primaryAction: { ids in
            if let s = model.song(id: ids.first ?? nil) { model.player.toggle(s.url) }
        }
        .onKeyPress(.space) {
            guard let s = model.song(id: browser.selection.first ?? nil) else { return .ignored }
            model.player.toggle(s.url)
            return .handled
        }
        .overlay {
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
    }
}

struct SongDetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.musicBrowser.selection
        if ids.count == 1, let song = model.song(id: ids.first ?? nil) {
            SongDetail(song: song).id(song.id)
        } else if ids.count > 1 {
            ContentUnavailableView("\(ids.count) Songs Selected", systemImage: "square.stack")
        } else {
            ContentUnavailableView("No Song Selected", systemImage: "music.note",
                                   description: Text("Select a song to hear it and see its tempo and key."))
        }
    }
}

struct SongDetail: View {
    @Environment(AppModel.self) private var model
    let song: SongRecord

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
                if song.bpm == nil && song.key == nil {
                    Text("Not analysed yet. Import the Phase 0 results (File ▸ Import Phase 0 Music Analysis…). "
                        + "Earmark will analyse new songs itself in a later version.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        tempo
                        key
                    }
                    Button("Find Songs That Mix With This") { model.musicBrowser.findMixes(for: song) }
                }
                InfoGrid([
                    ("Album", song.album),
                    ("Length", formatLength(song.duration, precise: false)),
                    ("Analysis", song.analysisSource),
                    ("Folder", song.folder),
                    ("File", song.fileName),
                ])
                FileActions(url: song.url, online: online)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tempo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Tempo").font(.caption).foregroundStyle(.secondary)
            Text(song.bpm.map { "\(formatBPM($0)) BPM" } ?? "No steady beat")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            if song.tempoStability == "variable", let lo = song.bpmLow, let hi = song.bpmHigh {
                Text("Changes: \(formatBPM(lo))–\(formatBPM(hi))").font(.callout).foregroundStyle(.secondary)
            }
            if let beats = song.beatsPerBar {
                Text("\(beats) beats per bar").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Key").font(.caption).foregroundStyle(.secondary)
            if let k = song.key {
                Text("\(k.name) · \(k.camelot)").font(.title3.weight(.semibold))
                Text("Or \(k.relative.name) (\(k.relative.camelot)), its relative key: same notes, and the most common mix-up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Unknown").font(.title3.weight(.semibold))
            }
        }
    }
}
