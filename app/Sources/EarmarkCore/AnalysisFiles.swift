import Foundation
import GRDB

/// What Earmark worked out for one library or music folder, in a file, to take it to another
/// Mac without analysing again (docs/analysis-file-format.md). Items are matched by content
/// (fingerprints), not by path, and an import only fills gaps: what's already there, and the
/// user's own choices and corrections, are never overwritten. Written outside the libraries
/// only; nothing is ever written inside them.
public struct AnalysisFile: Codable, Sendable {
    public static let formatName = "earmark-analysis"
    public static let currentVersion = 1
    public static let fileExtension = "earmark-analysis.json"

    public var format = formatName
    public var version = currentVersion
    public var exportedAt: Date
    public var library: LibraryInfo
    public var sounds: [Sound]?
    /// The user's categories for folders of sounds without one of their own.
    public var folderCategories: [FolderCategory]?
    public var songs: [Song]?

    public struct LibraryInfo: Codable, Sendable, Equatable {
        public var kind: Library.Kind
        public var name: String
        /// Where it was on the Mac it came from (for people; matching doesn't use it).
        public var path: String
    }

    public struct Sound: Codable, Sendable, Equatable {
        /// Inside the library.
        public var path: String
        public var fingerprint: String
        public var facts: Facts?
        /// By model ("clap-general", "pe-av-large").
        public var embeddings: [String: Embedding]?
    }

    public struct Facts: Codable, Sendable, Equatable {
        public var version: Int
        public var loudness: Double?
        public var peak: Double?
    }

    public struct Embedding: Codable, Sendable, Equatable {
        public var version: Int
        /// float32, little-endian, base64 in the file; null for a silent sound.
        public var vector: Data?
    }

    public struct FolderCategory: Codable, Sendable, Equatable {
        /// Inside the library.
        public var folder: String
        public var catID: String
    }

    public struct Song: Codable, Sendable, Equatable {
        /// Inside the music folder.
        public var path: String
        public var size: Int64
        /// nil when the file couldn't be read at export (it's then matched by path and size).
        public var fingerprint: String?
        public var analysis: SongValues?
        public var correction: SongValues?
    }

    /// Tempo and key: what was analysed (with `source`), or what the user set by hand.
    public struct SongValues: Codable, Sendable, Equatable {
        public var bpm: Double?
        public var bpmLow: Double?
        public var bpmHigh: Double?
        public var stability: String?
        public var beatsPerBar: Int?
        public var keyPitchClass: Int?
        public var keyMinor: Bool?
        public var keyConfidence: Double?
        /// "Phase 0" or "Earmark".
        public var source: String?
    }

