import EarmarkCore
import Foundation

/// Earmark's category guesses through the Rust engine, with the same results as
/// `CategoryVotes.votes(indices:…)`, `SoundCategories.guesses` and `FolderSuggester`.
public enum EngineCategories {
    /// Each row's top 3 categories by its neighbours' vote (from `EngineDuplicates.nearestNeighbours`).
    public static func votes(indices: [Int], distances: [Float], k: Int, labels: [String?], folders: [String],
                             voters: Int = 15) -> [[CategoryVotes.Vote]] {
        categoryVotes(indices: indices.map(UInt32.init), distances: distances, k: UInt32(k), labels: labels, folders: folders,
                      voters: UInt32(voters))
            .map { $0.map { CategoryVotes.Vote(catID: $0.catId, share: $0.share) } }
    }

    public static func guesses(sounds: [SoundRecord], votes: [[CategoryVotes.Vote]], alternatives: (SoundRecord) -> Set<String>,
                               strong: Double = 0.6, weak: Double = 0.1) -> [SoundCategoryChoice] {
        soundGuesses(sounds: sounds.map(fields), votes: votes.map { $0.map { CategoryVote(catId: $0.catID, share: $0.share) } },
                     alternatives: sounds.map { Array(alternatives($0)) }, strong: strong, weak: weak)
            .map { SoundCategoryChoice(soundId: $0.soundId, fingerprint: $0.fingerprint, catID: $0.catId, byOwner: false,
                                       share: $0.share, replaced: $0.replaced) }
    }

    /// Up to `count` categories for a folder, best first. With Swift's index (the engine turned
    /// off) or none, the engine suggests from the names and files alone, as Swift does without one.
    public static func suggest(folder: String, sounds: [SoundRecord], index: (any SoundNeighbourIndex)?, labels: [Int64: String],
                               sharedDescriptions: Set<String>, count: Int = 3,
                               catalog: UCSCatalog = .shared) -> [FolderSuggester.Option] {
        folderSuggestions(folder: folder, sounds: sounds.map(fields), index: (index as? EngineSimilarityIndex)?.index,
                          labels: labels, sharedDescriptions: Array(sharedDescriptions), count: UInt32(count))
            .compactMap { o in
                catalog.entry(catID: o.catId).map {
                    FolderSuggester.Option(entry: $0, score: o.score, words: o.words, fileWords: o.fileWords,
                                           soundShare: o.soundShare, isUncertain: o.isUncertain)
                }
            }
    }

    public static func labels(_ sounds: [SoundRecord]) -> [Int64: String] {
        folderLabels(sounds: sounds.map(fields))
    }

    public static func sharedDescriptions(_ sounds: [SoundRecord], minFolders: Int = 3) -> Set<String> {
        Set(EarmarkEngine.sharedDescriptions(sounds: sounds.map(fields), minFolders: UInt32(minFolders)))
    }

    static func fields(_ s: SoundRecord) -> SoundFields {
        SoundFields(id: s.id, libraryId: s.libraryId, path: s.path, fileName: s.fileName, folder: s.folder,
                    fingerprint: s.fingerprint, duration: s.duration, fxName: s.fxName, details: s.details, keywords: s.keywords,
                    vendorLibrary: s.vendorLibrary, manufacturer: s.manufacturer, designer: s.designer, catId: s.catID,
                    category: s.category, subcategory: s.subcategory, categorySource: s.categorySource)
    }
}
