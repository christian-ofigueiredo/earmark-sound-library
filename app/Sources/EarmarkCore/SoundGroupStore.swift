import Foundation
import GRDB

/// A subcategory's groups as a whole: when Earmark last grouped it and whether the owner has
/// changed them (then Earmark never regroups it by itself).
public struct SoundGroupSet: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public var catID: String
    /// `SoundGroups.version` when grouped.
    public var version: Int
    /// How many sounds were grouped.
    public var grouped: Int
    /// Sounds added to or removed from the groups since (regrouped once that's a quarter).
    public var changed: Int
    /// The owner renamed, merged, moved or made a group here.
    public var edited: Bool
    public var groupedAt: Date

    public init(catID: String, version: Int = SoundGroups.version, grouped: Int, changed: Int = 0, edited: Bool = false,
                groupedAt: Date = Date()) {
        self.catID = catID; self.version = version; self.grouped = grouped; self.changed = changed
        self.edited = edited; self.groupedAt = groupedAt
    }
}

/// One similarity group.
public struct SoundGroupRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "soundGroup"
    public var id: Int64?
    public var catID: String
    /// Earmark's name ("Long · Splashy · Watery").
    public var name: String
    /// The owner's, if renamed.
    public var userName: String?
    /// The words behind Earmark's name, space-separated lists ("|" between words).
    public var aiWords: String
    public var shapeWords: String
    public var keywords: String
    /// Order in the sidebar (largest first when grouped).
    public var position: Int

    public init(id: Int64? = nil, catID: String, name: SoundGroups.Name, position: Int) {
        self.id = id; self.catID = catID; self.name = name.name; self.userName = nil
        aiWords = name.aiWords.joined(separator: "|"); shapeWords = name.shapeWords.joined(separator: "|")
        keywords = name.keywords.joined(separator: "|"); self.position = position
    }

    /// The name shown: the owner's, else Earmark's.
    public var title: String { userName ?? name }
    public var keywordList: [String] { keywords.split(separator: "|").map(String.init) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SoundGroupMember: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public var soundId: Int64
    public var fingerprint: String?
    public var soundGroupId: Int64

    public init(soundId: Int64, fingerprint: String?, soundGroupId: Int64) {
        self.soundId = soundId; self.fingerprint = fingerprint; self.soundGroupId = soundGroupId
    }
}

/// Everything about groups, read in one go.
public struct SoundGroupSnapshot: Sendable {
    public var sets: [String: SoundGroupSet] = [:]
    /// By catID, in sidebar order.
    public var groups: [String: [SoundGroupRecord]] = [:]
    public var byId: [Int64: SoundGroupRecord] = [:]
    /// Sound id → its group's id, for members whose file is unchanged since grouping (checked
    /// against the sounds by the caller: `memberFingerprints`).
    public var membership: [Int64: Int64] = [:]
    public var memberFingerprints: [Int64: String?] = [:]
    public init() {}
}

/// What to do with one subcategory's groups.
public enum SoundGroupWork: Equatable, Sendable {
    /// Group all of these sounds afresh (replacing any groups).
    case regroup(catID: String, sounds: [Int64])
    /// Keep the groups: put `add` in the nearest group, take `remove` out.
    case update(catID: String, add: [Int64], remove: [Int64])
    /// No sounds left: forget the groups.
    case drop(catID: String)
}

