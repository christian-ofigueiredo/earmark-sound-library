import Foundation
import Testing
@testable import EarmarkCore

/// Similarity groups: HDBSCAN against scikit-learn, the grouping pipeline and the names.
@Suite struct SoundGroupTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var dimensions: Int
            var minClusterSize: Int
            var minSamples: Int
            var points: [Double]
            var labels: [Int]
        }
        var cases: [Case]
    }

    /// Synthetic blobs and noise, labelled by sklearn 1.9 (`models/export_groups.py`).
    @Test func hdbscanMatchesScikitLearn() throws {
        let url = try #require(Bundle.module.url(forResource: "hdbscan", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for c in fixture.cases {
            let n = c.labels.count
            let labels = HDBSCAN.labels(c.points.map(Float.init), count: n, dimensions: c.dimensions,
                                        minClusterSize: c.minClusterSize, minSamples: c.minSamples)
            #expect(labels == c.labels, "\(zip(labels, c.labels).filter { $0 != $1 }.count) of \(n) differ")
        }
    }

    struct WardFixture: Decodable {
        struct Case: Decodable { var dimensions: Int; var groups: Int; var points: [Double]; var labels: [Int] }
        var cases: [Case]
    }

    /// The same groups as sklearn's AgglomerativeClustering(linkage="ward") (numbered by size here).
    @Test func wardMatchesScikitLearn() throws {
        let url = try #require(Bundle.module.url(forResource: "ward", withExtension: "json", subdirectory: "Fixtures"))
        for c in try JSONDecoder().decode(WardFixture.self, from: Data(contentsOf: url)).cases {
            let n = c.labels.count
            let labels = SoundGroups.ward(c.points.map(Float.init), count: n, dimensions: c.dimensions, groups: c.groups)
            func partition(_ l: [Int]) -> Set<Set<Int>> { Set(Dictionary(grouping: 0 ..< n) { l[$0] }.values.map(Set.init)) }
            #expect(partition(labels) == partition(c.labels))
            // Largest group first.
            let sizes = (0 ..< c.groups).map { g in labels.filter { $0 == g }.count }
            #expect(sizes == sizes.sorted(by: >))
        }
    }

    @Test func wardJoinsTinyGroups() {
        // Two clumps of 10 and one far point: asked for 3 groups, the lone point joins a clump.
        var points: [Float] = []
        for i in 0 ..< 10 { points += [Float(i) * 0.01, 0] }
        for i in 0 ..< 10 { points += [5 + Float(i) * 0.01, 0] }
        points += [20, 0]
        let labels = SoundGroups.ward(points, count: 21, dimensions: 2, groups: 3)
        #expect(Set(labels).count == 2)
        #expect(labels[20] == labels[10])
    }

    @Test func groupCountGrowsWithTheSet() {
        #expect(SoundGroups.groupCount(10) == 1)
        #expect(SoundGroups.groupCount(30) == 2)
        #expect(SoundGroups.groupCount(440) == 7)
        #expect(SoundGroups.groupCount(6586) == 12)
    }

    @Test func hdbscanOnTooFewPoints() {
        #expect(HDBSCAN.labels([0, 0, 1, 1], count: 2, dimensions: 2, minClusterSize: 5, minSamples: 2) == [-1, -1])
        #expect(HDBSCAN.labels([], count: 0, dimensions: 2, minClusterSize: 5, minSamples: 2) == [])
    }

    @Test func groupsFindTheClusters() throws {
        // 4 × 32 sounds: 4 groups (√(128/8)).
        let (vectors, truth) = SoundMapTests.clustered(clusters: 4, each: 32, dims: 48, spread: 0.3)
        let labels = try #require(SoundGroups.cluster(vectors.flatMap { $0 }, count: vectors.count, dimensions: 48))
        #expect(labels.count == truth.count)
        // Each true cluster is one group.
        let grouped = Array(zip(labels, truth))
        for g in Set(labels) {
            #expect(Set(grouped.filter { $0.0 == g }.map(\.1)).count == 1, "group \(g) mixes clusters")
        }
        #expect(Set(labels).count == 4)
        // The same sounds, the same groups.
        #expect(SoundGroups.cluster(vectors.flatMap { $0 }, count: vectors.count, dimensions: 48) == labels)
    }

    @Test func smallSetsAreOneGroupOrSplitByPCA() throws {
        let (few, _) = SoundMapTests.clustered(clusters: 2, each: 4, dims: 16)
        #expect(SoundGroups.cluster(few.flatMap { $0 }, count: few.count, dimensions: 16) == Array(repeating: 0, count: 8))
        let (some, truth) = SoundMapTests.clustered(clusters: 2, each: 12, dims: 16, spread: 0.2)
        let labels = try #require(SoundGroups.cluster(some.flatMap { $0 }, count: some.count, dimensions: 16))
        #expect(labels.count == 24)
        #expect(Set(labels).count == 2)
        for g in Set(labels) {
            #expect(Set(zip(labels, truth).filter { $0.0 == g }.map(\.1)).count == 1)
        }
    }

    @Test func wordVectorsLoad() throws {
        let v = try #require(SoundGroups.wordVectors)
        #expect(v.count == SoundGroups.words.count * 1536)
        // Each word's combined vector has unit length, as the sounds'.
        let first = v[0 ..< 1536].reduce(0) { $0 + $1 * $1 }
        #expect(abs(first - 1) < 1e-4)
    }

    @Test func namesUseLengthAIWordsAndStayUnique() throws {
        let words = try #require(SoundGroups.wordVectors)
        let d = 1536
        // Two groups of sounds sitting on two words' vectors: "metallic" short, "watery" long.
        func row(_ word: String) -> [Float] {
            let j = SoundGroups.words.firstIndex(of: word)!
            return Array(words[j * d ..< (j + 1) * d])
        }
        let x = Array(repeating: row("metallic"), count: 6).flatMap { $0 } + Array(repeating: row("watery"), count: 6).flatMap { $0 }
        let members = (0 ..< 12).map { i in
            SoundGroups.Member(duration: i < 6 ? 0.4 : 9, text: i < 6 ? "Clang_Pipe_Hit \(i)" : "Stream water flow \(i)")
        }
        let names = SoundGroups.names(groups: [Array(0 ..< 6), Array(6 ..< 12)], x: x, dimensions: d, members: members,
                                      libraryMean: [], exclude: [])
        #expect(names.count == 2)
        #expect(names[0].shapeWords == ["short"] && names[1].shapeWords == ["long"])
        #expect(names[0].aiWords.first == "metallic", "\(names[0].aiWords)")
        #expect(names[1].aiWords.first == "watery", "\(names[1].aiWords)")
        #expect(names[0].name.hasPrefix("Short · Metallic"), "\(names[0].name)")
        #expect(names[0].keywords.contains("clang") && names[1].keywords.contains("stream"))
        // The same sounds twice: the second name differs.
        let twice = SoundGroups.names(groups: [Array(0 ..< 6), Array(0 ..< 6)], x: x, dimensions: d, members: members,
                                      libraryMean: [], exclude: [])
        #expect(twice[0].name != twice[1].name, "\(twice.map(\.name))")
    }

    @Test func tokensAsPhase0() {
        #expect(SoundGroups.tokens("Whoosh_Fast-Pass 03 the SFX a1bc") == ["whoosh", "fast-pass"])
    }
}
