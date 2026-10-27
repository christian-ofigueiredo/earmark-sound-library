import Foundation

/// A second opinion on each sound's category from the sounds most like it: its nearest sounds
/// in other folders (PE-AV + CLAP, cosine) vote for their categories, weighted by how alike
/// they are. Sounds in its own folder don't vote, since they usually got their category the
/// same way (one folder guess), so it would only agree with itself.
public enum CategoryVotes {
    public struct Vote: Sendable, Equatable, Codable {
        public var catID: String
        /// Share of the weighted vote, 0…1.
        public var share: Double
        public init(catID: String, share: Double) { self.catID = catID; self.share = share }
    }

    /// Each row's top 3 categories by vote (empty if none of its nearest has one). `x`: `n` unit
    /// rows of `d`; `labels`: each row's category (nil: no vote); `folders`: each row's folder
    /// (library id and path), whose sounds don't vote for each other.
    public static func votes(_ x: UnsafeBufferPointer<Float>, count n: Int, dimensions d: Int, labels: [String?],
                             folders: [String], voters: Int = 15, candidates: Int = 60,
                             isCancelled: () -> Bool = { false }) -> [[Vote]]? {
        guard n > 1 else { return Array(repeating: [], count: n) }
        let k = min(candidates, n)
        guard let (indices, distances) = SoundMap.neighbours(x, n: n, d: d, k: k, progress: { _ in }, isCancelled: isCancelled)
        else { return nil }
        return (0 ..< n).map { i in
            var weights: [String: Double] = [:], counted = 0, total = 0.0
            for c in 0 ..< k where counted < voters {
                let j = indices[i * k + c]
                guard j != i, folders[j] != folders[i], let label = labels[j] else { continue }
                // Similarity, squared: the closest count most.
                let s = max(0, 1 - Double(distances[i * k + c]))
                weights[label, default: 0] += s * s
                total += s * s
                counted += 1
            }
            guard total > 0 else { return [] }
            return weights.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
                .map { Vote(catID: $0.key, share: $0.value / total) }
        }
    }

    /// Whether the vote says the sound is probably in the wrong category: another one has at
    /// least `strong` of the vote and its own has under `weak`.
    public static func disagrees(_ votes: [Vote], with catID: String?, strong: Double = 0.6, weak: Double = 0.1) -> Bool {
        guard let top = votes.first, top.catID != catID, top.share >= strong else { return false }
        let own = votes.first { $0.catID == catID }?.share ?? 0
        return own < weak
    }
}
