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

/// A category Earmark guessed for a folder whose sounds have none (the folder's best
/// suggestion), applied without asking until the user picks one. Stored in Earmark's
/// database only; made again when `FolderSuggester.version` changes.
public struct FolderGuess: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public var libraryId: Int64
    /// Relative to the library, as `SoundRecord.folder`.
    public var folder: String
    public var catID: String
    /// The next options, best first, comma-separated ("FEETAnml,FEETCrea").
    public var alternatives: String
    /// Why, as the app shows it ("name “footstep” · files “foot walk”").
    public var reason: String
    /// Another category fits as well, or nothing but a few similar sounds agree.
    public var isUnsure: Bool
    /// How many of the folder's sounds had been analysed (CLAP) when guessing.
    public var analysed: Int
    public var version: Int
    public var createdAt: Date

    public init(libraryId: Int64, folder: String, catID: String, alternatives: [String], reason: String,
                isUnsure: Bool, analysed: Int, version: Int = FolderSuggester.version, createdAt: Date = Date()) {
        self.libraryId = libraryId; self.folder = folder; self.catID = catID
        self.alternatives = alternatives.joined(separator: ","); self.reason = reason; self.isUnsure = isUnsure
        self.analysed = analysed; self.version = version; self.createdAt = createdAt
    }

    public var alternativeIDs: [String] { alternatives.split(separator: ",").map(String.init) }
}

public enum FolderRules {
    public static let source = "your folder rule"
    public static let guessSource = "Earmark's guess"

    /// Sounds without a category of their own take the user's rule for their folder or the
    /// nearest folder above it; failing that, Earmark's guess, found the same way.
    public static func apply(_ rules: [FolderRule], guesses: [FolderGuess] = [], to sounds: [SoundRecord],
                             catalog: UCSCatalog = .shared) -> [SoundRecord] {
        guard !rules.isEmpty || !guesses.isEmpty else { return sounds }
        func index(_ pairs: [(Int64, String, String)]) -> [Int64: [String: UCSEntry]] {
            var out: [Int64: [String: UCSEntry]] = [:]
            for (lib, folder, catID) in pairs { if let e = catalog.entry(catID: catID) { out[lib, default: [:]][folder] = e } }
            return out
        }
        let chosen = index(rules.map { ($0.libraryId, $0.folder, $0.catID) })
        let guessed = index(guesses.map { ($0.libraryId, $0.folder, $0.catID) })
        func nearest(_ s: SoundRecord, in folders: [String: UCSEntry]?) -> UCSEntry? {
            guard let folders else { return nil }
            var folder = s.folder
            while true {
                if let e = folders[folder] { return e }
                guard let slash = folder.lastIndex(of: "/") else { return nil }
                folder = String(folder[..<slash])
            }
        }
        return sounds.map { s in
            guard s.catID == nil else { return s }
            var out = s
            if let e = nearest(s, in: chosen[s.libraryId]) {
                out.categorySource = source
                out.catID = e.catID; out.category = e.category; out.subcategory = e.subcategory
            } else if let e = nearest(s, in: guessed[s.libraryId]) {
                out.categorySource = guessSource
                out.catID = e.catID; out.category = e.category; out.subcategory = e.subcategory
            }
            return out
        }
    }

