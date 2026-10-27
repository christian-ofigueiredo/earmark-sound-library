import EarmarkCore
import EarmarkML
import Foundation

/// Earmark's guesses for single sounds (`SoundCategories.guesses`): a sound whose folder's guess
/// doesn't fit how it sounds takes the category its nearest sounds in other folders vote for,
/// when that's one of the folder guess's runners-up. In the background, after the folder guesses
/// and as analysis brings in sounds; ~5 s for the library (the vote is one neighbour search).
/// The owner's choices are never touched; "Guessed from the Sound" in the sidebar lists the rest.
@MainActor
final class SoundGuesser {
    private var task: Task<Void, Never>?
    private var again = false
    /// What the last run saw, so an unchanged library isn't voted on again.
    private var lastInputs: String?

    func update(model: AppModel) {
        guard let db = model.database, model.hasLoaded, model.guessProgress == nil else { return }
        if task != nil { again = true; return }
        let inputs = Self.inputs(model)
        guard inputs != lastInputs else { return }
        task = Task {
            let result = await Task.detached(priority: .background) { try? Self.run(db) }.value
            lastInputs = inputs
            task = nil
            if let result { model.setNearDuplicates(result.duplicates) }
            if result?.changed == true { await model.reload() }
            if again {
                again = false
                update(model: model)
            }
        }
    }

    /// The votes change with the folders' categories, the owner's choices and the sounds analysed.
    private static func inputs(_ model: AppModel) -> String {
        let guesses = model.folderGuesses.map(\.createdAt).max()?.timeIntervalSince1970 ?? 0
        let rules = model.folderRules.map(\.createdAt).max()?.timeIntervalSince1970 ?? 0
        let owner = model.soundChoices.values.filter(\.byOwner)
        return "\(SoundCategories.version) \(model.folderGuesses.count) \(guesses) \(model.folderRules.count) \(rules) "
            + "\(owner.count) \(owner.map(\.createdAt).max()?.timeIntervalSince1970 ?? 0) "
            + "\(model.analysis.clapStatus.count) \(model.analysis.peavStatus.count) \(model.sounds.count)"
    }

    /// Votes on every analysed sound and saves Earmark's guesses (`changed`: whether they did).
    /// The same neighbour search finds sounds that are one recording (`Duplicates.nearPairs`).
    nonisolated static func run(_ db: LibraryDatabase) throws -> (changed: Bool, duplicates: [Duplicates.Pair]) {
        // The categories without Earmark's per-sound guesses: they'd otherwise vote for themselves.
        let rules = try db.folderRules(), guesses = try db.folderGuesses()
        let owners = try db.soundCategoryChoices().filter { $0.value.byOwner }
        let sounds = SoundCategories.apply(owners, to: FolderRules.apply(rules, guesses: guesses, to: try db.sounds()))
        let hidden = FormatTwins.group(sounds).hidden
        let byId = Dictionary(uniqueKeysWithValues: sounds.compactMap { s in s.id.map { ($0, s) } })
        let d = GroupBuilder.dimensions
        var rows: [SoundRecord] = []
        var buffer = PageBuffer(count: 0)
        try db.forEachVectors(models: GroupBuilder.models, count: { buffer = PageBuffer(count: $0 * d) }) { id, blocks in
            guard let s = byId[id], !hidden.contains(id), (rows.count + 1) * d <= buffer.count else { return }
            let r = rows.count
            buffer.withFloats { x in for (c, v) in SoundMap.combine(blocks).enumerated() { x[r * d + c] = v } }
            rows.append(s)
        }
        guard rows.count > 1 else { return (try db.replaceSoundGuesses([]), []) }
        let k = min(60, rows.count)
        let (indices, distances) = buffer.withFloats { x in
            SoundMap.nearestNeighbours(UnsafeBufferPointer(rebasing: x[0 ..< rows.count * d]), n: rows.count, d: d, k: k)
        }
        let votes = CategoryVotes.votes(indices: indices, distances: distances, k: k, labels: rows.map(\.catID),
                                        folders: rows.map { "\($0.libraryId)/\($0.folder)" })
        let duplicates = Duplicates.nearPairs(ids: rows.map { $0.id! }, durations: rows.map(\.duration), indices: indices,
                                              distances: distances, k: k)
        // The runners-up of the guess for each sound's folder (or the folder above it that has one).
        let folders = Dictionary(grouping: guesses, by: \.libraryId).mapValues { Set($0.map(\.folder)) }
        let byFolder = Dictionary(guesses.map { ("\($0.libraryId)/\($0.folder)", $0) }, uniquingKeysWith: { a, _ in a })
        let made = SoundCategories.guesses(sounds: rows, votes: votes) { s in
            guard let f = FolderRules.ruleFolder(for: s.folder, in: folders[s.libraryId] ?? []),
                  let g = byFolder["\(s.libraryId)/\(f)"] else { return [] }
            return Set(g.alternativeIDs)
        }
        try db.saveNearDuplicates(duplicates)
        return (try db.replaceSoundGuesses(made), duplicates)
    }
}
