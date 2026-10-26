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
    var folderRules: [FolderRule]
    var folderGuesses: [FolderGuess]

    init(_ db: LibraryDatabase) throws {
        libraries = try db.libraries()
        folderRules = try db.folderRules()
        folderGuesses = try db.folderGuesses()
        // Sounds with no category of their own take their folder's: the user's choice, or
        // else Earmark's guess (Folder Categories).
        sounds = FolderRules.apply(folderRules, guesses: folderGuesses, to: try db.sounds())
        soundIndex = SoundIndex(sounds)
        songs = try db.songs()
        songIndex = SongIndex(songs)
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
    let analysis = AnalysisEngine()

    /// The section on screen. Both sections stay built (`LibraryView`), so changing it costs
    /// about a frame and happens with the switch's animation.
    private(set) var section: AppSection
    var showWelcome: Bool
    var alert: AppAlert?

    private(set) var soundLibraries: [Library] = []
    private(set) var musicLibraries: [Library] = []
    private(set) var sounds: [SoundRecord] = []
    private(set) var soundIndex = SoundIndex([])
    private(set) var songs: [SongRecord] = []
    private(set) var songIndex = SongIndex([])
    private(set) var folderRules: [FolderRule] = []
    private(set) var folderGuesses: [FolderGuess] = []
    /// Earmark guessing categories for folders (status bar).
    var guessProgress: (done: Int, total: Int)?
    @ObservationIgnored private var guessing = false
    /// Bumped on every reload so the browsers refresh their lists.
    private(set) var version = 0
    private(set) var scanning: Set<Int64> = []
    private(set) var activity: String?
    private(set) var progress: Double?

    static let supportFolder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Earmark", isDirectory: true)

    init() {
        let defaults = UserDefaults.standard
        section = AppSection(rawValue: defaults.string(forKey: "section") ?? "") ?? .sounds
        showWelcome = !defaults.bool(forKey: "welcomeSeen")
        do {
            database = try LibraryDatabase(path: Self.supportFolder.appendingPathComponent("library.sqlite").path)
            startupError = nil
        } catch {
            database = nil
            startupError = "Earmark couldn't open its database in \(Self.supportFolder.path): \(error.localizedDescription)"
        }
        Task {
            await reload()
            analysis.start(model: self)
            // After the analysis has read which sounds it has done (the guesses note it).
            guessing = true
            folderGuesser.update(model: self)
        }
    }

    // MARK: sections

    /// The search field, shared by both sections: the shown one's search.
    var search: String {
        get { section == .music ? musicBrowser.search : soundBrowser.search }
        set { if section == .music { musicBrowser.search = newValue } else { soundBrowser.search = newValue } }
    }

    /// The section switch, ⌘1/⌘2 and anything else that changes section: the content changes at
    /// once and the switch's pill slides (`SectionSwitch` animates it on its own).
    func show(_ new: AppSection) {
        guard new != section else { return }
        section = new
    }

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
            folderRules = snap.folderRules
            folderGuesses = snap.folderGuesses
            version += 1
            analysis.libraryChanged()
            if guessing { folderGuesser.update(model: self) }
        } catch {
            show(error, title: "Couldn't read Earmark's database")
        }
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

    // MARK: Phase 0 music analysis

    func choosePhase0Import() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Choose music_analysis.json from a Phase 0 music report folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try Phase0MusicImport.read(Data(contentsOf: url))
            show(.music)
            Task { await applyPhase0(entries, offerFolder: true) }
        } catch {
            show(error, title: "Couldn't import “\(url.lastPathComponent)”")
        }
    }

    private func applyPhase0(_ entries: [Phase0MusicImport.Entry], offerFolder: Bool) async {
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
