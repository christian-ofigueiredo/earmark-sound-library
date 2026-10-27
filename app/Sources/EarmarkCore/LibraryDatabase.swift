import Foundation
import GRDB

/// A folder of sound effects or music that the user added. Only its path and
/// a bookmark are stored; nothing is written inside the folder.
public struct Library: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case sounds, music }

    public var id: Int64?
    public var kind: Kind
    public var path: String
    public var bookmark: Data?
    public var addedAt: Date

    public static let databaseTableName = "library"
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
    public var isOnline: Bool { FileManager.default.fileExists(atPath: path) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SoundRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable, Hashable {
    public var id: Int64?
    public var libraryId: Int64
    public var path: String
    public var fileName: String
    /// Folder inside the library, e.g. "TSK-03/Footsteps/Gravel".
    public var folder: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var fingerprint: String?
    public var duration: Double?
    public var sampleRate: Double?
    public var channels: Int?
    public var bitsPerSample: Int?
    public var fxName: String?
    public var details: String?
    public var keywords: String?
    public var vendorLibrary: String?
    public var manufacturer: String?
    public var designer: String?
    public var catID: String?
    public var category: String?
    public var subcategory: String?
    public var categorySource: String?

    public static let databaseTableName = "sound"
    public var url: URL { URL(fileURLWithPath: path) }
    public var ucsLabel: String? { category.map { c in subcategory.map { "\(c) / \($0)" } ?? c } }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public init(libraryId: Int64, root: URL, scanned s: ScannedSound) {
        let url = URL(fileURLWithPath: s.path)
        self.libraryId = libraryId
        self.path = s.path
        self.fileName = url.lastPathComponent
        self.folder = SoundRecord.relativeFolder(of: url, in: root)
        self.fileSize = s.fileSize
        self.modifiedAt = s.modified
        self.fingerprint = s.fingerprint
        self.duration = s.technical.duration
        self.sampleRate = s.technical.sampleRate
        self.channels = s.technical.channels
        self.bitsPerSample = s.technical.bitsPerSample
        let m = s.metadata
        self.fxName = m[.fxName]; self.details = m[.description]; self.keywords = m[.keywords]
        self.vendorLibrary = m[.library]; self.manufacturer = m[.manufacturer]; self.designer = m[.designer]
        self.catID = m.ucs?.catID; self.category = m.ucs?.category; self.subcategory = m.ucs?.subcategory
        self.categorySource = m.ucs?.source
    }

    static func relativeFolder(of file: URL, in root: URL) -> String {
        let dir = file.deletingLastPathComponent().standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard dir.hasPrefix(base) else { return "" }
        return String(dir.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// A song file with its tags, filled in by the app (AVFoundation).
public struct SongFile: Sendable, Equatable {
    public var path: String
    public var fileSize: Int64
    public var modified: Date
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?

    public init(path: String, fileSize: Int64, modified: Date, title: String? = nil, artist: String? = nil,
                album: String? = nil, duration: Double? = nil) {
        self.path = path; self.fileSize = fileSize; self.modified = modified
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
    }
}

public struct SongRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable, Hashable {
    public var id: Int64?
    public var libraryId: Int64
    public var path: String
    public var fileName: String
    public var folder: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?
    public var bpm: Double?
    public var bpmLow: Double?
    public var bpmHigh: Double?
    public var tempoStability: String?
    public var beatsPerBar: Int?
    public var keyPitchClass: Int?
    public var keyMinor: Bool?
    public var keyConfidence: Double?
    public var analysisSource: String?
    /// Set (in memory only) on a song the user corrected: what was analysed, and the correction
    /// (SongCorrections). The fields above then hold the user's values.
    public internal(set) var analysed: AnalysedValues?
    public internal(set) var correction: SongCorrection?

    /// The stored columns (not `analysed` and `correction`).
    enum CodingKeys: String, CodingKey {
        case id, libraryId, path, fileName, folder, fileSize, modifiedAt, title, artist, album, duration
        case bpm, bpmLow, bpmHigh, tempoStability, beatsPerBar, keyPitchClass, keyMinor, keyConfidence, analysisSource
    }

    public static let databaseTableName = "song"
    public var url: URL { URL(fileURLWithPath: path) }
    public var displayTitle: String { title?.isEmpty == false ? title! : url.deletingPathExtension().lastPathComponent }
    public var key: MusicKey? { keyPitchClass.map { MusicKey(pitchClass: $0, minor: keyMinor ?? false) } }
    /// Analysed by Phase 0 or by Earmark (which may have found no beat or key: silent, or very
    /// short). The user's corrections don't count.
    public var isAnalysed: Bool {
        let s = uncorrected
        return s.analysisSource != nil || s.bpm != nil || s.keyPitchClass != nil
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    mutating func apply(_ a: SongAnalysis) {
        bpm = a.bpm; bpmLow = a.bpmLow; bpmHigh = a.bpmHigh; tempoStability = a.tempoStability
        beatsPerBar = a.beatsPerBar; keyPitchClass = a.key?.pitchClass; keyMinor = a.key?.minor
        keyConfidence = a.keyConfidence; analysisSource = a.source
    }
}

/// Earmark's own database (in Application Support), the only place it writes.
public final class LibraryDatabase: Sendable {
    let dbQueue: DatabaseQueue

    /// `path == nil` opens an in-memory database (tests).
    public init(path: String?) throws {
        if let path {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "library") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob)
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "sound") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("library", onDelete: .cascade).notNull()
                t.column("path", .text).notNull().unique()
                t.column("fileName", .text).notNull()
                t.column("folder", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("fingerprint", .text).indexed()
                t.column("duration", .double)
                t.column("sampleRate", .double)
                t.column("channels", .integer)
                t.column("bitsPerSample", .integer)
                t.column("fxName", .text)
                t.column("details", .text)
                t.column("keywords", .text)
                t.column("vendorLibrary", .text)
                t.column("manufacturer", .text)
                t.column("designer", .text)
                t.column("catID", .text).indexed()
                t.column("category", .text)
                t.column("subcategory", .text)
                t.column("categorySource", .text)
            }
            try db.create(table: "song") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("library", onDelete: .cascade).notNull()
                t.column("path", .text).notNull().unique()
                t.column("fileName", .text).notNull()
                t.column("folder", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("title", .text)
                t.column("artist", .text)
                t.column("album", .text)
                t.column("duration", .double)
                t.column("bpm", .double)
                t.column("bpmLow", .double)
                t.column("bpmHigh", .double)
                t.column("tempoStability", .text)
                t.column("beatsPerBar", .integer)
                t.column("keyPitchClass", .integer)
                t.column("keyMinor", .boolean)
                t.column("keyConfidence", .double)
                t.column("analysisSource", .text)
            }
        }
        // Ids of sounds that left the database (library removed, or file gone on
        // rescan), by fingerprint, so the same file gets its id back if it returns.
        m.registerMigration("v2-retired-sounds") { db in
            try db.create(table: "retiredSound") { t in
                t.primaryKey("fingerprint", .text)
                t.column("soundId", .integer).notNull()
            }
        }
        // Analysis stage 1 ("facts"). Rows are keyed by sound id with no foreign
        // key, so they survive a library being removed and re-added (ids come back
        // through retiredSound); the fingerprint says whether they still apply.
        m.registerMigration("v3-sound-facts") { db in
            try db.create(table: "soundFacts") { t in
                t.primaryKey("soundId", .integer)
                t.column("fingerprint", .text)
                t.column("version", .integer).notNull()
                t.column("loudness", .double)
                t.column("peak", .double)
                t.column("error", .text)
                t.column("analyzedAt", .datetime).notNull()
            }
        }
        // Analysis stage 2: sound embeddings, one row per sound and model (CLAP now,
        // PE-AV later). Same rules as soundFacts: no foreign key, fingerprint-checked.
        m.registerMigration("v4-sound-embeddings") { db in
            try db.create(table: "soundEmbedding") { t in
                t.column("soundId", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("fingerprint", .text)
                t.column("version", .integer).notNull()
                t.column("vector", .blob)
                t.column("error", .text)
                t.column("analyzedAt", .datetime).notNull()
                t.primaryKey(["soundId", "model"])
            }
        }
        // Categories the user chose for folders of sounds that have none (FolderRules).
        m.registerMigration("v5-folder-rules") { db in
            try db.create(table: "folderRule") { t in
                t.column("libraryId", .integer).notNull()
                t.column("folder", .text).notNull()
                t.column("catID", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["libraryId", "folder"])
            }
        }
        m.registerMigration("v6-folder-guesses") { db in
            try db.create(table: "folderGuess") { t in
                t.column("libraryId", .integer).notNull()
                t.column("folder", .text).notNull()
                t.column("catID", .text).notNull()
                t.column("alternatives", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("isUnsure", .boolean).notNull()
                t.column("analysed", .integer).notNull()
                t.column("version", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["libraryId", "folder"])
            }
        }
        // Tempo, key and beats per bar the user set by hand (SongCorrections), by file path.
        m.registerMigration("v7-song-corrections") { db in
            try db.create(table: "songCorrection") { t in
                t.column("path", .text).primaryKey()
                t.column("bpm", .double)
                t.column("bpmLow", .double)
                t.column("bpmHigh", .double)
                t.column("keyPitchClass", .integer)
                t.column("keyMinor", .boolean)
                t.column("beatsPerBar", .integer)
                t.column("correctedAt", .datetime).notNull()
            }
        }
        // Similarity groups inside each subcategory (SoundGroups, SoundGroupStore). Members are
        // keyed by sound id with no foreign key to sound, like the analysis tables.
        m.registerMigration("v8-sound-groups") { db in
            try db.create(table: "soundGroupSet") { t in
                t.primaryKey("catID", .text)
                t.column("version", .integer).notNull()
                t.column("grouped", .integer).notNull()
                t.column("changed", .integer).notNull()
                t.column("edited", .boolean).notNull()
                t.column("groupedAt", .datetime).notNull()
            }
            try db.create(table: "soundGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("catID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("userName", .text)
                t.column("aiWords", .text).notNull()
                t.column("shapeWords", .text).notNull()
                t.column("keywords", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "soundGroupMember") { t in
                t.primaryKey("soundId", .integer)
                t.column("fingerprint", .text)
                t.belongsTo("soundGroup", onDelete: .cascade).notNull()
            }
        }
        // A category for one sound: the owner's, or Earmark's guess from how it sounds
        // (SoundCategories). Keyed by sound id, no foreign key, like the analysis tables.
        m.registerMigration("v9-sound-categories") { db in
            try db.create(table: "soundCategory") { t in
                t.primaryKey("soundId", .integer)
                t.column("fingerprint", .text)
                t.column("catID", .text).notNull()
                t.column("byOwner", .boolean).notNull()
                t.column("share", .double)
                t.column("replaced", .text)
                t.column("version", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        return m
    }

    // MARK: libraries

    @discardableResult
    public func addLibrary(kind: Library.Kind, path: String, bookmark: Data?) throws -> Library {
        try dbQueue.write { db in
            if var existing = try Library.filter(Column("path") == path).fetchOne(db) {
                existing.bookmark = bookmark ?? existing.bookmark
                try existing.update(db)
                return existing
            }
            var lib = Library(id: nil, kind: kind, path: path, bookmark: bookmark, addedAt: Date())
            try lib.insert(db)
            return lib
        }
    }

    public func libraries(kind: Library.Kind? = nil) throws -> [Library] {
        try dbQueue.read { db in
            var q = Library.order(Column("path"))
            if let kind { q = q.filter(Column("kind") == kind.rawValue) }
            return try q.fetchAll(db)
        }
    }

    /// Forgets a library. Its sounds' ids are kept by fingerprint, so adding
    /// the folder again (or the same files elsewhere) restores them.
    public func removeLibrary(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO retiredSound (fingerprint, soundId)
                SELECT fingerprint, id FROM sound WHERE libraryId = ? AND fingerprint IS NOT NULL
                """, arguments: [id])
            // Earmark's guesses are remade if the folder comes back; the user's rules stay.
            try db.execute(sql: "DELETE FROM folderGuess WHERE libraryId = ?", arguments: [id])
            _ = try Library.deleteOne(db, key: id)
        }
    }

    // MARK: sounds

    /// Replace a library's sounds with a fresh scan. A file keeps its id when
    /// its path is unchanged; a renamed or moved file keeps it through its
    /// fingerprint, as does a file returning after it was removed. Files no
    /// longer present are removed (their ids retired by fingerprint).
    /// Only call this when the library folder is online.
    public func replaceSounds(libraryId: Int64, root: URL, scanned: [ScannedSound]) throws {
        try dbQueue.write { db in
            let existing = try Row.fetchAll(db, sql: "SELECT id, path, fingerprint FROM sound WHERE libraryId = ?",
                                            arguments: [libraryId])
            var idByPath: [String: Int64] = [:]
            var fingerprintByID: [Int64: String] = [:]
            for row in existing {
                idByPath[row["path"]] = row["id"]
                if let f: String = row["fingerprint"] { fingerprintByID[row["id"]] = f }
            }
            let records = scanned.map { SoundRecord(libraryId: libraryId, root: root, scanned: $0) }
            let scannedPaths = Set(records.map(\.path))

            // Rows whose file is no longer at their path may have moved: index them by fingerprint.
            var movable: [String: [Int64]] = [:]
            for (path, id) in idByPath where !scannedPaths.contains(path) {
                if let f = fingerprintByID[id] { movable[f, default: []].append(id) }
            }
            var kept = Set<Int64>()
            var fresh: [SoundRecord] = []
            for var rec in records {
                if let id = idByPath[rec.path] {
                    rec.id = id
                } else if let f = rec.fingerprint, let id = movable[f]?.popLast() {
                    rec.id = id
                } else {
                    fresh.append(rec)
                    continue
                }
                kept.insert(rec.id!)
                try rec.update(db)
            }
            for (_, id) in idByPath where !kept.contains(id) {
                if let f = fingerprintByID[id] {
                    try db.execute(sql: "INSERT OR REPLACE INTO retiredSound (fingerprint, soundId) VALUES (?, ?)",
                                   arguments: [f, id])
                }
                _ = try SoundRecord.deleteOne(db, key: id)
            }
            for var rec in fresh {
                if let f = rec.fingerprint,
                   let id = try Int64.fetchOne(db, sql: "SELECT soundId FROM retiredSound WHERE fingerprint = ?", arguments: [f]),
                   try !SoundRecord.exists(db, key: id) {
                    rec.id = id
                }
                try rec.insert(db)
                if let f = rec.fingerprint { try db.execute(sql: "DELETE FROM retiredSound WHERE fingerprint = ?", arguments: [f]) }
            }
        }
    }

    public func sounds(libraryId: Int64? = nil) throws -> [SoundRecord] {
        try dbQueue.read { db in
            var q = SoundRecord.order(Column("path"))
            if let libraryId { q = q.filter(Column("libraryId") == libraryId) }
            return try q.fetchAll(db)
        }
    }

    // MARK: analysis facts

    public func soundFacts() throws -> [Int64: SoundFacts] {
        try dbQueue.read { db in
            Dictionary(try SoundFacts.fetchAll(db).map { ($0.soundId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    public func save(_ facts: [SoundFacts]) throws {
        guard !facts.isEmpty else { return }
        try dbQueue.write { db in for f in facts { try f.save(db) } }
    }

    // MARK: analysis embeddings

    /// What's stored for `model`, without the vectors (enough to know what's left to do).
    public func embeddingStatus(model: String) throws -> [Int64: SoundEmbedding.Status] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT soundId, fingerprint, version FROM soundEmbedding WHERE model = ?",
                                        arguments: [model])
            return Dictionary(rows.map { ($0["soundId"], SoundEmbedding.Status(fingerprint: $0["fingerprint"], version: $0["version"])) },
                              uniquingKeysWith: { a, _ in a })
        }
    }

    /// Every stored vector for `model` that still describes its sound (same fingerprint, current version).
    public func vectors(model: String) throws -> [(id: Int64, vector: [Float])] {
        let version = SoundEmbedding.versions[model] ?? 1
        return try dbQueue.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT e.soundId, e.vector FROM soundEmbedding e JOIN sound s ON s.id = e.soundId
                WHERE e.model = ? AND e.vector IS NOT NULL AND e.version >= ? AND e.fingerprint IS s.fingerprint
                """, arguments: [model, version])
            var out: [(id: Int64, vector: [Float])] = []
            while let r = try rows.next() {
                let data: Data = r["vector"]
                out.append((r["soundId"], data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }))
            }
            return out
        }
    }

    /// The same for sounds that have a vector from every one of `models`, in sound id order, one
    /// sound at a time (`body` gets them in `models`' order), so a caller can keep them its own
    /// way without them all in memory twice. `count` first gets how many sounds there will be.
    /// `ids`: only these sounds.
    public func forEachVectors(models: [String], ids: [Int64]? = nil, count: (Int) -> Void = { _ in },
                               _ body: (_ id: Int64, _ vectors: [[Float]]) -> Void) throws {
        var joins = models.indices.map { i in
            """
            JOIN soundEmbedding e\(i) ON e\(i).soundId = s.id AND e\(i).model = ? AND e\(i).vector IS NOT NULL
                AND e\(i).version >= ? AND e\(i).fingerprint IS s.fingerprint
            """
        }
        // Only these sounds (ids are integers, so written in).
        if let ids { joins.append("AND s.id IN (\(ids.map(String.init).joined(separator: ",")))") }
        let columns = models.indices.map { "e\($0).vector" }.joined(separator: ", ")
        var values: [any DatabaseValueConvertible] = []
        for model in models { values += [model, SoundEmbedding.versions[model] ?? 1] }
        try dbQueue.read { db in
            count(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sound s \(joins.joined(separator: " "))",
                                   arguments: StatementArguments(values)) ?? 0)
            let rows = try Row.fetchCursor(db, sql: "SELECT s.id, \(columns) FROM sound s \(joins.joined(separator: " ")) ORDER BY s.id",
                                           arguments: StatementArguments(values))
            while let r = try rows.next() {
                body(r[0], models.indices.map { i in
                    let data: Data = r[i + 1]
                    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                })
            }
        }
    }

    public func embedding(soundId: Int64, model: String) throws -> SoundEmbedding? {
        try dbQueue.read { db in
            try SoundEmbedding.filter(Column("soundId") == soundId && Column("model") == model).fetchOne(db)
        }
    }

    public func save(_ embeddings: [SoundEmbedding]) throws {
        guard !embeddings.isEmpty else { return }
        try dbQueue.write { db in for e in embeddings { try e.save(db) } }
    }

    // MARK: songs

    /// Replace a music folder's songs with a fresh listing, keeping any
    /// analysis already stored for files that are still there.
    public func replaceSongs(libraryId: Int64, root: URL, files: [SongFile]) throws {
        try dbQueue.write { db in
            let existing = try SongRecord.filter(Column("libraryId") == libraryId).fetchAll(db)
            var byPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            for f in files {
                let url = URL(fileURLWithPath: f.path)
                seen.insert(f.path)
                if var rec = byPath.removeValue(forKey: f.path) {
                    rec.fileSize = f.fileSize; rec.modifiedAt = f.modified
                    rec.title = f.title; rec.artist = f.artist; rec.album = f.album; rec.duration = f.duration ?? rec.duration
                    try rec.update(db)
                } else {
                    var rec = SongRecord(id: nil, libraryId: libraryId, path: f.path, fileName: url.lastPathComponent,
                                         folder: SoundRecord.relativeFolder(of: url, in: root), fileSize: f.fileSize,
                                         modifiedAt: f.modified, title: f.title, artist: f.artist, album: f.album,
                                         duration: f.duration)
                    try rec.insert(db)
                }
            }
            for rec in byPath.values where !seen.contains(rec.path) { _ = try rec.delete(db) }
        }
    }

    public func songs(libraryId: Int64? = nil) throws -> [SongRecord] {
        try dbQueue.read { db in
            var q = SongRecord.order(Column("path"))
            if let libraryId { q = q.filter(Column("libraryId") == libraryId) }
            return try q.fetchAll(db)
        }
    }

    /// Stores Earmark's own analysis for songs that still have none (a Phase 0 import that
    /// came in meanwhile wins). Returns the updated songs.
    public func saveSongAnalysis(_ results: [(songId: Int64, analysis: SongAnalysis)]) throws -> [SongRecord] {
        try dbQueue.write { db in
            var updated: [SongRecord] = []
            for (id, analysis) in results {
                guard var rec = try SongRecord.fetchOne(db, key: id), rec.analysisSource == nil else { continue }
                rec.apply(analysis)
                try rec.update(db)
                updated.append(rec)
            }
            return updated
        }
    }

    /// Attach imported analysis to songs: by full path first, then by file
    /// name + size, then by a unique file name. Returns how many matched.
    @discardableResult
    public func applySongAnalysis(_ entries: [Phase0MusicImport.Entry]) throws -> Int {
        try dbQueue.write { db in
            let songs = try SongRecord.fetchAll(db)
            let byPath = Dictionary(songs.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let byNameSize = Dictionary(songs.map { ("\($0.fileName.lowercased())|\($0.fileSize)", $0) }, uniquingKeysWith: { a, _ in a })
            let byName = Dictionary(grouping: songs, by: { $0.fileName.lowercased() })
            var matched = 0
            for e in entries {
                var target: SongRecord?
                if let p = e.path { target = byPath[p] }
                if target == nil, let size = e.size { target = byNameSize["\(e.fileName.lowercased())|\(size)"] }
                if target == nil, let candidates = byName[e.fileName.lowercased()], candidates.count == 1 { target = candidates[0] }
                guard var rec = target else { continue }
                rec.apply(e.analysis)
                try rec.update(db)
                matched += 1
            }
            return matched
        }
    }
}

/// Analysis stage 1 for one sound: measured from the decoded audio.
public struct SoundFacts: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    /// Bump when the measurement changes, so every sound is measured again.
    public static let currentVersion = 1

    public var soundId: Int64
    public var fingerprint: String?
    public var version: Int
    /// Integrated loudness, LUFS (EBU R128).
    public var loudness: Double?
    /// Sample peak, dBFS.
    public var peak: Double?
    /// Why the file couldn't be measured (it isn't retried until the file or version changes).
    public var error: String?
    public var analyzedAt: Date

    public init(soundId: Int64, fingerprint: String?, loudness: LoudnessMeter.Result?, error: String? = nil,
                version: Int = SoundFacts.currentVersion, analyzedAt: Date = Date()) {
        self.soundId = soundId; self.fingerprint = fingerprint; self.version = version
        self.loudness = loudness?.integrated; self.peak = loudness?.peak
        self.error = error; self.analyzedAt = analyzedAt
    }

    /// Whether these facts still describe `sound` (same content, current version).
    public func isCurrent(for sound: SoundRecord) -> Bool {
        version >= Self.currentVersion && fingerprint == sound.fingerprint
    }
}

/// Analysis stage 2 for one sound: its embedding from one model (stored as float32 little-endian).
public struct SoundEmbedding: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    /// Bump a model's version when its pipeline changes, so every sound is embedded again.
    public static let versions: [String: Int] = ["clap-general": 1, "pe-av-large": 1]

    public struct Status: Sendable, Equatable {
        public var fingerprint: String?
        public var version: Int

        public init(fingerprint: String?, version: Int) { self.fingerprint = fingerprint; self.version = version }
    }

    public var soundId: Int64
    public var model: String
    public var fingerprint: String?
    public var version: Int
    /// nil for silent sounds, or when `error` is set.
    public var vector: Data?
    public var error: String?
    public var analyzedAt: Date

    public init(soundId: Int64, model: String, fingerprint: String?, vector: [Float]?, error: String? = nil,
                analyzedAt: Date = Date()) {
        self.soundId = soundId; self.model = model; self.fingerprint = fingerprint
        self.version = Self.versions[model] ?? 1
        self.vector = vector.map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
        self.error = error; self.analyzedAt = analyzedAt
    }

    public var values: [Float]? {
        vector.map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    }

    /// Whether a stored row still describes `sound` (same content, current pipeline).
    public static func isCurrent(_ status: Status?, model: String, for sound: SoundRecord) -> Bool {
        guard let status else { return false }
        return status.version >= (versions[model] ?? 1) && status.fingerprint == sound.fingerprint
    }
}
