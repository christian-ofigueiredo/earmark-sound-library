import AppKit
import EarmarkCore
import EarmarkML
import SwiftUI

enum SoundScope: Hashable, Sendable {
    case all
    case library(Int64)
    case category(String)
    case catID(String)
    case uncategorised
    /// Sounds whose category is Earmark's guess for their folder.
    case guessed
    /// The sounds most like this one (Find Similar Sounds).
    case similar(Int64)
    /// A similarity group inside a subcategory.
    case group(Int64)
    /// Sounds whose category is Earmark's guess from how they sound, and the owner's for one sound.
    case guessedFromSound, chosenByYou
    /// Sounds that are the same as another (`Duplicates`), each set together.
    case duplicates
}

/// What the sound list shows: scope, search, sort and selection.
@MainActor @Observable
final class SoundBrowser {
    var scope: SoundScope? = .all {
        didSet { if case .catID(let c) = scope { lastSubcategory = c } }
    }
    /// The last subcategory shown, to go back to when its group goes.
    private(set) var lastSubcategory: String?
    var search = ""
    var selection: Set<SoundRecord.ID> = []
    var sortOrder = [KeyPathComparator(\SoundRecord.displayName)]
    private(set) var visible: [SoundRecord] = []

    /// The last Find Similar Sounds: the sound it started from and its matches' cosine scores.
    struct Similar: Equatable {
        var source: Int64
        var name: String
        var scores: [Int64: Float]
    }
    private(set) var similar: Similar?

    var isShowingSimilar: Bool { if case .similar = scope { true } else { false } }

    /// Counts the refreshes of `visible`, so the list knows when to reload.
    private(set) var generation = 0
    /// Bumped by `reveal`: the list scrolls to the selection.
    private(set) var revealRequest = 0

    /// Selects this sound and scrolls the list to it, showing all sounds if the list hides it.
    func reveal(_ id: SoundRecord.ID) {
        if !visible.contains(where: { $0.id == id }) {
            search = ""
            scope = .all
        }
        selection = [id]
        revealRequest += 1
    }

    /// Scrolls the list to the selection: back from the map, where it may have changed.
    func revealSelection() { revealRequest += 1 }

    // The sidebar's Similar row is never added or removed while it's selected: done in one
    // update, the sidebar left a copy of the row drawn over it (its text doubled, in the
    // selected and plain styles), which also took the first click on its ✕.

    func showSimilar(_ result: Similar) {
        similar = result
        search = ""
        selection = [result.source]
        // Selected once the row is in the sidebar.
        DispatchQueue.main.async { if self.similar == result { self.scope = .similar(result.source) } }
    }

    func clearSimilar() {
        if isShowingSimilar { scope = .all }
        // Removed once it's no longer selected.
        let cleared = similar
        DispatchQueue.main.async { if self.similar == cleared { self.similar = nil } }
    }

    /// "87%" for a match, "Source" for the sound the search started from, "" otherwise.
    func matchText(_ s: SoundRecord) -> String {
        guard let similar, let id = s.id else { return "" }
        if id == similar.source { return "Source" }
        return similar.scores[id].map { "\(Int(($0 * 100).rounded()))%" } ?? ""
    }

    struct FilterKey: Hashable {
        var scope: SoundScope?
        var search: String
        var sortOrder: [KeyPathComparator<SoundRecord>]
        var version: Int
        /// The groups' version, while a group is shown.
        var groups: Int
    }

    func filterKey(version: Int, groups: Int = 0) -> FilterKey {
        let showsGroup = if case .group = scope { true } else { false }
        return FilterKey(scope: scope, search: search, sortOrder: sortOrder, version: version, groups: showsGroup ? groups : 0)
    }

    /// Filters and sorts off the main thread (tens of milliseconds for the whole library).
    func refresh(from model: AppModel) async {
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let scope = self.scope ?? .all, order = sortOrder, scores = similar?.scores
        let sounds = model.sounds, haystacks = model.soundIndex.haystacks, hidden = model.soundIndex.twins.hidden
        let membership = model.groups.membership, duplicateSets = model.duplicates.setOf
        let result = await Task.detached(priority: .userInitiated) {
            Self.filtered(sounds, haystacks: haystacks, hidden: hidden, scope: scope, terms: terms, scores: scores,
                          membership: membership, duplicateSets: duplicateSets, order: order)
        }.value
        guard !Task.isCancelled else { return }
        visible = result
        generation += 1
        // Drop selected sounds the new filter hides, so the detail pane doesn't show them.
        let kept = selection.intersection(visible.map(\.id))
        if kept != selection { selection = kept }
    }

