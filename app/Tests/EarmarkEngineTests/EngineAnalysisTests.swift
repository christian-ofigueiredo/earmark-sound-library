import EarmarkCore
import EarmarkEngine
import Foundation
import Testing

/// The map, groups and names through the Rust engine give Swift's, to the bit, on the same
/// page-aligned rows. (On a real library: `earmark-parity engineanalysis <library.sqlite>`.)
struct EngineAnalysisTests {
    /// `n` unit-length rows of `d` in three loose clusters, in a PageBuffer as the app's.
    func rows(_ n: Int, _ d: Int) -> PageBuffer {
        var seed: UInt64 = 7
        func next() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24) - 0.5
        }
        let x = PageBuffer(count: n * d)
        x.withFloats { f in
            for i in 0 ..< n {
                var length: Float = 0
                for c in 0 ..< d {
                    let v = next() + (c % 3 == i % 3 ? 1 : 0)
                    f[i * d + c] = v
                    length += v * v
                }
                for c in 0 ..< d { f[i * d + c] /= length.squareRoot() }
            }
        }
        return x
    }

    @Test(arguments: [0, 1, 2, 12, 60])
    func map(n: Int) {
        let d = 24, x = rows(n, d)
        x.withFloats { f in
            let f = UnsafeBufferPointer(f)
            let swift = SoundMap.map(flat: f, count: n, dimensions: d)!
            let engine = EngineAnalysis.map(flat: f, count: n, dimensions: d)!
            #expect(engine.points == swift.points)
            #expect(engine.links == swift.links)
        }
    }

    @Test(arguments: [1, 8, 25, 60])
    func groupsAndNames(n: Int) {
        let d = 1536, x = rows(n, d)
        let members = (0 ..< n).map { SoundGroups.Member(duration: Double($0 % 5) + 0.5, text: "Door wood slam \($0 % 3) heavy") }
        let mean = [Float](repeating: 0.01, count: d)
        x.withFloats { f in
            let f = UnsafeBufferPointer(f)
            let swift = SoundGroups.cluster(f, count: n, dimensions: d)!
            let engine = EngineAnalysis.cluster(f, count: n, dimensions: d)!
            #expect(engine == swift)
            let k = (swift.max() ?? -1) + 1
            let groups = (0 ..< k).map { g in swift.indices.filter { swift[$0] == g } }
            #expect(EngineAnalysis.names(groups: groups, x: f, dimensions: d, members: members, libraryMean: mean, exclude: ["door"])
                == SoundGroups.names(groups: groups, x: f, dimensions: d, members: members, libraryMean: mean, exclude: ["door"]))
        }
    }

    @Test func cancelled() {
        let d = 24, x = rows(60, d)
        x.withFloats { f in
            #expect(EngineAnalysis.map(flat: UnsafeBufferPointer(f), count: 60, dimensions: d, isCancelled: { true }) == nil)
        }
    }
}

/// Loudness through the Rust engine gives Swift's LoudnessMeter's, chunk for chunk.
/// (On real files: `earmark-parity engineloudness <library.sqlite>`.)
struct EngineLoudnessTests {
    @Test(arguments: [(48_000.0, 1), (44_100.0, 2), (96_000.0, 6)])
    func sameAsSwift(rate: Double, channels: Int) {
        let frames = Int(rate * 3.3)
        let signal = (0 ..< channels).map { c in
            (0 ..< frames).map { i in Float(sin(Double(i) * (0.01 + 0.003 * Double(c))) * (i < frames / 3 ? 0.001 : 0.4)) }
        }
        var swift = LoudnessMeter(sampleRate: rate, channels: channels)
        let engine = EngineLoudnessMeter(sampleRate: rate, channels: channels)
        var start = 0
        for chunk in [1, 4800, 65_536, 999_999] where start < frames {
            let n = min(chunk, frames - start)
            let buffers = signal.map { $0.withUnsafeBufferPointer { Array($0[start ..< start + n]) } }
            buffers.withPointers { pointers in
                swift.process(pointers, frames: n)
                engine.process(pointers, frames: n)
            }
            start += n
        }
        #expect(engine.result == swift.result)
        #expect(swift.result.integrated != nil)
    }

    @Test func silence() {
        var swift = LoudnessMeter(sampleRate: 48_000, channels: 1)
        let engine = EngineLoudnessMeter(sampleRate: 48_000, channels: 1)
        let zeros = [Float](repeating: 0, count: 48_000)
        zeros.withUnsafeBufferPointer { swift.process([$0], frames: 48_000); engine.process([$0], frames: 48_000) }
        #expect(engine.result == swift.result)
        #expect(engine.result.integrated == nil)
    }
}

private extension Array where Element == [Float] {
    /// Each channel's buffer, alive for the length of `body`.
    func withPointers<R>(_ body: ([UnsafeBufferPointer<Float>]) -> R) -> R {
        func go(_ i: Int, _ done: [UnsafeBufferPointer<Float>]) -> R {
            i == count ? body(done) : self[i].withUnsafeBufferPointer { go(i + 1, done + [$0]) }
        }
        return go(0, [])
    }
}
