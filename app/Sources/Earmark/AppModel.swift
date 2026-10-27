import AppKit
import EarmarkCore
import EarmarkML
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable {
    case sounds, music

    var title: String {
        switch self {
        case .sounds: "Sound Effects"
        case .music: "Music"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var actionTitle: String?
    var isDestructive = false
    var action: (@MainActor () -> Void)?
}

/// Everything read from the database in one go (off the main thread).
struct LibrarySnapshot: Sendable {
    var libraries: [Library]
    var sounds: [SoundRecord]
    var soundIndex: SoundIndex
    var songs: [SongRecord]
    var songIndex: SongIndex
    var songCorrections: [String: SongCorrection]
    var folderRules: [FolderRule]
    var folderGuesses: [FolderGuess]
    var soundChoices: [Int64: SoundCategoryChoice]
    var groups: SoundGroupSnapshot

    init(_ db: LibraryDatabase) throws {
        libraries = try db.libraries()
        folderRules = try db.folderRules()
        folderGuesses = try db.folderGuesses()
        // Sounds with no category of their own take their folder's: the user's choice, or
        // else Earmark's guess (Folder Categories). Then single sounds' categories: the owner's
        // over anything, Earmark's from how a sound sounds over its folder's guess.
        soundChoices = try db.soundCategoryChoices()
        sounds = SoundCategories.apply(soundChoices, to: FolderRules.apply(folderRules, guesses: folderGuesses, to: try db.sounds()))
        soundIndex = SoundIndex(sounds)
        // Songs show the tempo, key and beats per bar the user set by hand over what was analysed.
        songCorrections = Dictionary(try db.songCorrections().map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        songs = SongCorrections.apply(songCorrections, to: try db.songs())
        songIndex = SongIndex(songs)
        groups = try db.soundGroupSnapshot()
    }
}

/// App state shared by both windows' sections. Earmark only ever writes to its
/// own database; sound and music files are opened read-only.
@MainActor @Observable
final class AppModel {
    let database: LibraryDatabase?
    let startupError: String?
    let player = AudioPlayer()
    let soundBrowser = SoundBrowser()
    let musicBrowser = MusicBrowser()
    let folderMapper = FolderMapper()
    let folderGuesser = FolderGuesser()
    let groupBuilder = GroupBuilder()
    let soundGuesser = SoundGuesser()
    let analysis = AnalysisEngine()

    /// The library has been read once since launch (the sidebars are built then).
    private(set) var hasLoaded = false
    /// The section on screen. Both sections stay built (`LibraryView`).
    private(set) var section: AppSection
    /// The section the switch shows: it changes first, then `section` once the content has
    /// faded out (`show`).
    private(set) var switchSection: AppSection
    /// The shown section's content is faded out, during a switch.
    private(set) var sectionFaded = false
    @ObservationIgnored private var switching: Task<Void, Never>?
    var showWelcome: Bool
    var alert: AppAlert?
    /// The sound list as a map (View ▸ Sound Map).
    let soundMap = SoundMapState()
    /// File ▸ Export Analysis…'s sheet, while it's open.
    var exportRequest: ExportRequest?
    /// The waveform's selection in the detail pane, in seconds (for File ▸ Add to DaVinci Resolve Timeline).
    @ObservationIgnored var playerSelection: (url: URL, range: ClosedRange<Double>)?

    private(set) var soundLibraries: [Library] = []
    private(set) var musicLibraries: [Library] = []
    private(set) var sounds: [SoundRecord] = []
    private(set) var soundIndex = SoundIndex([])
    private(set) var songs: [SongRecord] = []
    private(set) var songIndex = SongIndex([])
    /// Tempo, key and beats per bar set by hand, by file path (already applied to `songs`).
    private(set) var songCorrections: [String: SongCorrection] = [:]
    /// Corrections are saved one after another, so quick edits reach the database in order.
    @ObservationIgnored private var correctionWrites: Task<Void, Never>?
    private(set) var folderRules: [FolderRule] = []
    private(set) var folderGuesses: [FolderGuess] = []
    /// Categories for single sounds, the owner's and Earmark's (already applied to `sounds`).
    private(set) var soundChoices: [Int64: SoundCategoryChoice] = [:]
    /// The category chooser for selected sounds, while it's open.
    var categoryChoosing: CategoryChoosing?
    /// Earmark guessing categories for folders (status bar).
    var guessProgress: (done: Int, total: Int)?
    @ObservationIgnored private var guessing = false
    /// Similarity groups inside each subcategory (`GroupBuilder`).
    private(set) var groups = SoundGroupSnapshot()
    /// Bumped whenever the groups change, so lists and the sidebar refresh.
    private(set) var groupsVersion = 0
    /// Earmark making similarity groups (status bar).
    var groupProgress: (done: Int, total: Int)?
    /// The rename or new-group sheet, while it's open.
    var groupNaming: GroupNaming?
    /// The sidebar's categories → subcategories → groups (more than one), with counts.
    private(set) var categoryTree: [SidebarNode] = []
    /// Bumped on every reload so the browsers refresh their lists.
    private(set) var version = 0
    /// Bumped whenever the songs change (a reload, or Earmark's own tempo and key coming in).
    private(set) var songsVersion = 0
    private(set) var scanning: Set<Int64> = []
    /// The status bar's line about what Earmark is doing (scans, exports and imports of analysis).
    var activity: String?
    private(set) var progress: Double?

    static let supportFolder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Earmark", isDirectory: true)

    init() {
        let defaults = UserDefaults.standard
        let savedSection = AppSection(rawValue: defaults.string(forKey: "section") ?? "") ?? .sounds
        section = savedSection
        switchSection = savedSection
        showWelcome = !defaults.bool(forKey: "welcomeSeen")
        do {
            database = try LibraryDatabase(path: Self.supportFolder.appendingPathComponent("library.sqlite").path)
            startupError = nil
        } catch {
            database = nil
            startupError = "Earmark couldn't open its database in \(Self.supportFolder.path): \(error.localizedDescription)"
        }
        player.gain = { [weak self] url in self?.previewGain(for: url) ?? 0 }
        Task {
            await reload()
            hasLoaded = true
            analysis.start(model: self)
            // After the analysis has read which sounds it has done (the guesses note it).
            guessing = true
            folderGuesser.update(model: self)
            soundGuesser.update(model: self)
            groupBuilder.update(model: self)
        }
    }

    // MARK: sections

    /// The search field, shared by both sections: the shown one's search.
    var search: String {
        get { section == .music ? musicBrowser.search : soundBrowser.search }
        set { if section == .music { musicBrowser.search = newValue } else { soundBrowser.search = newValue } }
    }

    /// The section switch, ⌘1/⌘2 and anything else that changes section. The switch's pill
    /// slides while the content fades out; the section changes once both have finished (its
    /// layout is the one costly moment, ~0.1 s, more for the sound list); then the new content
    /// fades in. Changed sooner, mid-slide, the pill stuttered going back to Sound Effects.
    func show(_ new: AppSection) {
        guard new != switchSection else { return }
        switchSection = new
        switching?.cancel()
        switching = Task { [weak self] in
            guard let self else { return }
            withAnimation(Self.fadeOut) { sectionFaded = true }
            try? await Task.sleep(for: .milliseconds(Int(SectionSwitch.slide * 1000) + 20))
            guard !Task.isCancelled else { return }
            section = switchSection
            // The new section is laid out before it fades in, so the fade starts smoothly.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            withAnimation(Self.fadeIn) { sectionFaded = false }
        }
    }

    static let fadeOut = Animation.easeIn(duration: 0.15)
    static let fadeIn = Animation.easeOut(duration: 0.22)

    // MARK: reading

    func reload() async {
        guard let db = database else { return }
        do {
            let snap = try await Task.detached(priority: .userInitiated) { try LibrarySnapshot(db) }.value
            soundLibraries = snap.libraries.filter { $0.kind == .sounds }
            musicLibraries = snap.libraries.filter { $0.kind == .music }
            sounds = snap.sounds
            soundIndex = snap.soundIndex
            songs = snap.songs
            songIndex = snap.songIndex
            songCorrections = snap.songCorrections
            folderRules = snap.folderRules
            folderGuesses = snap.folderGuesses
            soundChoices = snap.soundChoices
            groups = snap.groups
            rebuildCategoryTree()
            version += 1
            songsVersion += 1
            groupsVersion += 1
            analysis.libraryChanged()
            if guessing {
                folderGuesser.update(model: self)
                soundGuesser.update(model: self)
                groupBuilder.update(model: self)
            }
        } catch {
            show(error, title: "Couldn't read Earmark's database")
        }
    }

    /// Songs whose analysis changed (Earmark's own tempo and key), updated in place without
    /// reading the whole library again.
    func updateSongs(_ updated: [SongRecord]) {
        guard !updated.isEmpty else { return }
        for rec in updated {
            if let id = rec.id, let i = songIndex.position[id] { songs[i] = rec.applying(songCorrections[rec.path]) }
        }
        songIndex = SongIndex(songs)
        songsVersion += 1
    }

    /// Corrects these songs' tempo, key or beats per bar by hand; Edit ▸ Undo takes it back.
    /// Only Earmark's database changes, and what was analysed stays (for Revert).
    func edit(_ edit: SongEdit, songs ids: [SongRecord.ID], undo: UndoManager?) {
        let picked = ids.compactMap { song(id: $0) }.filter { $0.allows(edit) }
        guard !picked.isEmpty else { return }
        let now = Date()
        setCorrections(picked.map { ($0.path, $0.correction(after: edit, at: now)) }, title: edit.title, undo: undo)
    }

    private func setCorrections(_ changes: [(path: String, correction: SongCorrection?)], title: String, undo: UndoManager?) {
        let before = changes.map { (path: $0.path, correction: songCorrections[$0.path]) }
        for (path, correction) in changes { songCorrections[path] = correction }
        let paths = Set(changes.map(\.path))
        for i in songs.indices where paths.contains(songs[i].path) { songs[i] = songs[i].applying(songCorrections[songs[i].path]) }
        songIndex = SongIndex(songs)
        songsVersion += 1
        if let db = database {
            let previous = correctionWrites
            correctionWrites = Task { [weak self] in
                await previous?.value
                do {
                    try await Task.detached(priority: .userInitiated) { try db.setSongCorrections(changes) }.value
                } catch {
                    self?.show(error, title: "Couldn't save the change")
                }
            }
        }
        // Undo puts back what was there; its own undo (Redo) puts this back.
        undo?.registerUndo(withTarget: self) { [weak undo] model in
            MainActor.assumeIsolated { model.setCorrections(before, title: title, undo: undo) }
        }
        undo?.setActionName(title)
    }

    func sound(id: SoundRecord.ID) -> SoundRecord? {
        guard let id else { return nil }
        return soundIndex.position[id].map { sounds[$0] }
    }

    func song(id: SongRecord.ID) -> SongRecord? {
        guard let id else { return nil }
        return songIndex.position[id].map { songs[$0] }
    }

    /// The sound the player has (playing or paused), if it's a sound.
    /// Plays sound effects at the same loudness (Preferences): the gain, dB, that brings a sound
    /// to the chosen loudness, keeping its peaks below −1 dBFS. Only playback in Earmark: the
    /// file isn't changed. Songs, and sounds not measured yet, play as they are.
    func previewGain(for url: URL) -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Preferences.normalizeKey) as? Bool ?? true else { return 0 }
        let target = defaults.object(forKey: Preferences.loudnessKey) as? Double ?? Preferences.defaultLoudness
        let path = url.path
        guard let sound = sounds.first(where: { $0.path == path }), let id = sound.id,
              let facts = analysis.facts[id], facts.isCurrent(for: sound), let loudness = facts.loudness else { return 0 }
        var gain = target - loudness
        if let peak = facts.peak { gain = min(gain, -1 - peak) }
        return max(-40, min(gain, 48))
    }

    var playingSound: SoundRecord? {
        guard player.state != .stopped, let path = player.url?.path else { return nil }
        return sounds.first { $0.path == path }
    }

    /// The song the player has (playing or paused), if it's a song.
    var playingSong: SongRecord? {
        guard player.state != .stopped, let path = player.url?.path else { return nil }
        return songs.first { $0.path == path }
    }

    func library(id: Int64) -> Library? {
        soundLibraries.first { $0.id == id } ?? musicLibraries.first { $0.id == id }
    }

    func isOnline(libraryId: Int64) -> Bool { library(id: libraryId)?.isOnline ?? false }

    func isScanning(_ library: Library) -> Bool { library.id.map(scanning.contains) ?? false }

    // MARK: adding and removing folders

    func chooseLibrary(_ kind: Library.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = kind == .sounds
            ? "Choose folders of sound effects. Earmark only reads them; nothing is changed."
            : "Choose folders of music. Earmark only reads them; nothing is changed."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let lib = addLibrary(url, kind: kind) { startScan(lib) }
        }
    }

    /// Adds a folder, or explains why not when it overlaps one already added.
    @discardableResult
    func addLibrary(_ url: URL, kind: Library.Kind) -> Library? {
        let path = url.standardizedFileURL.path
        let existing = kind == .sounds ? soundLibraries : musicLibraries
        if let same = existing.first(where: { $0.path == path }) { return same }
        if let outer = existing.first(where: { path.hasPrefix($0.path + "/") }) {
            alert = AppAlert(title: "Already in Earmark",
                             message: "“\(url.lastPathComponent)” is inside “\(outer.name)”, which Earmark already reads.")
            return nil
        }
        let inner = existing.filter { $0.path.hasPrefix(path + "/") }
        if !inner.isEmpty {
            let names = inner.map { "“\($0.name)”" }.joined(separator: ", ")
            alert = AppAlert(
                title: "Read the whole folder instead?",
                message: "“\(url.lastPathComponent)” contains \(names), already in Earmark. Earmark will replace "
                    + "\(inner.count == 1 ? "it" : "them") with the whole folder. No files are changed.",
                actionTitle: "Replace"
            ) { [weak self] in
                guard let self else { return }
                for lib in inner { self.forget(lib) }
                if let lib = self.insertLibrary(url, kind: kind) { self.startScan(lib) }
            }
            return nil
        }
        return insertLibrary(url, kind: kind)
    }

    private func insertLibrary(_ url: URL, kind: Library.Kind) -> Library? {
        guard let db = database else { return nil }
        do {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let lib = try db.addLibrary(kind: kind, path: url.standardizedFileURL.path, bookmark: bookmark)
            if kind == .sounds {
                soundLibraries = (soundLibraries + [lib]).sorted { $0.path < $1.path }
            } else {
                musicLibraries = (musicLibraries + [lib]).sorted { $0.path < $1.path }
            }
            return lib
        } catch {
            show(error, title: "Couldn't add “\(url.lastPathComponent)”")
            return nil
        }
    }

    func confirmRemove(_ library: Library) {
        alert = AppAlert(
            title: "Remove “\(library.name)” from Earmark?",
            message: "Earmark forgets this folder and what it knows about its files. The files themselves aren't touched.",
            actionTitle: "Remove", isDestructive: true
        ) { [weak self] in
            guard let self else { return }
            self.forget(library)
            Task { await self.reload() }
        }
    }

    private func forget(_ library: Library) {
        guard let db = database, let id = library.id else { return }
        do {
            try db.removeLibrary(id: id)
            soundLibraries.removeAll { $0.id == id }
            musicLibraries.removeAll { $0.id == id }
        } catch {
            show(error, title: "Couldn't remove “\(library.name)”")
        }
    }

    // MARK: scanning (reads headers and tags only)

    func startScan(_ library: Library) {
        Task { await scan(library) }
    }

    func rescanAll() {
        Task {
            for lib in soundLibraries + musicLibraries where lib.isOnline { await scan(lib) }
        }
    }

    func scan(_ library: Library) async {
        guard let db = database, let id = library.id, !scanning.contains(id) else { return }
        guard library.isOnline else {
            alert = AppAlert(title: "“\(library.name)” is offline",
                             message: "Connect the drive and try again. Earmark keeps what it already knows about these files.")
            return
        }
        let name = library.name, root = library.url
        let known = library.kind == .sounds ? soundIndex.libraryCounts[id, default: 0] : songIndex.libraryCounts[id, default: 0]
        scanning.insert(id)
        activity = "Reading “\(name)”…"
        progress = nil
        let report: @Sendable (Int, Int) -> Void = { done, total in
            guard done == total || done.isMultiple(of: 25) else { return }
            Task { @MainActor in self.updateProgress(name: name, done: done, total: total) }
        }
        do {
            switch library.kind {
            case .sounds:
                let found = await LibraryScanner(fallback: SoundFiles.technical).scan(root: root, progress: report)
                if confirmScanResult(found.count, known: known, library: library) {
                    try await Task.detached { try db.replaceSounds(libraryId: id, root: root, scanned: found) }.value
                }
            case .music:
                let found = await MusicFiles.read(root: root, progress: report)
                if confirmScanResult(found.count, known: known, library: library) {
                    try await Task.detached { try db.replaceSongs(libraryId: id, root: root, files: found) }.value
                }
            }
        } catch {
            show(error, title: "Couldn't save what was read from “\(name)”")
        }
        scanning.remove(id)
        if scanning.isEmpty {
            activity = nil
            progress = nil
        }
        await reload()
    }

    /// Guards against wiping a library when its drive goes away mid-scan.
    private func confirmScanResult(_ found: Int, known: Int, library: Library) -> Bool {
        guard library.isOnline else {
            alert = AppAlert(title: "“\(library.name)” went offline",
                             message: "The drive disconnected while Earmark was reading it. Nothing was changed in Earmark.")
            return false
        }
        if found == 0 && known > 0 {
            alert = AppAlert(title: "No audio files found in “\(library.name)”",
                             message: "Earmark kept its \(known.formatted()) entries in case the folder is temporarily empty.")
            return false
        }
        return true
    }

    private func updateProgress(name: String, done: Int, total: Int) {
        guard !scanning.isEmpty else { return }
        activity = "Reading “\(name)”: \(done.formatted()) of \(total.formatted()) files"
        progress = total > 0 ? Double(done) / Double(total) : nil
    }

    // MARK: Phase 0 music analysis (read by File ▸ Import Analysis…, `chooseImport`)

    func applyPhase0(_ entries: [Phase0MusicImport.Entry], offerFolder: Bool) async {
        guard let db = database else { return }
        do {
            let matched = try await Task.detached { try db.applySongAnalysis(entries) }.value
            await reload()
            if matched < entries.count, offerFolder,
               let folder = Self.commonFolder(of: entries.compactMap(\.path)),
               !musicLibraries.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) {
                alert = AppAlert(
                    title: "Add the music folder too?",
                    message: "\(matched) of \(entries.count) songs matched. The rest are in “\(folder.path)”, "
                        + "which isn't in Earmark yet. Add it (Earmark only reads it) and finish the import?",
                    actionTitle: "Add Folder and Import"
                ) { [weak self] in
                    guard let self, let lib = self.addLibrary(folder, kind: .music) else { return }
                    Task {
                        await self.scan(lib)
                        await self.applyPhase0(entries, offerFolder: false)
                    }
                }
            } else {
                alert = AppAlert(
                    title: "Imported tempo and key for \(matched) of \(entries.count) songs",
                    message: matched < entries.count
                        ? "Songs that didn't match aren't in a music folder in Earmark. Add their folder, then import again."
                        : "The results are in the Music section. Nothing was recalculated.")
            }
        } catch {
            show(error, title: "Couldn't import the analysis")
        }
    }

    /// The deepest folder holding all of these files, if it's narrower than a whole disk or home folder.
    static func commonFolder(of paths: [String]) -> URL? {
        let dirs = paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = dirs.first else { return nil }
        for d in dirs.dropFirst() {
            var n = 0
            while n < common.count, n < d.count, common[n] == d[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        let url = URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard common.count >= 3, url.path != home else { return nil }
        return url
    }

    // MARK: find similar

    /// CLAP vectors of every analysed sound, loaded on first use.
    private var similarity: SimilarityIndex?
    /// How many CLAP results existed when `similarity` was built (rebuilt when more arrive).
    private var similarityBuiltFor = -1

    /// The CLAP index, built on first use and again when more sounds have been analysed.
    func similarityIndex() async throws -> SimilarityIndex? {
        guard let db = database else { return nil }
        let analysed = analysis.clapStatus.count
        if similarity == nil || similarityBuiltFor != analysed {
            let vectors = try await Task.detached(priority: .userInitiated) { try db.vectors(model: ClapEmbedder.modelName) }.value
            similarity = SimilarityIndex(vectors: vectors)
            similarityBuiltFor = analysed
        }
        return similarity
    }

    func canFindSimilar(_ sound: SoundRecord) -> Bool {
        SoundEmbedding.isCurrent(analysis.clapStatus[sound.id ?? -1], model: ClapEmbedder.modelName, for: sound)
    }

    /// Shows the 100 sounds closest to `sound` (CLAP, cosine), leaving out format twins
    /// already hidden from the list and byte-identical copies.
    func findSimilar(to sound: SoundRecord) {
        guard let id = sound.id else { return }
        Task {
            do {
                guard let index = try await similarityIndex(), index.contains(id) else { return }
                var excluded = soundIndex.twins.hidden
                if let fp = sound.fingerprint {
                    for s in sounds where s.fingerprint == fp && s.id != id { if let other = s.id { excluded.insert(other) } }
                }
                let skip = excluded
                let matches = await Task.detached(priority: .userInitiated) { index.nearest(to: id, count: 100, excluding: skip) }.value
                soundBrowser.showSimilar(.init(source: id, name: sound.displayName,
                                               scores: Dictionary(uniqueKeysWithValues: matches.map { ($0.id, $0.score) })))
            } catch {
                show(error, title: "Couldn't find similar sounds")
            }
        }
    }

    // MARK: similarity groups

    /// Reads the groups again (after `GroupBuilder` or the owner's changes).
    func reloadGroups() async {
        guard let db = database else { return }
        if let snap = try? await Task.detached(priority: .userInitiated, operation: { try db.soundGroupSnapshot() }).value {
            groups = snap
            rebuildCategoryTree()
            groupsVersion += 1
            // A group shown in the list that's gone (merged, emptied): its subcategory instead.
            if case .group(let g) = soundBrowser.scope, groups.byId[g] == nil {
                soundBrowser.scope = soundBrowser.lastSubcategory.map { .catID($0) } ?? .all
            }
        }
    }

    /// Counts each group's sounds in the list and hangs the groups under their subcategory.
    private func rebuildCategoryTree() {
        let hidden = soundIndex.twins.hidden
        var counts: [Int64: Int] = [:]
        for s in sounds {
            guard let id = s.id, !hidden.contains(id), let g = groups.membership[id],
                  groups.memberFingerprints[id] == .some(s.fingerprint) else { continue }
            counts[g, default: 0] += 1
        }
        categoryTree = soundIndex.categories.map { category in
            var c = category
            c.children = category.children?.map { sub in
                guard case .catID(let catID) = sub.id else { return sub }
                let groups = self.groups(catID: catID).filter { (counts[$0.id ?? -1] ?? 0) > 0 }
                guard groups.count > 1 else { return sub }
                var s = sub
                s.children = groups.map { SidebarNode(id: .group($0.id!), title: $0.title, count: counts[$0.id!] ?? 0) }
                return s
            }
            return c
        }
    }

    /// The group a sound is in, if it has one and its file hasn't changed since.
    func group(of sound: SoundRecord) -> SoundGroupRecord? {
        guard let id = sound.id, let g = groups.membership[id], groups.memberFingerprints[id] == .some(sound.fingerprint) else { return nil }
        return groups.byId[g]
    }

    /// A subcategory's groups, when it has more than one.
    func groups(catID: String?) -> [SoundGroupRecord] {
        guard let catID, let list = groups.groups[catID], list.count > 1 else { return [] }
        return list
    }

    /// Runs one of the owner's changes to the groups, then shows the result.
    private func changeGroups(_ title: String, _ change: @escaping @Sendable (LibraryDatabase) throws -> Void) {
        guard let db = database else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try change(db) }.value
            } catch {
                show(error, title: title)
            }
            await reloadGroups()
        }
    }

    func renameGroup(_ group: SoundGroupRecord, to name: String?) {
        guard let id = group.id else { return }
        changeGroups("Couldn't rename the group") { try $0.renameGroup(id, to: name) }
    }

    /// Moves sounds into a group of their subcategory (the others are left where they are).
    func move(_ ids: [Int64], to group: SoundGroupRecord) {
        guard let target = group.id else { return }
        let picked = ids.compactMap { sound(id: $0) }.filter { $0.catID == group.catID }.map { (id: $0.id!, fingerprint: $0.fingerprint) }
        guard !picked.isEmpty else { return }
        changeGroups("Couldn't move the sounds") { try $0.moveSounds(picked, toGroup: target) }
    }

    /// A new group of these sounds (all of one subcategory), then shows it.
    func newGroup(from ids: [Int64], name: String) {
        let picked = ids.compactMap { sound(id: $0) }
        guard let catID = picked.first?.catID, picked.allSatisfy({ $0.catID == catID }), let db = database else { return }
        let members = picked.map { (id: $0.id!, fingerprint: $0.fingerprint) }
        Task {
            do {
                let id = try await Task.detached(priority: .userInitiated) { try db.newGroup(catID: catID, name: name, sounds: members) }.value
                await reloadGroups()
                soundBrowser.scope = .group(id)
            } catch {
                show(error, title: "Couldn't make the group")
            }
        }
    }

    func merge(_ groups: [SoundGroupRecord], into target: SoundGroupRecord) {
        guard let t = target.id else { return }
        let ids = groups.compactMap(\.id).filter { $0 != t }
        if case .group(let shown) = soundBrowser.scope, ids.contains(shown) { soundBrowser.scope = .group(t) }
        changeGroups("Couldn't merge the groups") { try $0.mergeGroups(ids, into: t) }
    }

    /// Forgets a subcategory's groups and the owner's changes to them; Earmark groups it afresh.
    func confirmRegroup(catID: String, title: String) {
        alert = AppAlert(
            title: "Regroup “\(title)”?",
            message: "Earmark makes this subcategory's groups again from the sounds. Names you gave and sounds you moved are forgotten.",
            actionTitle: "Regroup", isDestructive: true
        ) { [weak self] in
            guard let self, let db = self.database else { return }
            if case .group(let g) = self.soundBrowser.scope, self.groups.byId[g]?.catID == catID { self.soundBrowser.scope = .catID(catID) }
            Task {
                try? await Task.detached(priority: .userInitiated) { try db.regroup(catID: catID) }.value
                await self.reloadGroups()
                self.groupBuilder.update(model: self)
            }
        }
    }

    // MARK: DaVinci Resolve

    /// Puts the file, or `range` of it (seconds), on Resolve's timeline at its playhead
    /// (`ResolveBridge`), and says where in the status bar.
    func addToResolve(_ url: URL, range: ClosedRange<Double>?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert = AppAlert(title: "The file isn't there", message: "Connect its drive, then try again.")
            return
        }
        let name = url.lastPathComponent
        activity = "Adding “\(name)” to DaVinci Resolve…"
        progress = nil
        Task {
            do {
                let placed = try await ResolveBridge.add(.init(path: url.path, start: range?.lowerBound, end: range?.upperBound))
                let done = "Added \(range == nil ? "“\(name)”" : "the selection") to “\(placed.timeline)” in DaVinci Resolve, track A\(placed.track)"
                activity = done
                try? await Task.sleep(for: .seconds(4))
                if activity == done { activity = nil }
            } catch {
                activity = nil
                show(error, title: "Couldn't add the sound to DaVinci Resolve")
            }
        }
    }

    // MARK: categories for single sounds

    /// The owner's category for these sounds (nil takes it away: the folder's, or the file's own,
    /// again). Earmark's database only.
    func setCategory(_ ids: [Int64], to catID: String?) {
        guard let db = database else { return }
        let picked = ids.compactMap { sound(id: $0) }.map { (id: $0.id!, fingerprint: $0.fingerprint) }
        guard !picked.isEmpty else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try db.setSoundCategory(picked, catID: catID) }.value
                await reload()
            } catch {
                show(error, title: "Couldn't save the category")
            }
        }
    }

    // MARK: folder rules

    /// Saves the user's categories for folders (stored in Earmark's database only) and reloads.
    func saveFolderRules(_ rules: [FolderRule]) {
        guard let db = database, !rules.isEmpty else { return }
        do {
            try db.save(rules)
            Task { await reload() }
        } catch {
            show(error, title: "Couldn't save the folder categories")
        }
    }

    /// Back to Earmark's guess (or no category, if it has none for the folder).
    func removeFolderRule(_ rule: FolderRule) {
        guard let db = database else { return }
        do {
            try db.removeFolderRule(libraryId: rule.libraryId, folder: rule.folder)
            Task { await reload() }
        } catch {
            show(error, title: "Couldn't remove the folder category")
        }
    }

    // MARK: messages

    func show(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    func finishWelcome() {
        showWelcome = false
        UserDefaults.standard.set(true, forKey: "welcomeSeen")
    }
}