    nonisolated static func filtered(_ sounds: [SoundRecord], haystacks: [String], hidden: Set<Int64>,
                                             scope: SoundScope, terms: [String], scores: [Int64: Float]?,
                                             membership: [Int64: Int64] = [:], duplicateSets: [Int64: Int] = [:],
                                             order: [KeyPathComparator<SoundRecord>]) -> [SoundRecord] {
        let found = sounds.indices.filter { i in
            let s = sounds[i]
            if let id = s.id, hidden.contains(id) { return false }
            switch scope {
            case .all: break
            case .library(let id): if s.libraryId != id { return false }
            case .category(let c): if s.category != c { return false }
            case .catID(let c): if s.catID != c { return false }
            case .uncategorised: if s.catID != nil { return false }
            case .guessed: if s.categorySource != FolderRules.guessSource { return false }
            case .guessedFromSound: if s.categorySource != SoundCategories.soundGuessSource { return false }
            case .chosenByYou: if s.categorySource != SoundCategories.ownerSource { return false }
            case .duplicates: guard let id = s.id, duplicateSets[id] != nil else { return false }
            case .similar(let source):
                guard let id = s.id, id == source || scores?[id] != nil else { return false }
            case .group(let g):
                guard let id = s.id, membership[id] == g else { return false }
            }
            return terms.allSatisfy { haystacks[i].contains($0) }
        }
        var result = FastSort.sorted(found.map { sounds[$0] }, by: order)
        if case .duplicates = scope {
            // Each set together, in the list's order inside it; sets by their first sound there.
            var first: [Int: Int] = [:]
            for (i, s) in result.enumerated() { if let set = duplicateSets[s.id ?? -1], first[set] == nil { first[set] = i } }
            let position = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id ?? -1, $0.offset) })
            result.sort { a, b in
                let fa = first[duplicateSets[a.id ?? -1] ?? -1] ?? 0, fb = first[duplicateSets[b.id ?? -1] ?? -1] ?? 0
                return fa != fb ? fa < fb : position[a.id ?? -1, default: 0] < position[b.id ?? -1, default: 0]
            }
        }
        if case .similar(let source) = scope, let scores {
            // Best match first, the sound it started from at the top.
            result.sort { a, b in
                let sa = a.id == source ? 2 : scores[a.id ?? -1] ?? -2
                let sb = b.id == source ? 2 : scores[b.id ?? -1] ?? -2
                return sa > sb
            }
        }
        return result
    }
}

