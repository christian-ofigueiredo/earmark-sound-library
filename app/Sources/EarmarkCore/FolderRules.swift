import Foundation
import GRDB

/// A UCS category the user chose for the sounds of one folder that have none of their
/// own (the vendor's UCS metadata always wins). Stored in Earmark's database only.
public struct FolderRule: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public var libraryId: Int64
    /// Relative to the library, as `SoundRecord.folder`.
    public var folder: String
    public var catID: String
    public var createdAt: Date

    public init(libraryId: Int64, folder: String, catID: String, createdAt: Date = Date()) {
        self.libraryId = libraryId; self.folder = folder; self.catID = catID; self.createdAt = createdAt
    }
}

public enum FolderRules {
    public static let source = "your folder rule"

    /// Sounds without a category take the rule of their folder, or of the nearest folder
    /// above it that has one.
    public static func apply(_ rules: [FolderRule], to sounds: [SoundRecord], catalog: UCSCatalog = .shared) -> [SoundRecord] {
        guard !rules.isEmpty else { return sounds }
        var byFolder: [Int64: [String: UCSEntry]] = [:]
        for r in rules { if let e = catalog.entry(catID: r.catID) { byFolder[r.libraryId, default: [:]][r.folder] = e } }
        return sounds.map { s in
            guard s.catID == nil, let folders = byFolder[s.libraryId] else { return s }
            var folder = s.folder
            while true {
                if let e = folders[folder] {
                    var out = s
                    out.catID = e.catID; out.category = e.category; out.subcategory = e.subcategory
                    out.categorySource = source
                    return out
                }
                guard let slash = folder.lastIndex(of: "/") else { return s }
                folder = String(folder[..<slash])
            }
        }
    }
}

extension LibraryDatabase {
    public func folderRules() throws -> [FolderRule] {
        try dbQueue.read { db in try FolderRule.fetchAll(db) }
    }

    public func save(_ rules: [FolderRule]) throws {
        try dbQueue.write { db in for r in rules { try r.save(db) } }
    }

    public func removeFolderRule(libraryId: Int64, folder: String) throws {
        _ = try dbQueue.write { db in try FolderRule.deleteOne(db, key: ["libraryId": libraryId, "folder": folder]) }
    }
}

/// Suggests a UCS category for a folder of uncategorised sounds from two signals:
/// its name (folder words against UCS categories, subcategories and synonyms) and what
/// its sounds sound like (the categories of their nearest categorised neighbours).
public enum FolderSuggester {
    public struct Option: Sendable, Equatable {
        public var entry: UCSEntry
        public var score: Double
        /// Folder words that matched this entry's name or synonyms.
        public var words: [String]
        /// Share of the folder's nearest categorised neighbours in this subcategory (0…1).
        public var soundShare: Double
    }

    /// Words in folder names that say nothing about the content.
    static let stopWords: Set<String> = [
        "the", "and", "of", "a", "an", "in", "on", "for", "with", "by", "to", "from",
        "sfx", "fx", "sound", "sounds", "effect", "effects", "kit", "pack", "bundle", "library", "collection",
        "disk", "disc", "wav", "wave", "mp3", "aif", "aiff", "flac", "stereo", "mono", "hq", "hd", "version",
        "tsk", "vol", "volume", "part", "free", "pro", "complete", "ultimate", "series", "edition",
        "merry", "xmas", "christmas", "construction", "files", "file", "folder", "new", "other", "various",
    ]

    /// Lowercase, without plural "s".
    static func stem(_ w: String) -> String {
        var w = w.lowercased()
        if w.count > 4, w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
        else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
        return w
    }

