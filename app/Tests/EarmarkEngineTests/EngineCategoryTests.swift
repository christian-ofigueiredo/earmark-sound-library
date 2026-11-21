import EarmarkCore
import EarmarkEngine
import Foundation
import Testing

/// Earmark's category guesses through the Rust engine give Swift's.
/// (On a real library: `earmark-parity enginecategories <library.sqlite>`.)
struct EngineCategoryTests {
    let empty = try! JSONDecoder().decode(NormalizedMetadata.self, from: Data(#"{"fields":{},"sources":{}}"#.utf8))

    func sound(_ id: Int64, _ folder: String, _ file: String, catID: String? = nil, source: String? = nil) -> SoundRecord {
        var s = SoundRecord(libraryId: 1, root: URL(fileURLWithPath: "/lib"),
                            scanned: ScannedSound(path: "/lib/\(folder)/\(file)", fileSize: 1, modified: .distantPast,
                                                  fingerprint: "fp\(id)", technical: AudioTechnical(duration: 1), metadata: empty,
                                                  warnings: []))
        s.id = id
        if let catID, let e = UCSCatalog.shared.entry(catID: catID) {
            s.catID = e.catID; s.category = e.category; s.subcategory = e.subcategory; s.categorySource = source
        }
        return s
    }

    @Test func votesAndGuesses() {
        // Five sounds; each one's nearest are the others, closest first.
        let n = 5, k = 5
        let indices: [Int] = (0 ..< n).flatMap { i in [i] + (0 ..< n).filter { $0 != i } }
        let row: [Float] = [0, 0.05, 0.1, 0.2, 0.3]
        let distances: [Float] = (0 ..< n).flatMap { _ in row }
        let labels: [String?] = ["DOORWood", "DOORWood", "DOORMetl", nil, "DOORWood"]
        let folders = ["a", "b", "b", "c", "d"]
        let swift = CategoryVotes.votes(indices: indices, distances: distances, k: k, labels: labels, folders: folders)
        #expect(EngineCategories.votes(indices: indices, distances: distances, k: k, labels: labels, folders: folders) == swift)
        let sounds = (0 ..< n).map { sound(Int64($0 + 1), folders[$0], "\($0).wav", catID: "DOORMetl", source: FolderRules.guessSource) }
        let alternatives: (SoundRecord) -> Set<String> = { _ in ["DOORWood"] }
        func key(_ c: SoundCategoryChoice) -> String { "\(c.soundId) \(c.catID) \(c.share ?? -1) \(c.replaced ?? "-")" }
        let a = SoundCategories.guesses(sounds: sounds, votes: swift, alternatives: alternatives).map(key)
        #expect(EngineCategories.guesses(sounds: sounds, votes: swift, alternatives: alternatives).map(key) == a)
        #expect(!a.isEmpty)
    }

    @Test func folderSuggestions() {
        let sounds = [
            sound(1, "Pack/Footsteps/Gravel", "Footstep gravel 01.wav"), sound(2, "Pack/Footsteps/Gravel", "Footstep gravel 02.wav"),
            sound(3, "Doors Wood", "Door slam.wav", catID: "DOORWood", source: "UCS filename"),
            sound(4, "Whooshes", "Whoosh fast.wav"),
        ]
        #expect(EngineCategories.labels(sounds) == FolderSuggester.labels(sounds))
        #expect(EngineCategories.sharedDescriptions(sounds) == FolderSuggester.sharedDescriptions(sounds))
        for folder in ["Pack/Footsteps/Gravel", "Doors Wood", "Whooshes", "Nothing Here"] {
            let list = sounds.filter { $0.folder == folder }
            let a = FolderSuggester.suggest(folder: folder, sounds: list, index: nil, labels: [:], sharedDescriptions: [])
            let b = EngineCategories.suggest(folder: folder, sounds: list, index: nil, labels: [:], sharedDescriptions: [])
            #expect(b == a, "\(folder)")
        }
    }
}