struct SoundSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Built once the library has been read, so its rows arrive all at once. Built before,
        // the ~60 category rows were inserted into the list on screen a few seconds after
        // launch, and AppKit logged "a reentrant operation in its NSTableView delegate" while
        // SwiftUI's list measured them (owner, 2026-10-26; found with the debugger).
        if model.hasLoaded { list } else { Color.clear }
    }

    private var list: some View {
        @Bindable var browser = model.soundBrowser
        return List(selection: $browser.scope) {
            Label("All Sounds", systemImage: "square.grid.2x2")
                .badge(model.soundIndex.shownCount)
                .tag(SoundScope.all)
            Section("Libraries") {
                ForEach(model.soundLibraries) { lib in
                    LibraryRow(library: lib, count: model.soundIndex.libraryCounts[lib.id ?? -1] ?? 0,
                               scanning: model.isScanning(lib))
                        .tag(SoundScope.library(lib.id ?? -1))
                        .contextMenu { LibraryMenu(library: lib) }
                }
                Button {
                    model.chooseLibrary(.sounds)
                } label: {
                    Label("Add Library…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                if !model.duplicates.setOf.isEmpty {
                    Label("Duplicates", systemImage: "doc.on.doc")
                        .badge(model.duplicates.setOf.count)
                        .tag(SoundScope.duplicates)
                        .help("Sounds that are in the libraries more than once: copies of one file, or the same recording "
                              + "under another name. Earmark only shows them; it never deletes files.")
                }
            }
            if let similar = browser.similar {
                Section("Similar") {
                    HStack {
                        Label("Similar to “\(similar.name)”", systemImage: "waveform.path.ecg")
                            .lineLimit(1)
                        Spacer()
                        Button {
                            browser.clearSimilar()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                    }
                    .badge(similar.scores.count)
                    .tag(SoundScope.similar(similar.source))
                }
            }
            if !model.sounds.isEmpty {
                Section("Categories") {
                    OutlineGroup(model.categoryTree, children: \.children) { node in
                        if case .group(let id) = node.id, let group = model.groups.byId[id] {
                            Text(node.title).badge(node.count).tag(node.id)
                                .help(([group.title, "sounds that sound alike"] + group.keywordList.map { "#\($0)" })
                                    .joined(separator: " · "))
                                .contextMenu { GroupMenu(group: group) }
                        } else {
                            Text(node.title).badge(node.count).tag(node.id)
                        }
                    }
                    if model.soundIndex.guessed > 0 {
                        Label("Guessed by Earmark", systemImage: "wand.and.stars")
                            .badge(model.soundIndex.guessed)
                            .tag(SoundScope.guessed)
                            .help("Sounds whose category Earmark guessed from their folder: change any in Folder Categories")
                    }
                    if model.soundIndex.guessedFromSound > 0 {
                        Label("Guessed from the Sound", systemImage: "waveform.badge.magnifyingglass")
                            .badge(model.soundIndex.guessedFromSound)
                            .tag(SoundScope.guessedFromSound)
                            .help("Sounds that don't sound like their folder's category: Earmark gave them the one the most similar sounds have. Worth a listen.")
                    }
                    if model.soundIndex.chosenByYou > 0 {
                        Label("Chosen by You", systemImage: "person.crop.circle.badge.checkmark")
                            .badge(model.soundIndex.chosenByYou)
                            .tag(SoundScope.chosenByYou)
                            .help("Sounds you gave a category one by one")
                    }
                    Label("Not Categorised Yet", systemImage: "questionmark.folder")
                        .badge(model.soundIndex.uncategorised)
                        .tag(SoundScope.uncategorised)
                    MapFoldersButton()
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SoundTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.soundBrowser
        // Hidden (in AppKit) while the map is in its place.
        let shown = model.section == .sounds && !model.soundMap.showing
        let faded = model.sectionFaded
        let playing = model.playingSound
        RecordTable(rows: browser.visible, rowsVersion: browser.generation, filter: browser.filterKey(version: 0),
                    columns: Self.columns(browser), hiddenColumns: browser.isShowingSimilar ? [] : ["match"],
                    selection: $browser.selection, sortOrder: $browser.sortOrder, shown: shown,
                    autosaveName: "Sounds", accessibilityLabel: "Sounds", url: \.url,
                    menu: { ids in menu(for: ids) },
                    primaryAction: { ids in if let s = model.sound(id: ids.first ?? nil) { model.player.toggle(s.url) } },
                    arrowKeys: { model.skip(forward: $0, more: $1) },
                    playing: playing?.id, playingPaused: !model.player.isPlaying, revealRequest: browser.revealRequest, faded: faded)
        .overlay {
            Group {
                if model.soundLibraries.isEmpty {
                    ContentUnavailableView {
                        Label("No Sound Libraries Yet", systemImage: "waveform")
                    } description: {
                        Text("Add the folders where your sound effects live. Earmark reads their metadata and never changes them.")
                    } actions: {
                        Button("Add Sound Library…") { model.chooseLibrary(.sounds) }
                    }
                } else if browser.visible.isEmpty && !browser.search.isEmpty {
                    ContentUnavailableView.search(text: browser.search)
                } else if browser.visible.isEmpty && model.scanning.isEmpty {
                    ContentUnavailableView("No Sounds Here", systemImage: "tray")
                }
            }
            .shown(shown && !faded)
        }
        .onChange(of: model.soundMap.showing) { _, map in if !map { browser.revealSelection() } }
    }

    private static func columns(_ browser: SoundBrowser) -> [RecordColumn<SoundRecord>] {
        [
            // Shown only for Find Similar Sounds.
            RecordColumn(id: "match", title: "Match", minWidth: 50, width: 56, maxWidth: 70, digits: true,
                         secondary: true, canHide: false) { browser.matchText($0) },
            RecordColumn(id: "name", title: "Name", width: 240, sort: KeyPathComparator(\.displayName),
                         canHide: false, typeSelect: true, marksPlaying: true) { $0.displayName },
            RecordColumn(id: "category", title: "Category", width: 170, sort: KeyPathComparator(\.categoryText)) { $0.categoryText },
            RecordColumn(id: "length", title: "Length", minWidth: 50, width: 64, maxWidth: 90,
                         sort: KeyPathComparator(\.durationValue), digits: true) { formatLength($0.duration) },
            RecordColumn(id: "folder", title: "Folder", width: 220, sort: KeyPathComparator(\.folder)) { $0.folder },
            RecordColumn(id: "format", title: "Format", minWidth: 80, width: 150, sort: KeyPathComparator(\.formatText)) { $0.formatText },
        ]
    }

    private func menu(for ids: Set<SoundRecord.ID>) -> [RecordMenuItem] {
        let picked = ids.compactMap { model.sound(id: $0) }
        var items: [RecordMenuItem] = []
        if picked.count == 1, let s = picked.first {
            items.append(.action("Play") { model.player.play(s.url) })
            items.append(.action("Find Similar Sounds", enabled: model.canFindSimilar(s)) { model.findSimilar(to: s) })
            items.append(.action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) })
        } else if !picked.isEmpty {
            items.append(.action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url)) })
        }
        if !picked.isEmpty {
            items.append(.action(picked.count == 1 ? "Copy Path" : "Copy Paths") {
                copyToPasteboard(picked.map(\.path).joined(separator: "\n"))
            })
        }
        if !picked.isEmpty {
            let ids = picked.compactMap(\.id)
            items.append(.divider)
            items.append(.action(picked.count == 1 ? "Set Category…" : "Set Category for \(picked.count) Sounds…") {
                model.categoryChoosing = CategoryChoosing(sounds: ids)
            })
            let mine = picked.filter { $0.categorySource == SoundCategories.ownerSource }.compactMap(\.id)
            if !mine.isEmpty {
                items.append(.action("Remove Your Category") { model.setCategory(mine, to: nil) })
            }
        }
        items += groupMenuItems(for: picked, model: model)
        return items
    }
}

