import Foundation
import Testing
@testable import EarmarkCore

/// Categories for single sounds: the vote of their nearest, Earmark's guesses and the owner's choices.
@Suite struct SoundCategoryTests {
    static func sound(_ id: Int64, _ catID: String?, source: String?, folder: String = "Pack/Misc") -> SoundRecord {
        let e = catID.flatMap { UCSCatalog.shared.entry(catID: $0) }
        var s = SoundRecord(libraryId: 1, root: URL(fileURLWithPath: "/L"), scanned: ScannedSound(
            path: "/L/\(folder)/s\(id).wav", fileSize: 10, modified: Date(), fingerprint: "f\(id)",
            technical: AudioTechnical(), metadata: NormalizedMetadata(), warnings: []))
        s.id = id
        s.catID = e?.catID; s.category = e?.category; s.subcategory = e?.subcategory; s.categorySource = source
        return s
    }

    @Test func nearestSoundsInOtherFoldersVote() throws {
        // Row 0's nearest: rows 1 (same folder, doesn't vote), 2 and 3 (DOORWood), 4 (GUNAuto), farther.
        let x: [Float] = [1, 0, 0.99, 0.14, 0.98, 0.2, 0.97, 0.24, 0.6, 0.8]
        let unit = stride(from: 0, to: x.count, by: 2).flatMap { i -> [Float] in
            let l = (x[i] * x[i] + x[i + 1] * x[i + 1]).squareRoot(); return [x[i] / l, x[i + 1] / l]
        }
        let votes = try #require(unit.withUnsafeBufferPointer {
            CategoryVotes.votes($0, count: 5, dimensions: 2, labels: ["FEETHmn", "FEETHmn", "DOORWood", "DOORWood", "GUNAuto"],
                                folders: ["a", "a", "b", "c", "d"], voters: 3, candidates: 5)
        })
        #expect(votes[0].first?.catID == "DOORWood")
        #expect(!votes[0].contains { $0.catID == "FEETHmn" })
        #expect(abs(votes[0].reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(CategoryVotes.disagrees(votes[0], with: "FEETHmn"))
        #expect(!CategoryVotes.disagrees(votes[0], with: "DOORWood"))
    }

    @Test func earmarkGuessesOnlyAmongTheFoldersRunnersUp() {
        let sounds = [Self.sound(1, "FEETHmn", source: FolderRules.guessSource), Self.sound(2, "FEETHmn", source: FolderRules.guessSource),
                      Self.sound(3, "FEETHmn", source: "UCS filename")]
        let vote = [CategoryVotes.Vote(catID: "DOORWood", share: 0.8), .init(catID: "FEETHmn", share: 0.05)]
        let guesses = SoundCategories.guesses(sounds: sounds, votes: [vote, [.init(catID: "GUNAuto", share: 0.9)], vote]) { _ in
            ["DOORWood", "FEETCrea"]
        }
        // Sound 2's vote isn't among the runners-up; sound 3's category is its file's own.
        #expect(guesses.map(\.soundId) == [1])
        #expect(guesses.first?.catID == "DOORWood" && guesses.first?.replaced == "FEETHmn" && guesses.first?.byOwner == false)
    }

    @Test func ownersChoicesWinEarmarksReplaceOnlyFolderGuesses() throws {
        let db = try LibraryDatabase(path: nil)
        let sounds = [Self.sound(1, "FEETHmn", source: FolderRules.guessSource), Self.sound(2, "FEETHmn", source: "UCS filename"),
                      Self.sound(3, "FEETHmn", source: FolderRules.guessSource)]
        try db.replaceSoundGuesses([SoundCategoryChoice(soundId: 1, fingerprint: "f1", catID: "DOORWood", byOwner: false),
                                    SoundCategoryChoice(soundId: 2, fingerprint: "f2", catID: "DOORWood", byOwner: false)])
        try db.setSoundCategory([(3, "f3"), (2, "f2")], catID: "GUNAuto")
        var applied = SoundCategories.apply(try db.soundCategoryChoices(), to: sounds)
        #expect(applied.map(\.catID) == ["DOORWood", "GUNAuto", "GUNAuto"])
        #expect(applied.map(\.categorySource) == [SoundCategories.soundGuessSource, SoundCategories.ownerSource, SoundCategories.ownerSource])
        // New guesses leave the owner's alone, and say whether anything changed.
        #expect(try db.replaceSoundGuesses([SoundCategoryChoice(soundId: 1, fingerprint: "f1", catID: "DOORWood", byOwner: false),
                                            SoundCategoryChoice(soundId: 3, fingerprint: "f3", catID: "DOORWood", byOwner: false)]) == false)
        #expect(try db.soundCategoryChoices()[3]?.byOwner == true)
        // The owner takes theirs back; a changed file loses Earmark's.
        try db.setSoundCategory([(2, "f2")], catID: nil)
        var changed = sounds
        changed[0].fingerprint = "new"
        applied = SoundCategories.apply(try db.soundCategoryChoices(), to: changed)
        #expect(applied.map(\.catID) == ["FEETHmn", "FEETHmn", "GUNAuto"])
    }
}
