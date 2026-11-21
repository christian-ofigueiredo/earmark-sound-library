import Foundation

/// What the app asks of its library database: Swift's `LibraryDatabase` (GRDB), or the Rust
/// engine's (`EngineLibraryDatabase`, docs/rust-engine-plan.md step 8j). Both read and write the
/// same file in the same way.
public protocol LibraryStore: AnyObject, Sendable {
    // Libraries
    func addLibrary(kind: Library.Kind, path: String, bookmark: Data?) throws -> Library
    func libraries(kind: Library.Kind?) throws -> [Library]
    func removeLibrary(id: Int64) throws

    // Sounds and their analysis
    func replaceSounds(libraryId: Int64, root: URL, scanned: [ScannedSound]) throws
    func sounds(libraryId: Int64?) throws -> [SoundRecord]
    func soundFacts() throws -> [Int64: SoundFacts]
    func save(_ facts: [SoundFacts]) throws
    func embeddingStatus(model: String) throws -> [Int64: SoundEmbedding.Status]
    func vectors(model: String) throws -> [(id: Int64, vector: [Float])]
    func forEachVectors(models: [String], ids: [Int64]?, count: (Int) -> Void,
                        _ body: (_ id: Int64, _ vectors: [[Float]]) -> Void) throws
    func embedding(soundId: Int64, model: String) throws -> SoundEmbedding?
    func save(_ embeddings: [SoundEmbedding]) throws
    func nearDuplicates() throws -> [Duplicates.Pair]
    func saveNearDuplicates(_ pairs: [Duplicates.Pair]) throws

    // Songs
    func replaceSongs(libraryId: Int64, root: URL, files: [SongFile]) throws
    func songs(libraryId: Int64?) throws -> [SongRecord]
    func saveSongAnalysis(_ results: [(songId: Int64, analysis: SongAnalysis)]) throws -> [SongRecord]
    func applySongAnalysis(_ entries: [Phase0MusicImport.Entry]) throws -> Int
    func songCorrections() throws -> [SongCorrection]
    func setSongCorrections(_ changes: [(path: String, correction: SongCorrection?)]) throws

    // Categories
    func soundCategoryChoices() throws -> [Int64: SoundCategoryChoice]
    func setSoundCategory(_ sounds: [(id: Int64, fingerprint: String?)], catID: String?) throws
    func replaceSoundGuesses(_ guesses: [SoundCategoryChoice]) throws -> Bool
    func folderRules() throws -> [FolderRule]
    func save(_ rules: [FolderRule]) throws
    func removeFolderRule(libraryId: Int64, folder: String) throws
    func folderGuesses() throws -> [FolderGuess]
    func updateGuesses(saving guesses: [FolderGuess], removing stale: [(libraryId: Int64, folder: String)]) throws

    // Similarity groups
    func soundGroupSnapshot() throws -> SoundGroupSnapshot
    func replaceGroups(catID: String, groups: [[(id: Int64, fingerprint: String?)]], names: [SoundGroups.Name]) throws
    func updateGroups(catID: String, add: [(id: Int64, fingerprint: String?, group: Int64)], remove: [Int64]) throws
    func dropGroups(catID: String) throws
    func renameGroup(_ id: Int64, to name: String?) throws
    func moveSounds(_ sounds: [(id: Int64, fingerprint: String?)], toGroup id: Int64) throws
    func newGroup(catID: String, name: String, sounds: [(id: Int64, fingerprint: String?)]) throws -> Int64
    func mergeGroups(_ groups: [Int64], into target: Int64) throws
    func regroup(catID: String) throws

    // Analysis files. The engine reads fingerprints itself, the same way as `Fingerprint.of`.
    func analysisFile(for library: Library, includeEmbeddings: Bool, exportedAt: Date,
                      fingerprint: (URL) -> String?) throws -> AnalysisFile
    func writeAnalysisFile(for library: Library, includeEmbeddings: Bool, to url: URL, exportedAt: Date,
                           fingerprint: (URL) -> String?) throws -> Int
    func importAnalysis(_ file: AnalysisFile, fingerprint: (URL) -> String?) throws -> AnalysisImportReport
}

/// The defaults the app's calls leave out.
extension LibraryStore {
    public func libraries() throws -> [Library] { try libraries(kind: nil) }
    public func sounds() throws -> [SoundRecord] { try sounds(libraryId: nil) }
    public func songs() throws -> [SongRecord] { try songs(libraryId: nil) }
    public func forEachVectors(models: [String], ids: [Int64]? = nil, count: (Int) -> Void = { _ in },
                               _ body: (_ id: Int64, _ vectors: [[Float]]) -> Void) throws {
        try forEachVectors(models: models, ids: ids, count: count, body)
    }
    public func analysisFile(for library: Library, includeEmbeddings: Bool, exportedAt: Date = Date()) throws -> AnalysisFile {
        try analysisFile(for: library, includeEmbeddings: includeEmbeddings, exportedAt: exportedAt, fingerprint: Fingerprint.of)
    }
    public func writeAnalysisFile(for library: Library, includeEmbeddings: Bool, to url: URL,
                                  exportedAt: Date = Date()) throws -> Int {
        try writeAnalysisFile(for: library, includeEmbeddings: includeEmbeddings, to: url, exportedAt: exportedAt,
                              fingerprint: Fingerprint.of)
    }
    public func importAnalysis(_ file: AnalysisFile) throws -> AnalysisImportReport {
        try importAnalysis(file, fingerprint: Fingerprint.of)
    }
}

extension LibraryDatabase: LibraryStore {}