    public enum ReadError: Error, LocalizedError {
        case notAnalysisFile
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notAnalysisFile: "This isn't an Earmark analysis file."
            case .newerVersion(let v): "This analysis file is from a newer Earmark (format \(v)). Update Earmark to import it."
            }
        }
    }

    /// The format a JSON file says it's in ("earmark-analysis", "soundlab-music-analysis"), if any.
    public static func formatOf(_ data: Data) -> String? {
        struct Peek: Decodable { var format: String? }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.format
    }

    public static func read(_ data: Data) throws -> AnalysisFile {
        guard formatOf(data) == formatName else { throw ReadError.notAnalysisFile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(AnalysisFile.self, from: data)
        guard file.version <= currentVersion else { throw ReadError.newerVersion(file.version) }
        return file
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The library `url` is inside, if any: analysis files are never written there.
    public static func library(containing url: URL, in libraries: [Library]) -> Library? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return libraries.first { lib in
            let root = lib.url.standardizedFileURL.resolvingSymlinksInPath().path
            return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// "SoundFX.earmark-analysis.json".
    public static func fileName(for library: Library) -> String { "\(library.name).\(fileExtension)" }
}

/// What an import found and added.
public struct AnalysisImportReport: Sendable, Equatable {
    public var sounds = 0, soundsMatched = 0, facts = 0, embeddings = 0, folderCategories = 0
    public var songs = 0, songsMatched = 0, songAnalyses = 0, corrections = 0

    public init() {}

    public static func + (a: Self, b: Self) -> Self {
        var r = a
        r.sounds += b.sounds; r.soundsMatched += b.soundsMatched; r.facts += b.facts; r.embeddings += b.embeddings
        r.folderCategories += b.folderCategories; r.songs += b.songs; r.songsMatched += b.songsMatched
        r.songAnalyses += b.songAnalyses; r.corrections += b.corrections
        return r
    }
}

extension SoundRecord {
    /// Inside its library, e.g. "TSK-03/Footsteps/Gravel/Step 01.wav".
    public var pathInLibrary: String { folder.isEmpty ? fileName : folder + "/" + fileName }
}

extension SongRecord {
    /// Inside its music folder.
    public var pathInLibrary: String { folder.isEmpty ? fileName : folder + "/" + fileName }
}

extension LibraryDatabase {
    // MARK: export

    /// Everything Earmark worked out for one library. `fingerprint` reads a song's (songs have
    /// none stored); nil for a file it can't read.
    public func analysisFile(for library: Library, includeEmbeddings: Bool, exportedAt: Date = Date(),
                             fingerprint: (URL) -> String? = Fingerprint.of) throws -> AnalysisFile {
        guard let libraryId = library.id else { throw CocoaError(.coderInvalidValue) }
        var file = AnalysisFile(exportedAt: exportedAt, library: .init(kind: library.kind, name: library.name, path: library.path))
        switch library.kind {
        case .sounds:
            let (sounds, rules) = try soundsAndRules(libraryId: libraryId)
            file.sounds = try soundEntries(sounds, includeEmbeddings: includeEmbeddings)
            file.folderCategories = rules.map { .init(folder: $0.folder, catID: $0.catID) }
        case .music:
            let (songs, corrections) = try dbQueue.read { db in
                (try SongRecord.filter(Column("libraryId") == libraryId).order(Column("path")).fetchAll(db),
                 Dictionary(try SongCorrection.fetchAll(db).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }))
            }
            file.songs = songs.compactMap { s in
                let c = corrections[s.path]
                guard s.isAnalysed || c != nil else { return nil }
                return .init(path: s.pathInLibrary, size: s.fileSize, fingerprint: fingerprint(s.url),
                             analysis: s.isAnalysed ? .init(s) : nil, correction: c.map(AnalysisFile.SongValues.init))
            }
        }
        return file
    }

    /// Writes the library's analysis file to `url` (replacing one there), the sounds a batch at a
    /// time: built whole in memory, a 29k-sound library with embeddings (~240 MB) peaked at 1.2 GB.
    /// Returns its size in bytes.
    @discardableResult
    public func writeAnalysisFile(for library: Library, includeEmbeddings: Bool, to url: URL, exportedAt: Date = Date(),
                                  fingerprint: (URL) -> String? = Fingerprint.of) throws -> Int {
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let out = try FileHandle(forWritingTo: partial)
        var bytes = 0
        func write(_ d: Data) throws { try out.write(contentsOf: d); bytes += d.count }
        do {
            if library.kind == .sounds, let libraryId = library.id {
                // The rest of the file, then the sounds spliced in before its closing brace.
                var head = AnalysisFile(exportedAt: exportedAt, library: .init(kind: library.kind, name: library.name, path: library.path))
                let (sounds, rules) = try soundsAndRules(libraryId: libraryId)
                head.folderCategories = rules.map { .init(folder: $0.folder, catID: $0.catID) }
                try write(try head.encoded().dropLast())
                try write(Data(#","sounds":["#.utf8))
                let encoder = AnalysisFile.encoder
                var first = true
                for start in stride(from: 0, to: sounds.count, by: 2_000) {
                    for entry in try soundEntries(Array(sounds[start ..< min(sounds.count, start + 2_000)]),
                                                  includeEmbeddings: includeEmbeddings) {
                        if !first { try write(Data(",".utf8)) }
                        first = false
                        try write(try encoder.encode(entry))
                    }
                }
                try write(Data("]}".utf8))
            } else {
                try write(try analysisFile(for: library, includeEmbeddings: includeEmbeddings, exportedAt: exportedAt,
                                           fingerprint: fingerprint).encoded())
            }
            try out.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: url)
            }
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return bytes
    }

    private func soundsAndRules(libraryId: Int64) throws -> ([SoundRecord], [FolderRule]) {
        try dbQueue.read { db in
            (try SoundRecord.filter(Column("libraryId") == libraryId).order(Column("path")).fetchAll(db),
             try FolderRule.filter(Column("libraryId") == libraryId).order(Column("folder")).fetchAll(db))
        }
    }

    /// The file's entries for these sounds: results that hold for their content (a file that
    /// couldn't be read here may be read on the other Mac).
    private func soundEntries(_ sounds: [SoundRecord], includeEmbeddings: Bool) throws -> [AnalysisFile.Sound] {
        let ids = sounds.compactMap(\.id)
        let (facts, embeddings) = try dbQueue.read { db in
            (try SoundFacts.filter(ids.contains(Column("soundId"))).fetchAll(db),
             includeEmbeddings ? try SoundEmbedding.filter(ids.contains(Column("soundId"))).fetchAll(db) : [])
        }
        let factsById = Dictionary(facts.map { ($0.soundId, $0) }, uniquingKeysWith: { a, _ in a })
        let embeddingsById = Dictionary(grouping: embeddings, by: \.soundId)
        return sounds.compactMap { s in
            guard let id = s.id, let fp = s.fingerprint else { return nil }
            let f = factsById[id].flatMap { $0.fingerprint == fp && $0.error == nil ? $0 : nil }
            var vectors: [String: AnalysisFile.Embedding] = [:]
            for e in embeddingsById[id] ?? [] where e.fingerprint == fp && e.error == nil {
                vectors[e.model] = .init(version: e.version, vector: e.vector)
            }
            guard f != nil || !vectors.isEmpty else { return nil }
            return .init(path: s.pathInLibrary, fingerprint: fp,
                         facts: f.map { .init(version: $0.version, loudness: $0.loudness, peak: $0.peak) },
                         embeddings: vectors.isEmpty ? nil : vectors)
        }
    }

    // MARK: import

    /// Adds what the file has and this database doesn't, for files in any library of the same
    /// kind whose content matches. Never overwrites: current results, the user's folder
    /// categories and corrections stay as they are.
    public func importAnalysis(_ file: AnalysisFile, fingerprint: (URL) -> String? = Fingerprint.of) throws -> AnalysisImportReport {
        var report = AnalysisImportReport()
        if let sounds = file.sounds { try importSounds(sounds, folders: file.folderCategories ?? [], into: &report) }
        if let songs = file.songs { try importSongs(songs, fingerprint: fingerprint, into: &report) }
        return report
    }

    private func importSounds(_ entries: [AnalysisFile.Sound], folders: [AnalysisFile.FolderCategory],
                              into report: inout AnalysisImportReport) throws {
        let local = try sounds()
        let byFingerprint = Dictionary(grouping: local.filter { $0.fingerprint != nil }, by: { $0.fingerprint! })
        let facts = try soundFacts()
        var status: [String: [Int64: SoundEmbedding.Status]] = [:]
        for model in SoundEmbedding.versions.keys { status[model] = try embeddingStatus(model: model) }
        var newFacts: [Int64: SoundFacts] = [:], newEmbeddings: [String: SoundEmbedding] = [:]
        var matchedLibraries: [Int64: Int] = [:]
        report.sounds = entries.count
        for entry in entries {
            guard let matches = byFingerprint[entry.fingerprint] else { continue }
            report.soundsMatched += 1
            for s in matches {
                guard let id = s.id else { continue }
                matchedLibraries[s.libraryId, default: 0] += 1
                if let f = entry.facts, f.version >= SoundFacts.currentVersion, !(facts[id]?.isCurrent(for: s) ?? false) {
                    var new = SoundFacts(soundId: id, fingerprint: s.fingerprint, loudness: nil, version: f.version)
                    new.loudness = f.loudness
                    new.peak = f.peak
                    newFacts[id] = new
                }
                for (model, e) in entry.embeddings ?? [:] {
                    guard let current = SoundEmbedding.versions[model], e.version >= current,
                          !SoundEmbedding.isCurrent(status[model]?[id], model: model, for: s) else { continue }
                    var new = SoundEmbedding(soundId: id, model: model, fingerprint: s.fingerprint, vector: nil)
                    new.version = e.version
                    new.vector = e.vector
                    newEmbeddings["\(id) \(model)"] = new
                }
            }
        }
        report.facts = newFacts.count
        report.embeddings = newEmbeddings.count
        // Folder categories go to the library most of the file's sounds were found in, for
        // folders it has and the user hasn't chosen a category for.
        var newRules: [FolderRule] = []
        if let libraryId = matchedLibraries.max(by: { $0.value < $1.value })?.key {
            let existing = Set(try folderRules().filter { $0.libraryId == libraryId }.map(\.folder))
            let present = Set(local.filter { $0.libraryId == libraryId }.map(\.folder))
            for f in folders where !existing.contains(f.folder) && UCSCatalog.shared.entry(catID: f.catID) != nil
                && present.contains(where: { $0 == f.folder || $0.hasPrefix(f.folder + "/") }) {
                newRules.append(FolderRule(libraryId: libraryId, folder: f.folder, catID: f.catID))
            }
        }
        report.folderCategories = newRules.count
        try dbQueue.write { db in
            for f in newFacts.values { try f.save(db) }
            for e in newEmbeddings.values { try e.save(db) }
            for r in newRules { try r.save(db) }
        }
    }

    private func importSongs(_ entries: [AnalysisFile.Song], fingerprint: (URL) -> String?,
                             into report: inout AnalysisImportReport) throws {
        let local = try songs()
        let corrections = Set(try songCorrections().map(\.path))
        let bySize = Dictionary(grouping: local, by: \.fileSize)
        var fingerprints: [Int64: String?] = [:]   // read once, only for songs of a size in the file
        func fingerprintOf(_ s: SongRecord) -> String? {
            guard let id = s.id else { return nil }
            if let known = fingerprints[id] { return known }
            let fp = fingerprint(s.url)
            fingerprints[id] = fp
            return fp
        }
        var analyses: [(songId: Int64, analysis: SongAnalysis)] = [], newCorrections: [(path: String, correction: SongCorrection?)] = []
        report.songs = entries.count
        for entry in entries {
            let sameSize = bySize[entry.size] ?? []
            // The same content (or, without a fingerprint, the same place and size); the same place first.
            let matches = entry.fingerprint.map { fp in sameSize.filter { fingerprintOf($0) == fp } }
                ?? sameSize.filter { $0.pathInLibrary == entry.path }
            guard !matches.isEmpty else { continue }
            report.songsMatched += 1
            for s in matches.sorted(by: { ($0.pathInLibrary == entry.path ? 0 : 1) < ($1.pathInLibrary == entry.path ? 0 : 1) }) {
                guard let id = s.id else { continue }
                if let a = entry.analysis, !s.isAnalysed, !analyses.contains(where: { $0.songId == id }) {
                    analyses.append((id, a.songAnalysis))
                }
                if let c = entry.correction, !corrections.contains(s.path), !newCorrections.contains(where: { $0.path == s.path }) {
                    newCorrections.append((s.path, c.correction(path: s.path)))
                }
            }
        }
        report.songAnalyses = try saveSongAnalysis(analyses).count
        try setSongCorrections(newCorrections)
        report.corrections = newCorrections.count
    }
}

extension LibraryDatabase {
    /// Removes every analysis result and choice, keeping the libraries, sounds and songs: for
    /// testing an import at full size on a copy (`earmark-parity analysis-files`). Never the app's database.
    public func clearAnalysisForTesting() throws {
        try dbQueue.write { db in
            for table in ["soundFacts", "soundEmbedding", "folderRule", "songCorrection"] { try db.execute(sql: "DELETE FROM \(table)") }
            try db.execute(sql: """
                UPDATE song SET bpm = NULL, bpmLow = NULL, bpmHigh = NULL, tempoStability = NULL, beatsPerBar = NULL,
                keyPitchClass = NULL, keyMinor = NULL, keyConfidence = NULL, analysisSource = NULL
                """)
        }
    }
}

extension AnalysisFile.SongValues {
    init(_ s: SongRecord) {
        self.init(bpm: s.bpm, bpmLow: s.bpmLow, bpmHigh: s.bpmHigh, stability: s.tempoStability, beatsPerBar: s.beatsPerBar,
                  keyPitchClass: s.keyPitchClass, keyMinor: s.keyMinor, keyConfidence: s.keyConfidence, source: s.analysisSource)
    }

    init(_ c: SongCorrection) {
        self.init(bpm: c.bpm, bpmLow: c.bpmLow, bpmHigh: c.bpmHigh, beatsPerBar: c.beatsPerBar,
                  keyPitchClass: c.keyPitchClass, keyMinor: c.keyMinor)
    }

    var songAnalysis: SongAnalysis {
        SongAnalysis(bpm: bpm, bpmLow: bpmLow, bpmHigh: bpmHigh, tempoStability: stability, beatsPerBar: beatsPerBar,
                     key: keyPitchClass.map { MusicKey(pitchClass: $0, minor: keyMinor ?? false) }, keyConfidence: keyConfidence,
                     source: source ?? SongAnalysis.earmarkSource)
    }

    func correction(path: String) -> SongCorrection {
        SongCorrection(path: path, bpm: bpm, bpmLow: bpmLow, bpmHigh: bpmHigh,
                       key: keyPitchClass.map { MusicKey(pitchClass: $0, minor: keyMinor ?? false) }, beatsPerBar: beatsPerBar)
    }
}