public enum SoundGroupPlan {
    /// What needs doing, given each subcategory's sounds that can be grouped now (analysed by
    /// both models, current files) and what's stored. A subcategory is grouped afresh when it
    /// has none, when its groups are from an older `SoundGroups.version`, or when a quarter of
    /// it has come or gone since; otherwise sounds join or leave the groups as they are. Groups
    /// the owner changed are never regrouped by Earmark (only by Regroup).
    public static func work(sounds: [String: [(id: Int64, fingerprint: String?)]], stored: SoundGroupSnapshot) -> [SoundGroupWork] {
        var out: [SoundGroupWork] = []
        for (catID, list) in sounds.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }) {
            let ids = list.map(\.id).sorted()
            guard let set = stored.sets[catID] else {
                if !ids.isEmpty { out.append(.regroup(catID: catID, sounds: ids)) }
                continue
            }
            let inGroups = Set((stored.groups[catID] ?? []).compactMap(\.id))
            // Members of this subcategory's groups, with the file they were grouped as.
            var current: Set<Int64> = []
            for s in list {
                if let g = stored.membership[s.id], inGroups.contains(g), stored.memberFingerprints[s.id] == .some(s.fingerprint) {
                    current.insert(s.id)
                }
            }
            let members = Set(stored.membership.filter { inGroups.contains($0.value) }.keys)
            let add = ids.filter { !current.contains($0) }
            let remove = members.subtracting(current).sorted()
            if ids.isEmpty {
                out.append(.drop(catID: catID))
            } else if !set.edited && (set.version < SoundGroups.version
                                      || (set.changed + add.count + remove.count) * 4 > max(set.grouped, 1)) {
                out.append(.regroup(catID: catID, sounds: ids))
            } else if !add.isEmpty || !remove.isEmpty {
                out.append(.update(catID: catID, add: add, remove: remove))
            }
        }
        for catID in stored.sets.keys.sorted() where sounds[catID] == nil { out.append(.drop(catID: catID)) }
        return out
    }

    /// The group whose centre (mean of its members, unit vectors) is nearest by cosine.
    /// `x`: rows of `d`; `members`: group id → rows. Nil when there are no groups.
    public static func nearest(_ v: [Float], x: UnsafeBufferPointer<Float>, d: Int, members: [Int64: [Int]]) -> Int64? {
        var best: (Int64, Float)?
        for (g, rows) in members where !rows.isEmpty {
            var centre = [Float](repeating: 0, count: d)
            for r in rows { for c in 0 ..< d { centre[c] += x[r * d + c] } }
            let norm = max(centre.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-12)
            var dot: Float = 0
            for (c, value) in v.enumerated() { dot += value * centre[c] }
            let score = dot / norm
            if best.map({ score > $0.1 || score == $0.1 && g < $0.0 }) ?? true { best = (g, score) }
        }
        return best?.0
    }
}

extension LibraryDatabase {
    public func soundGroupSnapshot() throws -> SoundGroupSnapshot {
        try dbQueue.read { db in
            var snap = SoundGroupSnapshot()
            for s in try SoundGroupSet.fetchAll(db) { snap.sets[s.catID] = s }
            for g in try SoundGroupRecord.order(Column("catID"), Column("position"), Column("id")).fetchAll(db) {
                snap.groups[g.catID, default: []].append(g)
                if let id = g.id { snap.byId[id] = g }
            }
            for m in try SoundGroupMember.fetchAll(db) {
                snap.membership[m.soundId] = m.soundGroupId
                snap.memberFingerprints[m.soundId] = m.fingerprint
            }
            return snap
        }
    }

    /// Replaces a subcategory's groups with freshly made ones (`groups[i]` named `names[i]`).
    public func replaceGroups(catID: String, groups: [[(id: Int64, fingerprint: String?)]], names: [SoundGroups.Name]) throws {
        try dbQueue.write { db in
            try SoundGroupRecord.filter(Column("catID") == catID).deleteAll(db)
            for (i, members) in groups.enumerated() where !members.isEmpty {
                var g = SoundGroupRecord(catID: catID, name: names[i], position: i)
                try g.insert(db)
                for m in members {
                    try SoundGroupMember(soundId: m.id, fingerprint: m.fingerprint, soundGroupId: g.id!).save(db)
                }
            }
            try SoundGroupSet(catID: catID, grouped: groups.reduce(0) { $0 + $1.count }).save(db)
        }
    }

