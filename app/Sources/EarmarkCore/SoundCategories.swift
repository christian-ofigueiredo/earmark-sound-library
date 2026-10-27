import Foundation
import GRDB

/// A category for one sound: the owner's own choice, which wins over everything (even the
/// file's own category), or Earmark's guess from how it sounds, which only replaces a guess
/// for its folder.
public struct SoundCategoryChoice: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "soundCategory"
    public var soundId: Int64
    /// The file it was chosen for; a changed file loses it.
    public var fingerprint: String?
    public var catID: String
    public var byOwner: Bool
    /// Earmark's: its share of the vote of the sound's nearest (`CategoryVotes`), and the
    /// folder's guess it replaced.
    public var share: Double?
    public var replaced: String?
    public var version: Int
    public var createdAt: Date

    public init(soundId: Int64, fingerprint: String?, catID: String, byOwner: Bool, share: Double? = nil, replaced: String? = nil,
                version: Int = SoundCategories.version, createdAt: Date = Date()) {
        self.soundId = soundId; self.fingerprint = fingerprint; self.catID = catID; self.byOwner = byOwner
        self.share = share; self.replaced = replaced; self.version = version; self.createdAt = createdAt
    }
}

public enum SoundCategories {
    public static let ownerSource = "your choice for this sound"
    public static let soundGuessSource = "Earmark's guess from the sound"
    /// Bump when Earmark's guesses change: they're made again.
    public static let version = 1

    /// Per-sound categories over the folder ones (after `FolderRules.apply`): the owner's
    /// replace any category; Earmark's replace only a folder guess. Choices for a changed file
    /// (another fingerprint) are left out.
    public static func apply(_ choices: [Int64: SoundCategoryChoice], to sounds: [SoundRecord],
                             catalog: UCSCatalog = .shared) -> [SoundRecord] {
        guard !choices.isEmpty else { return sounds }
        return sounds.map { s in
            guard let id = s.id, let c = choices[id], c.fingerprint == s.fingerprint, let e = catalog.entry(catID: c.catID),
                  c.byOwner || s.categorySource == FolderRules.guessSource else { return s }
            var out = s
            out.catID = e.catID
            out.category = e.category
            out.subcategory = e.subcategory
            out.categorySource = c.byOwner ? ownerSource : soundGuessSource
            return out
        }
    }

    /// Earmark's guesses: for each sound whose category is its folder's guess, the category its
    /// nearest sounds in other folders vote for, when that's one of the folder guess's runners-up
    /// (`alternatives`) and the vote is clear (`CategoryVotes.disagrees`). On the owner's
    /// hand-checked folders (2026-10-27), 578 sounds got one: the folder's guess had been wrong
    /// for 71% of them, the new one is right for 62% (it was right for 29%).
    public static func guesses(sounds: [SoundRecord], votes: [[CategoryVotes.Vote]], alternatives: (SoundRecord) -> Set<String>,
                               strong: Double = 0.6, weak: Double = 0.1) -> [SoundCategoryChoice] {
        zip(sounds, votes).compactMap { s, v in
            guard let id = s.id, s.categorySource == FolderRules.guessSource, let top = v.first,
                  CategoryVotes.disagrees(v, with: s.catID, strong: strong, weak: weak),
                  alternatives(s).contains(top.catID) else { return nil }
            return SoundCategoryChoice(soundId: id, fingerprint: s.fingerprint, catID: top.catID, byOwner: false,
                                       share: top.share, replaced: s.catID)
        }
    }
}

extension LibraryDatabase {
    public func soundCategoryChoices() throws -> [Int64: SoundCategoryChoice] {
        try dbQueue.read { db in
            guard try db.tableExists("soundCategory") else { return [:] }
            return Dictionary(try SoundCategoryChoice.fetchAll(db).map { ($0.soundId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The owner's category for these sounds; nil takes their choice away (back to the
    /// folder's, or the file's own).
    public func setSoundCategory(_ sounds: [(id: Int64, fingerprint: String?)], catID: String?) throws {
        try dbQueue.write { db in
            for s in sounds {
                if let catID {
                    try SoundCategoryChoice(soundId: s.id, fingerprint: s.fingerprint, catID: catID, byOwner: true).save(db)
                } else {
                    _ = try SoundCategoryChoice.deleteOne(db, key: s.id)
                }
            }
        }
    }

    /// Replaces Earmark's per-sound guesses; the owner's choices stay. True if anything changed.
    @discardableResult
    public func replaceSoundGuesses(_ guesses: [SoundCategoryChoice]) throws -> Bool {
        try dbQueue.write { db in
            let old = try SoundCategoryChoice.filter(Column("byOwner") == false).fetchAll(db)
            let owners = Set(try Int64.fetchAll(db, sql: "SELECT soundId FROM soundCategory WHERE byOwner = 1"))
            let new = guesses.filter { !owners.contains($0.soundId) }
            func key(_ c: SoundCategoryChoice) -> String { "\(c.soundId) \(c.catID) \(c.fingerprint ?? "")" }
            guard Set(old.map(key)) != Set(new.map(key)) else { return false }
            try SoundCategoryChoice.filter(Column("byOwner") == false).deleteAll(db)
            for g in new { try g.insert(db) }
            return true
        }
    }
}
