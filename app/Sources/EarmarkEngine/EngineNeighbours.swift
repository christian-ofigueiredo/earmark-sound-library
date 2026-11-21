import EarmarkCore
import Foundation

/// Find Similar's index through the Rust engine: the same answers as Swift's `SimilarityIndex`.
public final class EngineSimilarityIndex: SoundNeighbourIndex, @unchecked Sendable {
    let index: SoundIndex

    /// `vectors`: (sound id, normalised vector); vectors of another length are skipped, as there.
    public init(vectors: [(id: Int64, vector: [Float])]) {
        let d = vectors.first?.vector.count ?? 0
        let kept = vectors.filter { $0.vector.count == d && d > 0 }
        index = SoundIndex(ids: kept.map(\.id), flat: kept.flatMap(\.vector), dimensions: UInt32(d))
    }

    public var count: Int { Int(index.count()) }

    public func contains(_ id: Int64) -> Bool { index.contains(id: id) }

    public func nearest(to id: Int64, count: Int, excluding: Set<Int64> = []) -> [(id: Int64, score: Float)] {
        guard count > 0 else { return [] }
        return index.nearest(id: id, count: UInt32(count), excluding: Array(excluding)).map { ($0.id, $0.score) }
    }
}

/// Duplicates and the neighbour search behind Earmark's guesses through the Rust engine, with
/// the same results as `Duplicates` and `SoundMap.nearestNeighbours`.
public enum EngineDuplicates {
    /// Each row's `k` nearest (itself included), flat, with cosine distances. The rows are read
    /// where they are, as in `EngineAnalysis`.
    public static func nearestNeighbours(_ x: UnsafeBufferPointer<Float>, n: Int, d: Int, k: Int) -> (indices: [Int], distances: [Float]) {
        let found = nearestRows(address: UInt64(UInt(bitPattern: x.baseAddress)), count: UInt32(n), dimensions: UInt32(d), k: UInt32(k))
        return (found.indices.map(Int.init), found.distances)
    }

    public static func identicalPairs(_ sounds: [SoundRecord], hidden: Set<Int64>) -> [Duplicates.Pair] {
        EarmarkEngine.identicalPairs(sounds: sounds.compactMap { s in s.id.map { SoundPrint(id: $0, fingerprint: s.fingerprint) } },
                                     hidden: Array(hidden)).map(pair)
    }

    public static func nearPairs(ids: [Int64], durations: [Double?], indices: [Int], distances: [Float], k: Int) -> [Duplicates.Pair] {
        nearDuplicatePairs(ids: ids, durations: durations, indices: indices.map(UInt32.init), distances: distances, k: UInt32(k))
            .map(pair)
    }

    public static func sets(_ pairs: [Duplicates.Pair]) -> Duplicates.Sets {
        let made = duplicateSets(pairs: pairs.map {
            DuplicatePair(a: $0.a, b: $0.b, identical: $0.identical, similarity: $0.similarity)
        })
        var sets = Duplicates.Sets()
        sets.setOf = made.setOf.mapValues(Int.init)
        sets.members = made.members
        sets.others = made.others.mapValues { $0.map { ($0.id, $0.identical, $0.similarity) } }
        return sets
    }

    private static func pair(_ p: DuplicatePair) -> Duplicates.Pair {
        Duplicates.Pair(a: p.a, b: p.b, identical: p.identical, similarity: p.similarity)
    }
}
