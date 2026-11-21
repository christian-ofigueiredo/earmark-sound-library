import EarmarkCore
import EarmarkEngine
import Foundation
import Testing

/// Find Similar, the neighbour search and duplicates through the Rust engine give Swift's.
/// (On a real library: `earmark-parity engineneighbours <library.sqlite>`.)
struct EngineNeighbourTests {
    func unit(_ seed: Int, _ d: Int) -> [Float] {
        var x = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1
        let v = (0 ..< d).map { _ -> Float in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return Float(x >> 40) / Float(1 << 24) - 0.5
        }
        let l = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / l }
    }

    @Test func findSimilar() {
        // Two sounds share a vector: their order is a tie Swift and the engine must break alike.
        var vectors = (0 ..< 300).map { (id: Int64($0 + 1), vector: unit($0, 64)) }
        vectors[10].vector = vectors[20].vector
        vectors.append((id: 999, vector: unit(1, 32)))   // another length: left out by both
        let swift = SimilarityIndex(vectors: vectors), engine = EngineSimilarityIndex(vectors: vectors)
        #expect(engine.count == swift.count)
        #expect(engine.contains(999) == swift.contains(999))
        for id in [Int64(1), 11, 21, 150, 300, 999, 5000] {
            for count in [0, 1, 10, 400] {
                let a = swift.nearest(to: id, count: count, excluding: [2, 3])
                let b = engine.nearest(to: id, count: count, excluding: [2, 3])
                #expect(a.map(\.id) == b.map(\.id) && a.map(\.score) == b.map(\.score), "\(id) \(count)")
            }
        }
    }

    @Test func neighboursAndDuplicates() {
        let n = 80, d = 48, k = 10
        let x = PageBuffer(count: n * d)
        x.withFloats { f in
            for i in 0 ..< n { for (c, v) in unit(i % 70, d).enumerated() { f[i * d + c] = v } }   // 10 repeats
        }
        let (a, b) = x.withFloats { f in
            let f = UnsafeBufferPointer(f)
            return (SoundMap.nearestNeighbours(f, n: n, d: d, k: k), EngineDuplicates.nearestNeighbours(f, n: n, d: d, k: k))
        }
        #expect(a.indices == b.indices)
        #expect(a.distances == b.distances)
        let ids = (0 ..< n).map { Int64($0 + 100) }, durations = (0 ..< n).map { Double($0 % 70) + 1 } as [Double?]
        let near = Duplicates.nearPairs(ids: ids, durations: durations, indices: a.indices, distances: a.distances, k: k)
        #expect(EngineDuplicates.nearPairs(ids: ids, durations: durations, indices: a.indices, distances: a.distances, k: k) == near)
        #expect(near.count == 10)
        let empty = try! JSONDecoder().decode(NormalizedMetadata.self, from: Data(#"{"fields":{},"sources":{}}"#.utf8))
        let sounds = (0 ..< 12).map { i in
            var s = SoundRecord(libraryId: 1, root: URL(fileURLWithPath: "/l"),
                                scanned: ScannedSound(path: "/l/\(i).wav", fileSize: 1, modified: .distantPast,
                                                      fingerprint: i < 10 ? "fp\(i % 3)" : nil, technical: AudioTechnical(),
                                                      metadata: empty, warnings: []))
            s.id = Int64(i + 1)
            return s
        }
        let same = Duplicates.identicalPairs(sounds, hidden: [1])
        let engineSame = EngineDuplicates.identicalPairs(sounds, hidden: [1])
        #expect(Set(engineSame.map { "\($0.a) \($0.b)" }) == Set(same.map { "\($0.a) \($0.b)" }))
        #expect(engineSame.count == same.count)
        let sets = Duplicates.sets(same + near), engineSets = EngineDuplicates.sets(same + near)
        #expect(engineSets == sets)
        #expect(engineSets.others.keys.sorted() == sets.others.keys.sorted())
    }
}