struct SoundDetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.soundBrowser.selection
        if ids.count == 1, let sound = model.sound(id: ids.first ?? nil) {
            SoundDetail(sound: sound).id(sound.id).transition(.identity)
        } else if ids.count > 1 {
            ContentUnavailableView("\(ids.count) Sounds Selected", systemImage: "square.stack").transition(.identity)
        } else {
            ContentUnavailableView("No Sound Selected", systemImage: "waveform",
                                   description: Text("Select a sound to hear it. Drag it into DaVinci Resolve to use it."))
                .transition(.identity)
        }
    }
}

struct SoundDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let sound: SoundRecord

    /// The folder whose choice or guess gave this sound its category (or its own folder).
    private var ruleKey: FolderMapper.Key {
        let folders: [String] = switch sound.categorySource {
        case FolderRules.source: model.folderRules.filter { $0.libraryId == sound.libraryId }.map(\.folder)
        case FolderRules.guessSource: model.folderGuesses.filter { $0.libraryId == sound.libraryId }.map(\.folder)
        default: []
        }
        return FolderMapper.Key(libraryId: sound.libraryId,
                                folder: FolderRules.ruleFolder(for: sound.folder, in: Set(folders)) ?? sound.folder)
    }

    /// Opens Folder Categories on this sound's folder (or the one that categorised it).
    private func mapFolder() {
        model.folderMapper.focus(ruleKey)
        openWindow(id: FolderMapView.windowID)
    }

    /// Why Earmark guessed this sound's category, if it did.
    private var guess: FolderGuess? {
        guard sound.categorySource == FolderRules.guessSource else { return nil }
        let key = ruleKey
        return model.folderGuesses.first { $0.libraryId == key.libraryId && $0.folder == key.folder }
    }

    /// Why Earmark gave this sound its category from how it sounds.
    private var soundGuessReason: String {
        guard let choice = model.soundChoices[sound.id ?? -1] else { return "" }
        let label = { (catID: String?) in UCSCatalog.shared.entry(catID: catID)?.label.capitalized ?? catID ?? "" }
        let share = Int(((choice.share ?? 0) * 100).rounded())
        return "It doesn't sound like its folder's category (\(label(choice.replaced))): \(share)% of the most similar sounds "
            + "in other folders are \(label(choice.catID))."
    }

    /// Which embeddings this sound has ("CLAP, PE-AV"), or nil.
    private func embeddingText(for sound: SoundRecord) -> String? {
        let id = sound.id ?? -1
        let done = [
            SoundEmbedding.isCurrent(model.analysis.clapStatus[id], model: ClapEmbedder.modelName, for: sound) ? "CLAP" : nil,
            SoundEmbedding.isCurrent(model.analysis.peavStatus[id], model: PeavEmbedder.modelName, for: sound) ? "PE-AV" : nil,
        ].compactMap { $0 }
        return done.isEmpty ? nil : done.joined(separator: ", ")
    }

    var body: some View {
        let online = model.isOnline(libraryId: sound.libraryId)
        DetailScroll {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sound.displayName)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    if let label = sound.ucsLabel {
                        HStack(spacing: 6) {
                            Text(label.capitalized).font(.callout.weight(.medium))
                            if let catID = sound.catID {
                                Text(catID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        GroupLine(sound: sound)
                        HStack(spacing: 6) {
                            if let guess {
                                Text("Guessed by Earmark")
                                    .help("From its folder: \(guess.reason)")
                            } else if sound.categorySource == SoundCategories.soundGuessSource {
                                Text("Guessed by Earmark from how it sounds")
                                    .help(soundGuessReason)
                            } else if sound.categorySource == SoundCategories.ownerSource {
                                Text("Chosen by you")
                            } else if let source = sound.categorySource {
                                Text("Category from \(source)")
                            }
                            CategoryChangeMenu(sound: sound, title: "Change", mapFolder: mapFolder)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Text("Not categorised yet").foregroundStyle(.secondary)
                            CategoryChangeMenu(sound: sound, title: "Choose a Category", mapFolder: mapFolder)
                        }
                        .font(.callout)
                    }
                }
                if online {
                    PlayerPanel(url: sound.url, knownDuration: sound.duration)
                    FileChip(url: sound.url)
                    OtherFormats(sound: sound)
                    SameSounds(sound: sound)
                } else {
                    OfflineNotice(library: model.library(id: sound.libraryId))
                }
                InfoGrid([
                    ("Description", sound.details),
                    ("Keywords", sound.keywords),
                    ("Library", sound.vendorLibrary),
                    ("Manufacturer", sound.manufacturer),
                    ("Designer", sound.designer),
                    ("Loudness", model.analysis.facts[sound.id ?? -1].flatMap { loudnessText($0, for: sound) }),
                    ("Embedding", embeddingText(for: sound)),
                    ("Format", sound.formatText),
                    ("Length", formatLength(sound.duration)),
                    ("Folder", sound.folder),
                    ("File", sound.fileName),
                ])
                Button {
                    model.findSimilar(to: sound)
                } label: {
                    Label("Find Similar Sounds", systemImage: "waveform.path.ecg")
                }
                .disabled(!model.canFindSimilar(sound))
                .help(model.canFindSimilar(sound) ? "Sounds that sound most like this one (CLAP)"
                                                  : "Available once this sound has been analysed")
                FileActions(url: sound.url, online: online)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Lower-quality copies of this sound (e.g. the MP3 next to the WAV), which the list hides.
struct OtherFormats: View {
    @Environment(AppModel.self) private var model
    let sound: SoundRecord

    var body: some View {
        let copies = (model.soundIndex.twins.alternates[sound.id ?? -1] ?? []).compactMap { model.sound(id: $0) }
        if !copies.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Also in this pack as").font(.caption).foregroundStyle(.secondary)
                ForEach(copies) { copy in FileChip(url: copy.url) }
            }
        }
    }
}

/// The sound's duplicates (`Duplicates`): copies of the file and the same recording elsewhere.
struct SameSounds: View {
    @Environment(AppModel.self) private var model
    let sound: SoundRecord

    var body: some View {
        let others = model.duplicates.others[sound.id ?? -1] ?? []
        let copies = others.filter(\.identical).compactMap { model.sound(id: $0.id) }
        let same = others.filter { !$0.identical }.compactMap { model.sound(id: $0.id) }
        if !copies.isEmpty { list("Copies of this file", copies) }
        if !same.isEmpty { list("The same recording", same) }
    }

    private func list(_ title: String, _ sounds: [SoundRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(sounds) { s in
                VStack(alignment: .leading, spacing: 2) {
                    FileChip(url: s.url)
                    Text([model.library(id: s.libraryId)?.name, s.folder].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(s.path)
                }
            }
        }
    }
}

/// "-18.2 LUFS · peak -0.4 dBFS", or nil while not measured yet.
func loudnessText(_ facts: SoundFacts, for sound: SoundRecord) -> String? {
    guard facts.isCurrent(for: sound) else { return nil }
    if facts.error != nil { return "Couldn't be measured" }
    guard let lufs = facts.loudness else { return "Silent" }
    let peak = facts.peak.map { String(format: " · peak %.1f dBFS", $0) } ?? ""
    return String(format: "%.1f LUFS", lufs) + peak
}
