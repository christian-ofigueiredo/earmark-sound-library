import Foundation
import Testing
@testable import EarmarkCore

/// Duplicates: byte-identical copies and the same recording found by its audio.
@Suite struct DuplicateTests {
    static func sound(_ id: Int64, fingerprint: String, duration: Double = 1) -> SoundRecord {
        var s = SoundRecord(libraryId: 1, root: URL(fileURLWithPath: "/L"), scanned: ScannedSound(
            path: "/L/Pack/s\(id).wav", fileSize: 10, modified: Date(), fingerprint: fingerprint,
            technical: AudioTechnical(), metadata: NormalizedMetadata(), warnings: []))
        s.id = id
        s.duration = duration
        return s
    }

    @Test func identicalCopiesShareAFingerprint() {
        let sounds = [Self.sound(1, fingerprint: "a"), Self.sound(2, fingerprint: "a"), Self.sound(3, fingerprint: "b"),
                      Self.sound(4, fingerprint: "a")]
        let pairs = Duplicates.identicalPairs(sounds, hidden: [4])
        #expect(pairs == [Duplicates.Pair(a: 1, b: 2, identical: true, similarity: 1)])
    }

    @Test func theSameRecordingNeedsTheSameLength() {
        // Rows 0–2: 0 and 1 alike at 0.999 (same length), 0 and 2 at 0.9995 (other length).
        let ids: [Int64] = [10, 11, 12]
        let indices = [0, 2, 1, 1, 0, 2, 2, 0, 1]
        let distances: [Float] = [0, 0.0005, 0.001, 0, 0.001, 0.2, 0, 0.0005, 0.2]
        let pairs = Duplicates.nearPairs(ids: ids, durations: [1.0, 1.005, 3.0], indices: indices, distances: distances, k: 3)
        #expect(pairs.count == 1 && pairs[0].a == 10 && pairs[0].b == 11 && !pairs[0].identical)
        #expect(Duplicates.sameLength(0.30, 0.315) && !Duplicates.sameLength(10, 10.5))
    }

    @Test func pairsJoinIntoSets() {
        let sets = Duplicates.sets([Duplicates.Pair(a: 1, b: 2, identical: true, similarity: 1),
                                    Duplicates.Pair(a: 2, b: 3, identical: false, similarity: 0.999),
                                    Duplicates.Pair(a: 2, b: 1, identical: false, similarity: 1),
                                    Duplicates.Pair(a: 7, b: 8, identical: false, similarity: 0.9985)])
        #expect(sets.members == [[1, 2, 3], [7, 8]])
        #expect(sets.setOf[3] == 0 && sets.setOf[8] == 1)
        // 1 and 2 are identical (kept over the audio's finding); 2 lists both.
        #expect(sets.others[1]?.map(\.id) == [2] && sets.others[1]?.first?.identical == true)
        #expect(sets.others[2]?.map(\.id) == [1, 3])
    }
}