    static let stemmedStopWords = Set(stopWords.map(stem))

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map { stem(String($0)) }
            .filter { $0.count > 1 && !stemmedStopWords.contains($0) }
    }

    /// Folder words, the deepest folder's first, without duplicates. The last two folders
    /// count fully (often category, then variant: "Footsteps/Concrete"); above them, half.
    static func folderWords(_ folder: String) -> [(word: String, weight: Double)] {
        let parts = folder.split(separator: "/").map(String.init)
        var seen = Set<String>(), out: [(String, Double)] = []
        for (i, part) in parts.enumerated().reversed() {
            let weight = i >= parts.count - 2 ? 1.0 : 0.5
            for w in words(part) where seen.insert(w).inserted { out.append((w, weight)) }
        }
        return out
    }

    struct Vocabulary: Sendable {
        var category: Set<String>, subcategory: Set<String>, synonyms: Set<String>
    }

    static func vocabulary(_ e: UCSEntry) -> Vocabulary {
        Vocabulary(category: Set(words(e.category)), subcategory: Set(words(e.subcategory)),
                   synonyms: Set(e.synonyms.flatMap(words)))
    }

    /// Name match per CatID, added up per word: category 3, subcategory 2, synonym 1, times the
    /// word's weight. Category names are the more specific ("Crowds" is CROWDS, not
    /// MOVEMENT / CROWD); synonyms pick the subcategory ("Footstep" is a synonym of
    /// FOOTSTEPS / HUMAN, so a "Footsteps" folder lands there rather than on ANIMAL).
    public static func nameScores(folder: String, catalog: UCSCatalog) -> [String: (score: Double, words: [String])] {
        detailedNameScores(folder: folder, catalog: catalog).mapValues { ($0.score, $0.words) }
    }

    /// As nameScores, with the part of the score that comes from the category's name alone
    /// (the rest is evidence for this particular subcategory).
    static func detailedNameScores(folder: String, catalog: UCSCatalog) -> [String: (score: Double, categoryPart: Double, words: [String])] {
        let fw = folderWords(folder)
        guard !fw.isEmpty else { return [:] }
        let vocab = catalog.entries.map { ($0, vocabulary($0)) }
        // A word in the subcategory names or synonyms of 3+ subcategories of one category says
        // only "this category" ("Automobile" is a synonym of VEHICLES / ALARM, BRAKE, CAR, MISC…).
        var spread: [String: [String: Int]] = [:]   // word → category → subcategories naming it
        for (w, _) in fw {
            for (e, v) in vocab where v.subcategory.contains(w) || v.synonyms.contains(w) { spread[w, default: [:]][e.category, default: 0] += 1 }
        }
        var out: [String: (Double, Double, [String])] = [:]
        for (e, v) in vocab {
            var score = 0.0, categoryPart = 0.0, matched: [String] = []
            for (w, weight) in fw {
                let c = v.category.contains(w) ? 3.0 : 0
                let sub = (v.subcategory.contains(w) ? 2.0 : 0) + (v.synonyms.contains(w) ? 1.0 : 0)
                guard c + sub > 0 else { continue }
                let general = (spread[w]?[e.category] ?? 0) >= 3
                score += (c + sub) * weight
                categoryPart += (c + (general ? sub : 0)) * weight
                matched.append(w)
            }
            if score > 0 { out[e.catID] = (score, categoryPart, matched) }
        }
        return out
    }

    /// Share of categorised neighbours per CatID: for up to `sample` of the folder's sounds,
    /// the `k` nearest sounds that have a category (`labels`), weighted by similarity.
    public static func soundShares(soundIds: [Int64], index: SimilarityIndex, labels: [Int64: String],
                                   k: Int = 10, sample: Int = 40) -> [String: Double] {
        let picked = soundIds.count <= sample ? soundIds
            : stride(from: 0, to: soundIds.count, by: max(1, soundIds.count / sample)).map { soundIds[$0] }
        let own = Set(soundIds)
        var votes: [String: Double] = [:]
        for id in picked where index.contains(id) {
            // Only categorised sounds from other folders can vote.
            let near = index.nearest(to: id, count: k * 4, excluding: own).filter { labels[$0.id] != nil }.prefix(k)
            for n in near { votes[labels[n.id]!, default: 0] += Double(max(0, n.score)) }
        }
        let total = votes.values.reduce(0, +)
        return total > 0 ? votes.mapValues { $0 / total } : [:]
    }

    /// Up to `count` options, best first. Name and sound are combined; a name that only
    /// gives the category (e.g. "Footsteps") lets the sound pick the subcategory.
    public static func suggest(folder: String, soundIds: [Int64], index: SimilarityIndex?, labels: [Int64: String],
                               catalog: UCSCatalog = .shared, count: Int = 3) -> [Option] {
        let detailed = detailedNameScores(folder: folder, catalog: catalog)
        let names = detailed.mapValues { (score: $0.score, words: $0.words) }
        let allShares = index.map { soundShares(soundIds: soundIds, index: $0, labels: labels) } ?? [:]
        var categoryShare: [String: Double] = [:]
        for (catID, s) in allShares { if let e = catalog.entry(catID: catID) { categoryShare[e.category, default: 0] += s } }
        // Under 10% of neighbours in one subcategory is noise, not evidence for it.
        let shares = allShares.filter { $0.value >= 0.1 }
        let maxName = names.values.map(\.score).max() ?? 0
        var candidates = Set(names.keys).union(shares.keys)
        if candidates.isEmpty { return [] }
        // A parent folder that names one UCS category decides the category; the folder below
        // is a variant ("Footsteps/Metal - Steel" is FOOTSTEPS, not METAL).
        let parts = folder.split(separator: "/").map(String.init)
        var locked: String?
        if parts.count >= 2 {
            let parentWords = Set(words(parts[parts.count - 2]))
            let named = Set(catalog.entries.filter { !vocabulary($0).category.isDisjoint(with: parentWords) }.map(\.category))
            if named.count == 1 { locked = named.first }
        }
        // Every subcategory of a category the name points to can be chosen by sound.
        for (catID, _) in names { if let e = catalog.entry(catID: catID) {
            for sub in catalog.entries where sub.category == e.category { candidates.insert(sub.catID) }
        } }
        if let locked {
            candidates = Set(catalog.entries.filter { $0.category == locked }.map(\.catID))
        }
        var options: [Option] = []
        for catID in candidates {
            guard let e = catalog.entry(catID: catID) else { continue }
            let name = maxName > 0 ? (names[catID]?.score ?? 0) / maxName : 0
            // The best name match within this entry's category counts for the category.
            let categoryName = maxName > 0
                ? (names.filter { catalog.entry(catID: $0.key)?.category == e.category }.map(\.value.score).max() ?? 0) / maxName : 0
            let share = shares[catID] ?? 0
            // Sound counts more when it clearly points one way (83% of neighbours in one
            // subcategory beats a single word of the name: "Quick Whips" are whooshes).
            let soundWeight = 1 + 2.5 * max(0, (shares.values.max() ?? 0) - 0.4)
            var score = 0.35 * name + 0.25 * categoryName + soundWeight * (0.25 * share + 0.15 * (categoryShare[e.category] ?? 0))
            let specificName = (detailed[catID]?.score ?? 0) - (detailed[catID]?.categoryPart ?? 0)
            if locked != nil { score += 0.5 * specificName / max(maxName, 1) }
            options.append(Option(entry: e, score: score, words: names[catID]?.words ?? [], soundShare: share))
        }
        // With nothing pointing to one subcategory over the others, MISC is the honest choice;
        // otherwise a specific subcategory beats MISC on equal evidence.
        if let top = options.max(by: { $0.score < $1.score }) {
            let sameCategory = options.filter { $0.entry.category == top.entry.category }
            let specific = sameCategory.contains { o in
                o.soundShare >= 0.1 || (detailed[o.entry.catID].map { $0.score - $0.categoryPart } ?? 0) > 0   // < 10%: noise
            }
            for i in options.indices where options[i].entry.category == top.entry.category && options[i].entry.subcategory == "MISC" {
                options[i].score += specific ? -0.001 : 0.001
            }
        }
        return Array(options.sorted {
            $0.score != $1.score ? $0.score > $1.score
                : $0.soundShare != $1.soundShare ? $0.soundShare > $1.soundShare : $0.entry.catID < $1.entry.catID
        }.prefix(count))
    }
}