    /// The folder whose rule (or guess) applies to a sound in `folder`, if any.
    public static func ruleFolder(for folder: String, in folders: Set<String>) -> String? {
        var folder = folder
        while true {
            if folders.contains(folder) { return folder }
            guard let slash = folder.lastIndex(of: "/") else { return nil }
            folder = String(folder[..<slash])
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

    public func folderGuesses() throws -> [FolderGuess] {
        try dbQueue.read { db in try FolderGuess.fetchAll(db) }
    }

    /// Saves new guesses and forgets those of folders that no longer need one.
    public func updateGuesses(saving guesses: [FolderGuess], removing stale: [(libraryId: Int64, folder: String)]) throws {
        try dbQueue.write { db in
            for g in guesses { try g.save(db) }
            for s in stale { _ = try FolderGuess.deleteOne(db, key: ["libraryId": s.libraryId, "folder": s.folder]) }
        }
    }
}

/// Suggests a UCS category for a folder of uncategorised sounds from three signals: its
/// name (folder words against UCS categories, subcategories and synonyms), the words most of
/// its files share (file names and descriptions), and what its sounds sound like (the
/// categories of their nearest neighbours that have one).
public enum FolderSuggester {
    /// Bumped when suggestions change, so Earmark's guesses are made again.
    public static let version = 2

    public struct Option: Sendable, Equatable {
        public var entry: UCSEntry
        public var score: Double
        /// Folder words that matched this entry's name or synonyms.
        public var words: [String]
        /// Words most of the folder's files share (names, descriptions) that matched this entry.
        public var fileWords: [String]
        /// Share of the folder's nearest categorised neighbours in this subcategory (0…1).
        public var soundShare: Double
        /// The words fit other categories as well and the sound doesn't settle it
        /// ("Pickups": a synonym of METAL, GLASS, WOOD… / HANDLE): worth listening first.
        public var isUncertain = false

        /// Worth listening to before trusting: uncertain, or nothing but a few similar sounds agree.
        public var isWeak: Bool { isUncertain || words.isEmpty && fileWords.isEmpty && soundShare < 0.3 }
    }

    /// Knobs for measuring the suggestions (`earmark-parity folders`); the app uses `.standard`.
    public struct Tuning: Sendable {
        /// Vendor and pack names (the sounds' designer, the library's top folder above a deeper
        /// folder) count only when the sound agrees: "BOOM Library" says nothing about sci-fi hums.
        public var packWords = true
        /// Weight of a word all the files share, next to a word of the folder's name (1).
        public var fileWeight = 0.8
        /// …times this when the folder's name already names a category or subcategory.
        public var fileWeightBesideStrongName = 0.5
        /// A folder isn't locked to its parent's category when its own name repeats that
        /// category and names another ("Monsters & Creatures/Creature Footsteps"), or when most
        /// of its files name a subcategory of another ("Human Vocal Full Sets/Male_…", VOICES / MALE).
        public var leafOverridesParent = true
        /// Weight of words from descriptions many folders share (a vendor's collection names:
        /// "Sports & Recreation"), next to the folder's own files' words (1).
        public var sharedDescriptionWeight = 0.35
        /// Share of the files a word must be in to count.
        public var minFileShare = 0.3
        /// The last of the options goes to another category when all the others share one.
        public var otherCategoryLast = true
        /// Sound shares count fully once this share of the nearest-neighbour places have a category.
        public var soundCoverage = 0.25

        public init() {}
        public static let standard = Tuning()
    }

    /// Words in folder and file names that say nothing about the content.
    static let stopWords: Set<String> = [
        "the", "and", "of", "a", "an", "in", "on", "for", "with", "by", "to", "from", "up",
        "sfx", "fx", "sound", "sounds", "effect", "effects", "kit", "pack", "bundle", "library", "collection",
        "disk", "disc", "wav", "wave", "mp", "mp3", "aif", "aiff", "aac", "flac", "stereo", "mono", "hq", "hd", "version",
        "tsk", "vol", "volume", "part", "free", "pro", "complete", "ultimate", "series", "edition",
        "merry", "xmas", "christmas", "construction", "files", "file", "folder", "new", "other", "various",
        // A format, not a sound: "Sci-Fi Loops" are sci-fi, not MUSICAL / LOOP.
        "loop",
    ]

    /// Words in file names and descriptions that describe how, not what ("Short", "Key A#",
    /// "Long Reverb"): many are UCS synonyms that would point elsewhere.
    static let fileStopWords: Set<String> = [
        "low", "high", "large", "small", "big", "short", "long", "medium", "deep", "fast", "slow", "soft", "hard",
        "heavy", "light", "dark", "bright", "dry", "wet", "close", "far", "near", "distant", "single", "key",
        "reverb", "tail", "empty", "audio", "mastered", "master",
    ]

    /// Lowercase, without plural "s" and with no letter three times running ("Braaams" → "braam").
    static func stem(_ w: String) -> String {
        var w = w.lowercased()
        var collapsed = "", run = 0, last: Character?
        for c in w {
            run = c == last ? run + 1 : 1
            last = c
            if run <= 2 { collapsed.append(c) }
        }
        w = collapsed
        if w.count > 4, w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
        else if w.count > 4, ["shes", "ches", "xes", "sses", "zzes"].contains(where: w.hasSuffix) { w.removeLast(2) }   // whooshes, boxes
        else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
        return w
    }

    static let stemmedStopWords = Set(stopWords.map(stem))

    /// Words as UCS spells them: "StreetBall_HitPad2" → street, ball, hit, pad; "Sci-Fi" and
    /// "SCI FI" also give "scifi", "Hi-Tech" "hitech".
    static func words(_ text: String) -> [String] {
        var tokens: [String] = []
        var joined: [String] = []   // hyphenated words written together ("Coin-Op" → "coinop")
        for chunk in text.split(whereSeparator: { !$0.isLetter && $0 != "-" }) {
            let parts = chunk.split(separator: "-")
            if parts.count > 1 { joined.append(parts.joined().lowercased()) }
            for part in parts { tokens += splitCase(String(part)) }
        }
        var out: [String] = []
        for (i, t) in tokens.enumerated() {
            out.append(stem(t))
            // "-ies" is "-y" (Batteries) or "-ie" (Zombies, Movies): keep both.
            if t.count > 4, t.lowercased().hasSuffix("ies") { out.append(String(t.lowercased().dropLast())) }
            if i > 0, ["scifi", "hitech"].contains((tokens[i - 1] + t).lowercased()) { out.append((tokens[i - 1] + t).lowercased()) }
        }
        return (out + joined.map(stem)).filter { $0.count > 1 && !stemmedStopWords.contains($0) }
    }

    /// "StreetBall" → Street, Ball; "SFXPack" → SFX, Pack; "BMX" stays.
    static func splitCase(_ word: String) -> [String] {
        let chars = Array(word)
        var out: [String] = [], current = ""
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase
                || (chars[i - 1].isUppercase && i + 1 < chars.count && chars[i + 1].isLowercase) {
                out.append(current)
                current = ""
            }
            current.append(c)
        }
        out.append(current)
        return out.filter { !$0.isEmpty }
    }

    /// Folder words, the deepest folder's first, without duplicates. The last two folders
    /// count fully (often category, then variant: "Footsteps/Concrete"); above them, half.
    public static func folderWords(_ folder: String) -> [(word: String, weight: Double)] {
        let parts = folder.split(separator: "/").map(String.init)
        var seen = Set<String>(), out: [(String, Double)] = []
        for (i, part) in parts.enumerated().reversed() {
            let weight = i >= parts.count - 2 ? 1.0 : 0.5
            for w in words(part) where seen.insert(w).inserted { out.append((w, weight)) }
        }
        return out
    }

    /// Words of the designer most of these sounds name: usually the vendor ("BOOM Library").
    public static func packWords(of sounds: [SoundRecord]) -> Set<String> {
        let designers = Dictionary(grouping: sounds.compactMap(\.designer), by: { $0 }).mapValues(\.count)
        return Set(designers.filter { 2 * $0.value >= sounds.count }.keys.flatMap(words))
    }

    /// Descriptions shared by sounds in `minFolders` or more folders: a vendor's collection names
    /// ("Sports & Recreation"), which say less about a folder than its own name.
    public static func sharedDescriptions(_ sounds: [SoundRecord], minFolders: Int = 3) -> Set<String> {
        var folders: [String: Set<String>] = [:]
        for s in sounds { if let d = s.details, !d.isEmpty { folders[d, default: []].insert("\(s.libraryId)|\(s.folder)") } }
        return Set(folders.filter { $0.value.count >= minFolders }.keys)
    }

    /// Words at least `minFileShare` of these sounds have in their file name, FXName,
    /// description or keywords, with that share (up to 12, commonest first). Of a UCS file name only the
    /// FXName counts: the rest names the vendor and the collection.
    public static func fileWords(of sounds: [SoundRecord], sharedDescriptions: Set<String> = [],
                                 catalog: UCSCatalog = .shared, tuning: Tuning = .standard) -> [String: Double] {
        let sample = sounds.count <= 400 ? sounds : stride(from: 0, to: sounds.count, by: sounds.count / 400 + 1).map { sounds[$0] }
        guard !sample.isEmpty else { return [:] }
        var counts: [String: Double] = [:]
        for s in sample {
            let stem = s.fileName.lastIndex(of: ".").map { String(s.fileName[..<$0]) } ?? s.fileName
            let name = catalog.parseFilename(stem).map { $0.fxName ?? "" } ?? stem
            var own = Set([name, s.fxName ?? "", s.keywords ?? ""].flatMap(words)), shared = Set<String>()
            if let d = s.details { if sharedDescriptions.contains(d) { shared = Set(words(d)) } else { own.formUnion(words(d)) } }
            for w in own where w.count > 2 && !fileStopWords.contains(w) { counts[w, default: 0] += 1 }
            for w in shared.subtracting(own) where w.count > 2 && !fileStopWords.contains(w) {
                counts[w, default: 0] += tuning.sharedDescriptionWeight
            }
        }
        let n = Double(sample.count)
        let common = counts.filter { $0.value >= tuning.minFileShare * n }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return Dictionary(uniqueKeysWithValues: common.prefix(12).map { ($0.key, $0.value / n) })
    }

    /// The UCS list indexed by word, built once per catalog.
    struct Lexicon: Sendable {
        struct Entry: Sendable {
            var entry: UCSEntry
            var category: Set<String>, subcategory: Set<String>, synonyms: Set<String>
        }
        let entries: [Entry]
        let byWord: [String: [Int]]
        /// Word → category → how many of its subcategories have the word in their name or synonyms.
        let subcategorySpread: [String: [String: Int]]
        /// Category → its entries.
        let byCategory: [String: [Int]]
        /// Words of category names ("glass", "metal", "footstep"…).
        let categoryWords: Set<String>

        init(_ catalog: UCSCatalog) {
            entries = catalog.entries.map { e in
                Entry(entry: e, category: Set(FolderSuggester.words(e.category)), subcategory: Set(FolderSuggester.words(e.subcategory)),
                      synonyms: Set(e.synonyms.flatMap(FolderSuggester.words)))
            }
            var byWord: [String: [Int]] = [:], spread: [String: [String: Int]] = [:], byCategory: [String: [Int]] = [:]
            for (i, e) in entries.enumerated() {
                byCategory[e.entry.category, default: []].append(i)
                for w in e.category.union(e.subcategory).union(e.synonyms) { byWord[w, default: []].append(i) }
                for w in e.subcategory.union(e.synonyms) { spread[w, default: [:]][e.entry.category, default: 0] += 1 }
            }
            self.byWord = byWord
            subcategorySpread = spread
            self.byCategory = byCategory
            categoryWords = Set(entries.flatMap(\.category))
        }

        static let shared = Lexicon(.shared)
        static func of(_ catalog: UCSCatalog) -> Lexicon { catalog === UCSCatalog.shared ? shared : Lexicon(catalog) }
    }

    /// A word for or against the folder's category, from its name or its files.
    struct Evidence {
        var word: String
        var weight: Double
        var fromName: Bool
        /// A parent folder's word under its lock: it names a group ("Monsters & Creatures"), not
        /// a subcategory, so a subcategory named like it gets nothing for it; its synonyms still
        /// count ("Footstep" is a synonym of FOOTSTEPS / HUMAN, the usual footsteps).
        var groupName = false
    }

    struct NameScore {
        var score = 0.0
        /// The part that comes from the category's name alone (the rest is evidence for
        /// this particular subcategory).
        var categoryPart = 0.0
        var words: [String] = []
        var fileWords: [String] = []
    }

    /// Match per CatID, added up per word: category 3, subcategory 2, synonym 1, times the
    /// word's weight. Category names are the more specific ("Crowds" is CROWDS, not
    /// MOVEMENT / CROWD); synonyms pick the subcategory ("Footstep" is a synonym of
    /// FOOTSTEPS / HUMAN, so a "Footsteps" folder lands there rather than on ANIMAL).
    static func scores(_ evidence: [Evidence], lexicon: Lexicon) -> [String: NameScore] {
        var out: [String: NameScore] = [:]
        func add(_ i: Int, _ points: Double, categoryPart: Double, _ ev: Evidence) {
            let id = lexicon.entries[i].entry.catID
            var s = out[id, default: NameScore()]
            s.score += points * ev.weight
            s.categoryPart += categoryPart * ev.weight
            if ev.fromName { if !s.words.contains(ev.word) { s.words.append(ev.word) } }
            else if !s.fileWords.contains(ev.word) { s.fileWords.append(ev.word) }
            out[id] = s
        }
        for ev in evidence {
            guard let hits = lexicon.byWord[ev.word] else { continue }
            var general = Set<String>()   // categories where the word is only a synonym-level hint
            for i in hits {
                let e = lexicon.entries[i]
                let c = e.category.contains(ev.word) ? 3.0 : 0
                let named = e.subcategory.contains(ev.word) && !ev.groupName ? 2.0 : 0
                let sub = named + (e.synonyms.contains(ev.word) ? 1.0 : 0)
                // A word in 3+ subcategories of one category says only "this category"
                // ("Automobile" is a synonym of VEHICLES / ALARM, BRAKE, CAR, MISC…): every
                // subcategory gets a synonym's point, below; one named after the word keeps
                // the rest ("Trucks": VEHICLES / TRUCK VAN & SUV).
                if (lexicon.subcategorySpread[ev.word]?[e.entry.category] ?? 0) >= 3 {
                    general.insert(e.entry.category)
                    if c + named > 0 { add(i, c + named, categoryPart: c, ev) }
                } else {
                    add(i, c + sub, categoryPart: c, ev)
                }
            }
            for category in general {
                for i in lexicon.byCategory[category] ?? [] { add(i, 1, categoryPart: 1, ev) }
            }
        }
        return out
    }

    /// The folder's name alone, per CatID.
    public static func nameScores(folder: String, catalog: UCSCatalog) -> [String: (score: Double, words: [String])] {
        scores(folderWords(folder).map { Evidence(word: $0.word, weight: $0.weight, fromName: true) },
               lexicon: .of(catalog)).mapValues { ($0.score, $0.words) }
    }

    /// `suggest` for a folder's sounds as the library has them: with their files' words and
    /// designer. `sharedDescriptions`: from `sharedDescriptions(_:)` over the whole library.
    public static func suggest(folder: String, sounds: [SoundRecord], index: SimilarityIndex?, labels: [Int64: String],
                               sharedDescriptions: Set<String>, count: Int = 3, tuning: Tuning = .standard) -> [Option] {
        suggest(folder: folder, soundIds: sounds.compactMap(\.id), index: index, labels: labels,
                fileWords: fileWords(of: sounds, sharedDescriptions: sharedDescriptions, tuning: tuning),
                packWords: packWords(of: sounds), count: count, tuning: tuning)
    }

    /// The categories that came with the files (not the user's rules or Earmark's guesses):
    /// what the sound signal learns from.
    public static func labels(_ sounds: [SoundRecord]) -> [Int64: String] {
        var out: [Int64: String] = [:]
        for s in sounds where s.categorySource != FolderRules.source && s.categorySource != FolderRules.guessSource {
            if let id = s.id, let catID = s.catID { out[id] = catID }
        }
        return out
    }

    /// Share of categorised neighbours per CatID: for up to `sample` of the folder's sounds,
    /// the `k` nearest sounds that have a category (`labels`, among the 4k nearest), weighted
    /// by similarity. When fewer than `fullAt` of those k places are found, the shares shrink
    /// in proportion: three neighbours that happen to be swords aren't "100% swords".
    public static func soundShares(soundIds: [Int64], index: SimilarityIndex, labels: [Int64: String],
                                   k: Int = 10, sample: Int = 40, fullAt: Double = 0.25) -> [String: Double] {
        let picked = soundIds.count <= sample ? soundIds
            : stride(from: 0, to: soundIds.count, by: max(1, soundIds.count / sample)).map { soundIds[$0] }
        let own = Set(soundIds)
        var votes: [String: Double] = [:]
        var found = 0, places = 0
        for id in picked where index.contains(id) {
            // Only categorised sounds from other folders can vote.
            let near = index.nearest(to: id, count: k * 4, excluding: own).filter { labels[$0.id] != nil }.prefix(k)
            for n in near { votes[labels[n.id]!, default: 0] += Double(max(0, n.score)) }
            found += near.count
            places += k
        }
        let total = votes.values.reduce(0, +)
        guard total > 0 else { return [:] }
        let coverage = fullAt > 0 ? min(1, Double(found) / (fullAt * Double(places))) : 1
        return votes.mapValues { coverage * $0 / total }
    }

    /// Up to `count` options, best first. Name, files and sound are combined; a name that only
    /// gives the category (e.g. "Footsteps") lets the sound pick the subcategory.
    /// `fileWords`: from `fileWords(of:)`; `packWords`: from `packWords(of:)`.
    public static func suggest(folder: String, soundIds: [Int64], index: SimilarityIndex?, labels: [Int64: String],
                               fileWords: [String: Double] = [:], packWords: Set<String> = [],
                               catalog: UCSCatalog = .shared, count: Int = 3, tuning: Tuning = .standard) -> [Option] {
        let lexicon = Lexicon.of(catalog)
        let allShares = index.map { soundShares(soundIds: soundIds, index: $0, labels: labels, fullAt: tuning.soundCoverage) } ?? [:]
        var categoryShare: [String: Double] = [:]
        for (catID, s) in allShares { if let e = catalog.entry(catID: catID) { categoryShare[e.category, default: 0] += s } }
        // Vendor and pack names: the designer's, and the top folder's when the folder is deeper
        // ("Lens Distortions - …/Anticipation SFX - WAV/01 - Risers/Risers - Tube").
        let parts = folder.split(separator: "/").map(String.init)
        var pack = tuning.packWords ? packWords : []
        if tuning.packWords, parts.count >= 3 { pack.formUnion(words(parts[0])) }
        func soundAgrees(_ word: String) -> Bool {
            (lexicon.byWord[word] ?? []).contains { i in
                let e = lexicon.entries[i]
                return (allShares[e.entry.catID] ?? 0) >= 0.1
                    || e.category.contains(word) && (categoryShare[e.entry.category] ?? 0) >= 0.25
            }
        }
        // A parent folder that names one UCS category decides the category; the folder below
        // is a variant ("Footsteps/Metal - Steel" is FOOTSTEPS, not METAL).
        var locked: String?
        if parts.count >= 2 {
            func named(_ ws: Set<String>) -> Set<String> {
                Set(lexicon.entries.filter { !$0.category.isDisjoint(with: ws.subtracting(pack)) }.map(\.entry.category))
            }
            let parentWords = Set(words(parts[parts.count - 2])).subtracting(pack)
            let parent = named(parentWords)
            if parent.count == 1, let category = parent.first {
                // A parent that is only the category's name ("Footsteps") holds its folders
                // whatever their files say ("Leaves", "Swamp"); one with other words that mean
                // something ("Human Vocal Full Sets") is a looser grouping.
                let ownName = Set(catalog.subcategories(of: category).first.map { words($0.category) } ?? [])
                let loose = parentWords.subtracting(ownName).contains { lexicon.byWord[$0] != nil }
                let leaf = named(Set(words(parts[parts.count - 1])))
                // Most files name a subcategory of another category, not this one ("Mechanical/
                // …CameraShutter": COMMUNICATIONS / CAMERA). Not a word that names a category
                // anywhere: those are materials, which the lock is for ("Footsteps/Glass",
                // "Foot_Glass_…", even though DOORS and RAIN have a GLASS subcategory).
                let files = Set(fileWords.filter { $0.value >= 0.5 }.keys).subtracting(lexicon.categoryWords)
                let filesElsewhere = lexicon.entries.filter { !$0.subcategory.isDisjoint(with: files) }.map(\.entry.category)
                let released = tuning.leafOverridesParent
                    && (leaf.contains(category) && leaf.count >= 2
                        || loose && !filesElsewhere.isEmpty && !filesElsewhere.contains(category))
                if !released { locked = category }
            }
        }
        // Under a lock the parent's words name a group: the folder's own words, its files and
        // the sound pick the subcategory ("Monsters & Creatures/Ghosts" is ETHEREAL, not MONSTER).
        let parentOnly = parts.count >= 2 && locked != nil
            ? Set(words(parts[parts.count - 2])).subtracting(words(parts[parts.count - 1])) : []
        var evidence = folderWords(folder).map {
            Evidence(word: $0.word, weight: $0.weight, fromName: true, groupName: parentOnly.contains($0.word))
        }
        evidence.removeAll { pack.contains($0.word) && !soundAgrees($0.word) }
        // The files' words decide when the name is vague ("Hockey" is only a synonym, of six
        // subcategories); beside a name that names a category or subcategory they count less.
        let strongName = scores(evidence, lexicon: lexicon).values.contains { $0.score >= 2 }
        let fileWeight = tuning.fileWeight * (strongName ? tuning.fileWeightBesideStrongName : 1)
        evidence += fileWords.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .filter { !pack.contains($0.key) || soundAgrees($0.key) }
            .map { Evidence(word: $0.key, weight: fileWeight * $0.value, fromName: false) }

        let detailed = scores(evidence, lexicon: lexicon)
        // Under 10% of neighbours in one subcategory is noise, not evidence for it.
        let shares = allShares.filter { $0.value >= 0.1 }
        let maxName = detailed.values.map(\.score).max() ?? 0
        var candidates = Set(detailed.keys).union(shares.keys)
        if candidates.isEmpty { return [] }
        // Every subcategory of a category the name points to can be chosen by sound.
        for (catID, _) in detailed { if let e = catalog.entry(catID: catID) {
            for sub in catalog.subcategories(of: e.category) { candidates.insert(sub.catID) }
        } }
        if let locked {
            candidates = Set(catalog.subcategories(of: locked).map(\.catID))
        }
        // UCS's category for production material (ADR, bounces, test tones), not for libraries.
        candidates = candidates.filter { catalog.entry(catID: $0)?.category != "ARCHIVED" }
        var bestInCategory: [String: Double] = [:]
        for (catID, s) in detailed { if let e = catalog.entry(catID: catID) { bestInCategory[e.category] = max(bestInCategory[e.category] ?? 0, s.score) } }
        // Sound counts more when it clearly points one way (83% of neighbours in one
        // subcategory beats a single word of the name: "Quick Whips" are whooshes).
        let soundWeight = 1 + 2.5 * max(0, (shares.values.max() ?? 0) - 0.4)
        var options: [Option] = []
        for catID in candidates {
            guard let e = catalog.entry(catID: catID) else { continue }
            let d = detailed[catID] ?? NameScore()
            let name = maxName > 0 ? d.score / maxName : 0
            // The best name match within this entry's category counts for the category.
            let categoryName = maxName > 0 ? (bestInCategory[e.category] ?? 0) / maxName : 0
            let share = shares[catID] ?? 0
            var score = 0.35 * name + 0.25 * categoryName + soundWeight * (0.25 * share + 0.15 * (categoryShare[e.category] ?? 0))
            if locked != nil { score += 0.5 * (d.score - d.categoryPart) / max(maxName, 1) }
            options.append(Option(entry: e, score: score, words: d.words, fileWords: d.fileWords, soundShare: share))
        }
        // With nothing pointing to one subcategory over the others, MISC (or GENERAL, as RAIN
        // and WIND call it) is the honest choice; otherwise a specific subcategory beats it.
        if let top = options.max(by: { $0.score < $1.score }) {
            // Only evidence of the subcategories at the top counts against MISC.
            let atTop = options.filter { $0.entry.category == top.entry.category && $0.score >= top.score - 1e-9 }
            let specific = atTop.contains { o in
                o.soundShare >= 0.1 || (detailed[o.entry.catID].map { $0.score - $0.categoryPart } ?? 0) > 0   // < 10%: noise
            }
            for i in options.indices where options[i].entry.category == top.entry.category
                && ["MISC", "GENERAL"].contains(options[i].entry.subcategory) {
                options[i].score += specific ? -0.001 : 0.001
            }
        }
        var ranked = options.sorted {
            $0.score != $1.score ? $0.score > $1.score
                : $0.soundShare != $1.soundShare ? $0.soundShare > $1.soundShare : $0.entry.catID < $1.entry.catID
        }
        // Uncertain: an option in another category is named just as well, and the sound doesn't settle it.
        if let top = ranked.first, top.soundShare < 0.3, let topName = detailed[top.entry.catID]?.score, topName > 0 {
            ranked[0].isUncertain = ranked.dropFirst().contains { o in
                o.entry.category != top.entry.category && (detailed[o.entry.catID]?.score ?? 0) >= topName - 1e-9
            }
        }
        // When the first options all share a category, the last place offers the best of another,
        // so the three aren't all variants of one guess.
        if tuning.otherCategoryLast, count >= 3, ranked.count > count, let first = ranked.first,
           ranked.prefix(count).allSatisfy({ $0.entry.category == first.entry.category }),
           let other = ranked.firstIndex(where: { $0.entry.category != first.entry.category }) {
            let alternative = ranked.remove(at: other)
            ranked.insert(alternative, at: count - 1)
        }
        return Array(ranked.prefix(count))
    }
}
