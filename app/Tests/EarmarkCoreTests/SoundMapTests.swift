import Foundation
import Testing
@testable import EarmarkCore

/// The sound map's UMAP layout (SoundMap).
@Suite struct SoundMapTests {
    /// `clusters` groups of unit vectors around random centres in `dims` dimensions.
    static func clustered(clusters: Int, each: Int, dims: Int = 32, spread: Float = 0.25) -> (vectors: [[Float]], labels: [Int]) {
        var rng = SoundMap.SplitMix(seed: 7)
        func unit(_ v: [Float]) -> [Float] { let l = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); return v.map { $0 / l } }
        let centres = (0 ..< clusters).map { _ in unit((0 ..< dims).map { _ in rng.normal(1) }) }
        var vectors: [[Float]] = [], labels: [Int] = []
        for (c, centre) in centres.enumerated() {
            for _ in 0 ..< each {
                vectors.append(unit(centre.map { $0 + rng.normal(spread / Float(dims).squareRoot()) }))
                labels.append(c)
            }
        }
        return (vectors, labels)
    }

    @Test func soundsThatAreAlikeStayTogether() throws {
        let (vectors, labels) = Self.clustered(clusters: 4, each: 60)
        let map = try #require(SoundMap.layout(vectors))
        #expect(map.count == vectors.count)
        #expect(map.allSatisfy { (0 ... 1).contains($0.x) && (0 ... 1).contains($0.y) })
        // Each point's nearest on the map is from its own cluster.
        var same = 0
        for i in map.indices {
            let j = map.indices.filter { $0 != i }.min { SoundMap.distance2(map[i], map[$0]) < SoundMap.distance2(map[i], map[$1]) }!
            if labels[j] == labels[i] { same += 1 }
        }
        #expect(Double(same) / Double(map.count) > 0.97, "\(same) of \(map.count)")
        // Inside a cluster it's noise, so no 2-D map keeps many exact neighbours: umap-learn kept
        // 0.45–0.46 of 15 on data like this (3 seeds), this port 0.44.
        #expect(SoundMap.neighboursKept(vectors, layout: map) > 0.4)
    }

    @Test func linksJoinNeighbours() throws {
        let (vectors, labels) = Self.clustered(clusters: 4, each: 60)
        let flat = vectors.flatMap { $0 }
        let map = try #require(flat.withUnsafeBufferPointer { SoundMap.map(flat: $0, count: vectors.count, dimensions: 32) })
        #expect(map.points == SoundMap.layout(vectors))
        // Each sound's 3 nearest, each pair once: between 3n/2 and 3n.
        #expect(map.links.count >= vectors.count * 3 / 2 && map.links.count <= vectors.count * 3)
        #expect(map.links.allSatisfy { $0.x < $0.y })
        #expect(Set(map.links.map { [$0.x, $0.y] }).count == map.links.count)
        #expect(map.links == map.links.sorted { ($0.x, $0.y) < ($1.x, $1.y) })
        let sameCluster = map.links.filter { labels[Int($0.x)] == labels[Int($0.y)] }.count
        #expect(Double(sameCluster) / Double(map.links.count) > 0.97)
    }

    @Test func theSameSoundsGiveTheSameMap() throws {
        let (vectors, _) = Self.clustered(clusters: 3, each: 30)
        let a = try #require(SoundMap.layout(vectors)), b = try #require(SoundMap.layout(vectors))
        #expect(a == b)
    }

    @Test func fewSounds() throws {
        #expect(SoundMap.layout([])?.isEmpty == true)
        #expect(SoundMap.layout([[1, 0]]) == [SIMD2(0.5, 0.5)])
        #expect(SoundMap.layout([[1, 0], [0, 1]])?.count == 2)
        let five = try #require(SoundMap.layout(Self.clustered(clusters: 1, each: 5).vectors))   // PCA only
        #expect(five.count == 5 && five.allSatisfy { (0 ... 1).contains($0.x) && (0 ... 1).contains($0.y) })
    }

    @Test func modelsCombineWithEqualWeight() {
        let v = SoundMap.combine([[3, 4], [0, 0, 2]])
        #expect(v.count == 5)
        #expect(abs(v.reduce(0) { $0 + $1 * $1 } - 1) < 1e-6)
        #expect(abs(v[0] - 0.6 / Float(2).squareRoot()) < 1e-6 && abs(v[4] - 1 / Float(2).squareRoot()) < 1e-6)
    }

    @Test func cancelling() {
        let (vectors, _) = Self.clustered(clusters: 2, each: 40)
        #expect(SoundMap.layout(vectors, isCancelled: { true }) == nil)
    }
}
