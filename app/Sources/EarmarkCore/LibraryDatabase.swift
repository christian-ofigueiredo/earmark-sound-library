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

    public static let databaseTableName = "song"
    public var url: URL { URL(fileURLWithPath: path) }
    public var displayTitle: String { title?.isEmpty == false ? title! : url.deletingPathExtension().lastPathComponent }
    public var key: MusicKey? { keyPitchClass.map { MusicKey(pitchClass: $0, minor: keyMinor ?? false) } }

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

    public func removeLibrary(id: Int64) throws {
        _ = try dbQueue.write { db in try Library.deleteOne(db, key: id) }
    }

    // MARK: sounds

    /// Replace a library's sounds with a fresh scan. Records for files that
    /// still exist keep their id; files no longer present are removed.
    /// Only call this when the library folder is online.
    public func replaceSounds(libraryId: Int64, root: URL, scanned: [ScannedSound]) throws {
        try dbQueue.write { db in
            let existing = try Row.fetchAll(db, sql: "SELECT id, path FROM sound WHERE libraryId = ?", arguments: [libraryId])
            var idByPath: [String: Int64] = [:]
            for row in existing { idByPath[row["path"]] = row["id"] }
            var seen = Set<String>()
            for s in scanned {
                var rec = SoundRecord(libraryId: libraryId, root: root, scanned: s)
                seen.insert(rec.path)
                if let id = idByPath[rec.path] { rec.id = id; try rec.update(db) } else { try rec.insert(db) }
            }
            for (path, id) in idByPath where !seen.contains(path) { _ = try SoundRecord.deleteOne(db, key: id) }
        }
    }

    public func sounds(libraryId: Int64? = nil) throws -> [SoundRecord] {
        try dbQueue.read { db in
            var q = SoundRecord.order(Column("path"))
            if let libraryId { q = q.filter(Column("libraryId") == libraryId) }
            return try q.fetchAll(db)
        }
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
