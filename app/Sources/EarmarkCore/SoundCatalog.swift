import Foundation

/// The sound libraries as Earmark shows them, read in one go: each sound with its category by
/// Earmark's rules (`FolderRules`, `SoundCategories`), format twins hidden, similarity groups and
/// duplicates. What the MCP server answers from; the app builds the same from the same rules.
public struct SoundCatalog: Sendable {
    public let libraries: [Library]
    /// Every sound, categories applied, hidden twins too (`isShown`).
    public let sounds: [SoundRecord]
    public let songCount: Int
    public let twins: FormatTwins.Groups
    public let folderGuesses: [FolderGuess]
    public let soundChoices: [Int64: SoundCategoryChoice]
    public let groups: SoundGroupSnapshot
    public let duplicates: Duplicates.Sets
    public let facts: [Int64: SoundFacts]
    /// Sounds with both models' embeddings (on the map, in groups, in duplicates by sound).
    public let analysed: Set<Int64>
    let position: [Int64: Int]
    let haystacks: [String]

    public init(_ db: LibraryDatabase) throws {
        libraries = try db.libraries()
        let rules = try db.folderRules()
        folderGuesses = try db.folderGuesses()
        soundChoices = try db.soundCategoryChoices()
        sounds = SoundCategories.apply(soundChoices, to: FolderRules.apply(rules, guesses: folderGuesses, to: try db.sounds()))
        songCount = try db.songs().count
        twins = FormatTwins.group(sounds)
        groups = try db.soundGroupSnapshot()
        duplicates = Duplicates.sets(Duplicates.identicalPairs(sounds, hidden: twins.hidden) + (try db.nearDuplicates()))
        facts = try db.soundFacts()
        var byId: [Int64: Int] = [:]
        for (i, s) in sounds.enumerated() { if let id = s.id { byId[id] = i } }
        position = byId
        haystacks = sounds.map(\.searchText)
        let clap = try db.embeddingStatus(model: "clap-general"), peav = try db.embeddingStatus(model: "pe-av-large")
        analysed = Set(sounds.compactMap { s in
            guard let id = s.id, SoundEmbedding.isCurrent(clap[id], model: "clap-general", for: s),
                  SoundEmbedding.isCurrent(peav[id], model: "pe-av-large", for: s) else { return nil }
            return id
        })
    }

    public func sound(_ id: Int64) -> SoundRecord? { position[id].map { sounds[$0] } }

    /// Listed (not a hidden format twin).
    public func isShown(_ s: SoundRecord) -> Bool { s.id.map { !twins.hidden.contains($0) } ?? false }

    /// The sound's similarity group, if its file is the one grouped.
    public func group(of s: SoundRecord) -> SoundGroupRecord? {
        guard let id = s.id, let g = groups.membership[id], groups.memberFingerprints[id] == .some(s.fingerprint) else { return nil }
        return groups.byId[g]
    }

    public func library(_ id: Int64) -> Library? { libraries.first { $0.id == id } }

    /// Where a sound's category came from, in words agents and people read.
    public static func sourceText(_ s: SoundRecord) -> String {
        switch s.categorySource {
        case nil: s.catID == nil ? "none yet" : "its file"
        case FolderRules.source: "the owner's choice for its folder"
        case FolderRules.guessSource: "Earmark's guess for its folder"
        case SoundCategories.soundGuessSource: "Earmark's guess from how it sounds"
        case SoundCategories.ownerSource: "the owner's choice for this sound"
        case let other?: "its file (\(other))"
        }
    }

    public struct Filter: Sendable {
        /// Words the sound's name, description, keywords, category, library or folder all contain.
        public var query: String?
        /// A category ("FOOTSTEPS"), a subcategory ("Footsteps / Human") or a CatID ("FEETHmn").
        public var category: String?
        public var groupId: Int64?
        public var libraryId: Int64?
        public var minLength: Double?
        public var maxLength: Double?
        /// "file", "folder", "guess" (Earmark's, from the folder or the sound), "owner", "none".
        public var source: String?
        public init(query: String? = nil, category: String? = nil, groupId: Int64? = nil, libraryId: Int64? = nil,
                    minLength: Double? = nil, maxLength: Double? = nil, source: String? = nil) {
            self.query = query; self.category = category; self.groupId = groupId; self.libraryId = libraryId
            self.minLength = minLength; self.maxLength = maxLength; self.source = source
        }
    }

    /// Listed sounds matching the filter: with a query, those with the words in their name first.
    public func search(_ f: Filter) -> [SoundRecord] {
        let terms = (f.query ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let category = f.category?.trimmingCharacters(in: .whitespaces).lowercased()
        var found: [(s: SoundRecord, inName: Int)] = []
        for (i, s) in sounds.enumerated() {
            guard isShown(s), terms.allSatisfy({ haystacks[i].contains($0) }) else { continue }
            if let category, !category.isEmpty {
                let labels = [s.catID, s.category, s.ucsLabel].compactMap { $0?.lowercased() }
                guard labels.contains(category) else { continue }
            }
            if let g = f.groupId, group(of: s)?.id != g { continue }
            if let l = f.libraryId, s.libraryId != l { continue }
            if let lo = f.minLength, (s.duration ?? 0) < lo { continue }
            if let hi = f.maxLength, (s.duration ?? .infinity) > hi { continue }
            if let source = f.source, !Self.matches(s, source: source) { continue }
            let name = s.displayName.lowercased()
            found.append((s, terms.filter { name.contains($0) }.count))
        }
        found.sort { $0.inName != $1.inName ? $0.inName > $1.inName
            : $0.s.displayName.localizedStandardCompare($1.s.displayName) == .orderedAscending }
        return found.map(\.s)
    }

    static func matches(_ s: SoundRecord, source: String) -> Bool {
        switch source.lowercased() {
        case "file": s.catID != nil && s.categorySource != FolderRules.source && s.categorySource != FolderRules.guessSource
            && s.categorySource != SoundCategories.soundGuessSource && s.categorySource != SoundCategories.ownerSource
        case "folder": s.categorySource == FolderRules.source
        case "guess": s.categorySource == FolderRules.guessSource || s.categorySource == SoundCategories.soundGuessSource
        case "owner": s.categorySource == SoundCategories.ownerSource || s.categorySource == FolderRules.source
        case "none": s.catID == nil
        default: true
        }
    }
}
