import EarmarkCore
import Foundation
import GRDB

/// The library database through the Rust engine (`earmark_db`, step 8j): the same file, tables
/// and answers as Swift's `LibraryDatabase`.
///
/// Records cross as JSON in the engine's shape, the rows as stored: dates as the text GRDB
/// writes (read and written here with GRDB's own conversion, so they're the same to the bit),
/// bytes as lists of numbers. Dictionaries come as lists and are rebuilt here.
///
/// The engine uses the system's SQLite, the one GRDB uses (see earmark-db's features): two copies
/// of SQLite in one process opening the same file can lose each other's locks.
public final class EngineLibraryDatabase: LibraryStore, @unchecked Sendable {
    private let db: EngineDatabase

    /// `path`: the database file (created and migrated if needed); nil: in memory.
    public init(path: String?, readOnly: Bool = false) throws {
        db = try Self.call { try EngineDatabase.open(path: path, readOnly: readOnly) }
    }

    // MARK: JSON both ways

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Date.fromDatabaseValue(text.databaseValue) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        d.dataDecodingStrategy = .custom { decoder in Data(try decoder.singleValueContainer().decode([UInt8].self)) }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            guard case .string(let text) = date.databaseValue.storage else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "no date text"))
            }
            try c.encode(text)
        }
        e.dataEncodingStrategy = .custom { data, encoder in
            var c = encoder.singleValueContainer()
            try c.encode([UInt8](data))
        }
        return e
    }()

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// JSON of plain values (lists of ids and fingerprints and the like).
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    /// The engine's failures as Swift errors with its message.
    static func call<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch DatabaseError.Failed(let message) { throw EngineDatabaseFailure(message: message) }
    }

    /// An analysis file's date, as `AnalysisFile.encoded()` writes it (JSONEncoder's .iso8601).
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Little-endian float32 bytes as floats (the Mac is little-endian: a plain copy).
    static func floats(_ data: Data) -> [Float] {
        [Float](unsafeUninitializedCapacity: data.count / 4) { buffer, count in
            count = data.copyBytes(to: buffer) / 4
        }
    }

    /// GRDB's text for a date, as stored.
    static func text(_ date: Date) -> String {
        if case .string(let s) = date.databaseValue.storage { return s }
        return ""
    }

    private static func idsAndPrints(_ list: [(id: Int64, fingerprint: String?)]) -> [Any] {
        list.map { [$0.id, $0.fingerprint as Any? ?? NSNull()] }
    }

    // MARK: libraries

    public func addLibrary(kind: Library.Kind, path: String, bookmark: Data?) throws -> Library {
        try Self.call { try Self.decode(Library.self, try db.addLibrary(kind: kind.rawValue, path: path, bookmark: bookmark)) }
    }

    public func libraries(kind: Library.Kind?) throws -> [Library] {
        try Self.call { try Self.decode([Library].self, try db.libraries(kind: kind?.rawValue)) }
    }

    public func removeLibrary(id: Int64) throws {
        try Self.call { try db.removeLibrary(id: id) }
    }

    // MARK: sounds

    public func replaceSounds(libraryId: Int64, root: URL, scanned: [ScannedSound]) throws {
        // As the engine reads them: the date in seconds since 1970.
        struct Row: Encodable {
            var path: String; var fileSize: Int64; var modified: Double; var fingerprint: String?
            var technical: AudioTechnical; var metadata: NormalizedMetadata; var warnings: [String]
        }
        let rows = scanned.map {
            Row(path: $0.path, fileSize: $0.fileSize, modified: $0.modified.timeIntervalSince1970, fingerprint: $0.fingerprint,
                technical: $0.technical, metadata: $0.metadata, warnings: $0.warnings)
        }
        let json = try Self.encode(rows)
        try Self.call { try db.replaceSounds(libraryId: libraryId, root: root.path, scanned: json) }
    }

    public func sounds(libraryId: Int64?) throws -> [SoundRecord] {
        try Self.call { try Self.decode([SoundRecord].self, try db.sounds(libraryId: libraryId)) }
    }

    public func soundFacts() throws -> [Int64: SoundFacts] {
        let list = try Self.call { try Self.decode([SoundFacts].self, try db.soundFacts()) }
        return Dictionary(list.map { ($0.soundId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func save(_ facts: [SoundFacts]) throws {
        let json = try Self.encode(facts)
        try Self.call { try db.saveFacts(facts: json) }
    }

    public func embeddingStatus(model: String) throws -> [Int64: SoundEmbedding.Status] {
        struct Row: Decodable { var soundId: Int64; var fingerprint: String?; var version: Int }
        let list = try Self.call { try Self.decode([Row].self, try db.embeddingStatus(model: model)) }
        return Dictionary(list.map { ($0.soundId, SoundEmbedding.Status(fingerprint: $0.fingerprint, version: $0.version)) },
                          uniquingKeysWith: { a, _ in a })
    }

    public func vectors(model: String) throws -> [(id: Int64, vector: [Float])] {
        let found = try Self.call { try db.vectors(model: model) }
        var out: [(id: Int64, vector: [Float])] = []
        out.reserveCapacity(found.ids.count)
        let floats = Self.floats(found.data)
        var at = 0
        for (id, length) in zip(found.ids, found.lengths) {
            out.append((id, Array(floats[at ..< at + Int(length)])))
            at += Int(length)
        }
        return out
    }

    public func forEachVectors(models: [String], ids: [Int64]?, count: (Int) -> Void,
                               _ body: (_ id: Int64, _ vectors: [[Float]]) -> Void) throws {
        try withoutActuallyEscaping(count) { count in
            try withoutActuallyEscaping(body) { body in
                let listener = VectorRelay(count: count, body: body)
                try Self.call { try db.forEachVectors(models: models, ids: ids, listener: listener) }
            }
        }
    }

    public func embedding(soundId: Int64, model: String) throws -> SoundEmbedding? {
        try Self.call {
            try db.embedding(soundId: soundId, model: model).map { try Self.decode(SoundEmbedding.self, $0) }
        }
    }

    public func save(_ embeddings: [SoundEmbedding]) throws {
        let json = try Self.encode(embeddings)
        try Self.call { try db.saveEmbeddings(embeddings: json) }
    }

    public func nearDuplicates() throws -> [Duplicates.Pair] {
        try Self.call {
            try db.nearDuplicates().map { Duplicates.Pair(a: $0.a, b: $0.b, identical: $0.identical, similarity: $0.similarity) }
        }
    }

    public func saveNearDuplicates(_ pairs: [Duplicates.Pair]) throws {
        try Self.call {
            try db.saveNearDuplicates(pairs: pairs.map {
                DuplicatePair(a: $0.a, b: $0.b, identical: $0.identical, similarity: $0.similarity)
            })
        }
    }

    // MARK: songs

    public func replaceSongs(libraryId: Int64, root: URL, files: [SongFile]) throws {
        struct Row: Encodable {
            var path: String; var fileSize: Int64; var modified: Double
            var title: String?; var artist: String?; var album: String?; var duration: Double?
        }
        let json = try Self.encode(files.map {
            Row(path: $0.path, fileSize: $0.fileSize, modified: $0.modified.timeIntervalSince1970, title: $0.title,
                artist: $0.artist, album: $0.album, duration: $0.duration)
        })
        try Self.call { try db.replaceSongs(libraryId: libraryId, root: root.path, files: json) }
    }

    public func songs(libraryId: Int64?) throws -> [SongRecord] {
        try Self.call { try Self.decode([SongRecord].self, try db.songs(libraryId: libraryId)) }
    }

    public func saveSongAnalysis(_ results: [(songId: Int64, analysis: SongAnalysis)]) throws -> [SongRecord] {
        let analyses = try results.map { r -> Any in
            [r.songId, try JSONSerialization.jsonObject(with: try Self.encoder.encode(r.analysis))]
        }
        let json = try Self.json(analyses)
        return try Self.call { try Self.decode([SongRecord].self, try db.saveSongAnalysis(results: json)) }
    }

    public func applySongAnalysis(_ entries: [Phase0MusicImport.Entry]) throws -> Int {
        let list = try entries.map { e -> Any in
            var row: [String: Any] = ["fileName": e.fileName,
                                      "analysis": try JSONSerialization.jsonObject(with: try Self.encoder.encode(e.analysis))]
            if let path = e.path { row["path"] = path }
            if let size = e.size { row["size"] = size }
            if let title = e.title { row["title"] = title }
            if let artist = e.artist { row["artist"] = artist }
            return row
        }
        let json = try Self.json(list)
        return Int(try Self.call { try db.applySongAnalysis(entries: json) })
    }

    public func songCorrections() throws -> [SongCorrection] {
        try Self.call { try Self.decode([SongCorrection].self, try db.songCorrections()) }
    }

    public func setSongCorrections(_ changes: [(path: String, correction: SongCorrection?)]) throws {
        let list = try changes.map { c -> Any in
            [c.path, try c.correction.map { try JSONSerialization.jsonObject(with: try Self.encoder.encode($0)) } ?? NSNull()]
        }
        let json = try Self.json(list)
        try Self.call { try db.setSongCorrections(changes: json) }
    }

    // MARK: categories

    public func soundCategoryChoices() throws -> [Int64: SoundCategoryChoice] {
        let list = try Self.call { try Self.decode([SoundCategoryChoice].self, try db.soundCategoryChoices()) }
        return Dictionary(list.map { ($0.soundId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func setSoundCategory(_ sounds: [(id: Int64, fingerprint: String?)], catID: String?) throws {
        let json = try Self.json(Self.idsAndPrints(sounds))
        try Self.call { try db.setSoundCategory(sounds: json, catId: catID) }
    }

    public func replaceSoundGuesses(_ guesses: [SoundCategoryChoice]) throws -> Bool {
        let json = try Self.encode(guesses)
        return try Self.call { try db.replaceSoundGuesses(guesses: json) }
    }

    public func folderRules() throws -> [FolderRule] {
        try Self.call { try Self.decode([FolderRule].self, try db.folderRules()) }
    }

    public func save(_ rules: [FolderRule]) throws {
        let json = try Self.encode(rules)
        try Self.call { try db.saveFolderRules(rules: json) }
    }

    public func removeFolderRule(libraryId: Int64, folder: String) throws {
        try Self.call { try db.removeFolderRule(libraryId: libraryId, folder: folder) }
    }

    public func folderGuesses() throws -> [FolderGuess] {
        try Self.call { try Self.decode([FolderGuess].self, try db.folderGuesses()) }
    }

    public func updateGuesses(saving guesses: [FolderGuess], removing stale: [(libraryId: Int64, folder: String)]) throws {
        let saving = try Self.encode(guesses)
        let removing = try Self.json(stale.map { [$0.libraryId, $0.folder] as [Any] })
        try Self.call { try db.updateGuesses(saving: saving, removing: removing) }
    }

    // MARK: groups

    public func soundGroupSnapshot() throws -> SoundGroupSnapshot {
        struct Stored: Decodable {
            var sets: [String: SoundGroupSet]
            var groups: [String: [SoundGroupRecord]]
            var membership: [[Int64]]
            var memberFingerprints: [Print]
        }
        /// `[soundId, fingerprint or null]`.
        struct Print: Decodable {
            var id: Int64; var fingerprint: String?
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                id = try c.decode(Int64.self)
                fingerprint = try c.decodeNil() ? nil : try c.decode(String.self)
            }
        }
        let stored = try Self.call { try Self.decode(Stored.self, try db.groupSnapshot()) }
        var snap = SoundGroupSnapshot()
        snap.sets = stored.sets
        snap.groups = stored.groups
        for g in stored.groups.values.joined() { if let id = g.id { snap.byId[id] = g } }
        for m in stored.membership where m.count == 2 { snap.membership[m[0]] = m[1] }
        for p in stored.memberFingerprints { snap.memberFingerprints[p.id] = .some(p.fingerprint) }
        return snap
    }

    public func replaceGroups(catID: String, groups: [[(id: Int64, fingerprint: String?)]], names: [SoundGroups.Name]) throws {
        let groupsJSON = try Self.json(groups.map(Self.idsAndPrints))
        let namesJSON = try Self.encode(names)
        try Self.call { try db.replaceGroups(catId: catID, groups: groupsJSON, names: namesJSON) }
    }

    public func updateGroups(catID: String, add: [(id: Int64, fingerprint: String?, group: Int64)], remove: [Int64]) throws {
        let json = try Self.json(add.map { [$0.id, $0.fingerprint as Any? ?? NSNull(), $0.group] })
        try Self.call { try db.updateGroups(catId: catID, add: json, remove: remove) }
    }

    public func dropGroups(catID: String) throws {
        try Self.call { try db.dropGroups(catId: catID) }
    }

    public func renameGroup(_ id: Int64, to name: String?) throws {
        try Self.call { try db.renameGroup(id: id, name: name) }
    }

    public func moveSounds(_ sounds: [(id: Int64, fingerprint: String?)], toGroup id: Int64) throws {
        let json = try Self.json(Self.idsAndPrints(sounds))
        try Self.call { try db.moveSounds(sounds: json, group: id) }
    }

    public func newGroup(catID: String, name: String, sounds: [(id: Int64, fingerprint: String?)]) throws -> Int64 {
        let json = try Self.json(Self.idsAndPrints(sounds))
        return try Self.call { try db.newGroup(catId: catID, name: name, sounds: json) }
    }

    public func mergeGroups(_ groups: [Int64], into target: Int64) throws {
        try Self.call { try db.mergeGroups(groups: groups, target: target) }
    }

    public func regroup(catID: String) throws {
        try Self.call { try db.regroup(catId: catID) }
    }

    // MARK: analysis files

    public func analysisFile(for library: Library, includeEmbeddings: Bool, exportedAt: Date,
                             fingerprint: (URL) -> String?) throws -> AnalysisFile {
        let lib = try Self.encode(library)
        let json = try Self.call {
            try db.analysisFile(library: lib, includeEmbeddings: includeEmbeddings, exportedAt: Self.iso(exportedAt))
        }
        return try AnalysisFile.read(Data(json.utf8))
    }

    public func writeAnalysisFile(for library: Library, includeEmbeddings: Bool, to url: URL, exportedAt: Date,
                                  fingerprint: (URL) -> String?) throws -> Int {
        let lib = try Self.encode(library)
        return Int(try Self.call {
            try db.writeAnalysisFile(library: lib, includeEmbeddings: includeEmbeddings, path: url.path,
                                     exportedAt: Self.iso(exportedAt))
        })
    }

    public func importAnalysis(_ file: AnalysisFile, fingerprint: (URL) -> String?) throws -> AnalysisImportReport {
        let json = String(decoding: try file.encoded(), as: UTF8.self)
        let answer = try Self.call { try db.importAnalysis(file: json) }
        struct Report: Decodable {
            var sounds, soundsMatched, facts, embeddings, folderCategories, soundCategories: Int
            var songs, songsMatched, songAnalyses, corrections: Int
        }
        let r = try Self.decode(Report.self, answer)
        var out = AnalysisImportReport()
        out.sounds = r.sounds; out.soundsMatched = r.soundsMatched; out.facts = r.facts; out.embeddings = r.embeddings
        out.folderCategories = r.folderCategories; out.soundCategories = r.soundCategories
        out.songs = r.songs; out.songsMatched = r.songsMatched; out.songAnalyses = r.songAnalyses; out.corrections = r.corrections
        return out
    }
}

/// A failure the engine's database reported, with its message.
public struct EngineDatabaseFailure: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// The caller's closures for one `forEachVectors` call; the engine calls them on the caller's thread.
private final class VectorRelay: VectorListener, @unchecked Sendable {
    let countBody: (Int) -> Void
    let body: (Int64, [[Float]]) -> Void
    init(count: @escaping (Int) -> Void, body: @escaping (Int64, [[Float]]) -> Void) {
        countBody = count
        self.body = body
    }
    func count(sounds: UInt64) { countBody(Int(sounds)) }
    func vectors(id: Int64, data: Data, lengths: [UInt32]) {
        let floats = EngineLibraryDatabase.floats(data)
        var at = 0
        body(id, lengths.map { n in
            defer { at += Int(n) }
            return Array(floats[at ..< at + Int(n)])
        })
    }
}