    /// Sounds join groups (`add`: sound → group) or leave this subcategory's; groups left empty go.
    public func updateGroups(catID: String, add: [(id: Int64, fingerprint: String?, group: Int64)], remove: [Int64]) throws {
        try dbQueue.write { db in
            // Only from this subcategory's groups: a sound whose category changed may already
            // have joined another's.
            for id in remove {
                try db.execute(sql: """
                    DELETE FROM soundGroupMember WHERE soundId = ? AND soundGroupId IN (SELECT id FROM soundGroup WHERE catID = ?)
                    """, arguments: [id, catID])
            }
            for a in add { try SoundGroupMember(soundId: a.id, fingerprint: a.fingerprint, soundGroupId: a.group).save(db) }
            try Self.dropEmptyGroups(db, catID: catID)
            if var set = try SoundGroupSet.fetchOne(db, key: catID) {
                set.changed += add.count + remove.count
                try set.update(db)
            }
        }
    }

    public func dropGroups(catID: String) throws {
        try dbQueue.write { db in
            try SoundGroupRecord.filter(Column("catID") == catID).deleteAll(db)
            _ = try SoundGroupSet.deleteOne(db, key: catID)
        }
    }

    // MARK: the owner's changes

    /// A new name for a group; nil goes back to Earmark's.
    public func renameGroup(_ id: Int64, to name: String?) throws {
        try dbQueue.write { db in
            guard var g = try SoundGroupRecord.fetchOne(db, key: id) else { return }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            g.userName = trimmed?.isEmpty == false && trimmed != g.name ? trimmed : nil
            try g.update(db)
            try Self.markEdited(db, catID: g.catID)
        }
    }

    /// Moves these sounds into a group (of their own subcategory); groups left empty go.
    public func moveSounds(_ sounds: [(id: Int64, fingerprint: String?)], toGroup id: Int64) throws {
        try dbQueue.write { db in
            guard let g = try SoundGroupRecord.fetchOne(db, key: id) else { return }
            for s in sounds { try SoundGroupMember(soundId: s.id, fingerprint: s.fingerprint, soundGroupId: id).save(db) }
            try Self.dropEmptyGroups(db, catID: g.catID)
            try Self.markEdited(db, catID: g.catID)
        }
    }

    /// A new group of these sounds, after the subcategory's others. Returns its id.
    @discardableResult
    public func newGroup(catID: String, name: String, sounds: [(id: Int64, fingerprint: String?)]) throws -> Int64 {
        try dbQueue.write { db in
            let last = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM soundGroup WHERE catID = ?", arguments: [catID]) ?? -1
            var g = SoundGroupRecord(catID: catID, name: SoundGroups.Name(name: name, aiWords: [], shapeWords: [], keywords: []),
                                     position: last + 1)
            try g.insert(db)
            for s in sounds { try SoundGroupMember(soundId: s.id, fingerprint: s.fingerprint, soundGroupId: g.id!).save(db) }
            try Self.dropEmptyGroups(db, catID: catID)
            if try SoundGroupSet.fetchOne(db, key: catID) == nil {
                try SoundGroupSet(catID: catID, grouped: sounds.count).save(db)
            }
            try Self.markEdited(db, catID: catID)
            return g.id!
        }
    }

    /// Moves every sound of `groups` into `target` and removes those groups.
    public func mergeGroups(_ groups: [Int64], into target: Int64) throws {
        try dbQueue.write { db in
            guard let t = try SoundGroupRecord.fetchOne(db, key: target) else { return }
            for g in groups where g != target {
                try db.execute(sql: "UPDATE soundGroupMember SET soundGroupId = ? WHERE soundGroupId = ?", arguments: [target, g])
                _ = try SoundGroupRecord.deleteOne(db, key: g)
            }
            try Self.markEdited(db, catID: t.catID)
        }
    }

    /// Forgets a subcategory's groups and the owner's changes, so Earmark groups it afresh.
    public func regroup(catID: String) throws { try dropGroups(catID: catID) }

    static func markEdited(_ db: Database, catID: String) throws {
        try db.execute(sql: "UPDATE soundGroupSet SET edited = 1 WHERE catID = ?", arguments: [catID])
    }

    static func dropEmptyGroups(_ db: Database, catID: String) throws {
        try db.execute(sql: """
            DELETE FROM soundGroup WHERE catID = ? AND id NOT IN (SELECT DISTINCT soundGroupId FROM soundGroupMember)
            """, arguments: [catID])
    }
}
