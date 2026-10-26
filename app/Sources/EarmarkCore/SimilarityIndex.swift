import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Nearest neighbours by cosine similarity over L2-normalised embeddings (CLAP now):
/// one contiguous matrix, a dot product against every row per query.
public struct SimilarityIndex: Sendable {
    public let ids: [Int64]
    public let dimensions: Int
    private let matrix: [Float]
    private let row: [Int64: Int]

    public var count: Int { ids.count }

    /// `vectors`: (sound id, normalised vector); vectors of another length are skipped.
    public init(vectors: [(id: Int64, vector: [Float])]) {
        let dims = vectors.first?.vector.count ?? 0
        let kept = vectors.filter { $0.vector.count == dims && dims > 0 }
        ids = kept.map(\.id)
        dimensions = dims
        matrix = kept.flatMap(\.vector)
        row = Dictionary(kept.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    public func contains(_ id: Int64) -> Bool { row[id] != nil }

    /// The `count` most similar sounds to `id` (best first, the sound itself excluded),
    /// skipping `excluding`. Scores are cosine similarities, -1…1.
    public func nearest(to id: Int64, count: Int, excluding: Set<Int64> = []) -> [(id: Int64, score: Float)] {
        guard let q = row[id], count > 0 else { return [] }
        let d = dimensions
        var scores = [Float](repeating: 0, count: ids.count)
        matrix.withUnsafeBufferPointer { m in
            let query = UnsafeBufferPointer(rebasing: m[q * d ..< (q + 1) * d])
            #if canImport(Accelerate)
            // scores (rows × 1) = matrix (rows × d) · query (d × 1); ~20× the plain loop.
            scores.withUnsafeMutableBufferPointer { out in
                vDSP_mmul(m.baseAddress!, 1, query.baseAddress!, 1, out.baseAddress!, 1,
                          vDSP_Length(ids.count), 1, vDSP_Length(d))
            }
            #else
            for r in 0 ..< ids.count {
                var s: Float = 0
                let base = r * d
                for k in 0 ..< d { s += query[k] * m[base + k] }
                scores[r] = s
            }
            #endif
        }
        var best: [(id: Int64, score: Float)] = []
        best.reserveCapacity(count + 1)
        for r in 0 ..< ids.count where r != q {
            let s = scores[r]
            // Most rows can't make the list; check the exclusions only for those that can.
            if best.count == count, s <= best[count - 1].score { continue }
            if excluding.contains(ids[r]) { continue }
            if best.count < count {
                best.append((ids[r], s))
                if best.count == count { best.sort { $0.score > $1.score } }
            } else if s > best[count - 1].score {
                // Insert in order, dropping the last.
                var i = count - 1
                while i > 0, best[i - 1].score < s { i -= 1 }
                best.insert((ids[r], s), at: i)
                best.removeLast()
            }
        }
        if best.count < count { best.sort { $0.score > $1.score } }
        return best
    }
}
