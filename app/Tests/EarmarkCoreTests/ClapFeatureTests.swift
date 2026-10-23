import Foundation
import Testing
@testable import EarmarkCore

/// Checks the Swift port of Phase 0's audio prep and CLAP's features against
/// values from Python (models/parity_clap.py --fixture).
@Suite struct ClapFeatureTests {
    struct Fixture: Decodable {
        struct Window: Decodable { var length: Int; var first: Float; var rms: Double }
        struct Features: Decodable { var shape: [Int]; var index: [Int]; var values: [Float]; var mean: Double; var std: Double }
        var prepared_length: Int
        var prepared_peak: Float
        var windows: [Window]
        var long: Features
        var short: Features
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "clap_features", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    /// Same formula as parity_clap.fixture_signal().
    static func signal() -> [Float] {
        let sr = Double(ClapAudio.sampleRate)
        var body = (0 ..< 23 * ClapAudio.sampleRate).map { i -> Double in
            let t = Double(i) / sr
            var v = 0.4 * sin(2 * .pi * (200 * t + 40 * t * t)) + 0.2 * sin(2 * .pi * 3000 * t) * exp(-0.1 * t)
            v += 0.5 * exp(-200 * t.truncatingRemainder(dividingBy: 2)) * sin(2 * .pi * 800 * t)
            return v
        }
        for i in 0 ..< 3 * ClapAudio.sampleRate { body[i] *= 0.01 }
        let x = [Double](repeating: 0, count: ClapAudio.sampleRate / 2) + body + [Double](repeating: 0, count: ClapAudio.sampleRate)
        return x.map { Float($0) }
    }

    @Test func prepareAndWindowsMatchPhase0() throws {
        let f = Self.fixture
        let prepared = try #require(ClapAudio.prepare(Self.signal()))
        #expect(prepared.count == f.prepared_length)
        #expect(abs(prepared.map(abs).max()! - f.prepared_peak) < 1e-6)
        let windows = ClapAudio.windows(prepared)
        #expect(windows.count == f.windows.count)
        for (w, ref) in zip(windows, f.windows) {
            #expect(w.count == ref.length)
            #expect(abs(w[0] - ref.first) < 1e-5)
            let rms = (w.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(w.count)).squareRoot()
            #expect(abs(rms - ref.rms) < 1e-5)
        }
    }

    @Test(arguments: ["long", "short"])
    func featuresMatchClapFeatureExtractor(which: String) throws {
        let f = Self.fixture
        let prepared = try #require(ClapAudio.prepare(Self.signal()))
        let input = which == "long" ? ClapAudio.windows(prepared)[0] : Array(prepared.prefix(Int(3.3 * Double(ClapAudio.sampleRate))))
        let ref = which == "long" ? f.long : f.short
        let feats = ClapAudio.features(input)
        #expect(feats.count == ref.shape[0] * ref.shape[1])
        var worst: Float = 0
        for (i, v) in zip(ref.index, ref.values) { worst = max(worst, abs(feats[i] - v)) }
        #expect(worst < 0.01, "largest difference \(worst) dB")
        let mean = feats.reduce(0.0) { $0 + Double($1) } / Double(feats.count)
        #expect(abs(mean - ref.mean) < 0.001)
    }

    @Test func fftMatchesDirectDFT() {
        let n = 16
        let fft = RadixTwoFFT(size: n)
        let x = (0 ..< n).map { sin(Double($0) * 0.7) + 0.3 * cos(Double($0) * 2.1) }
        var re = x, im = [Double](repeating: 0, count: n)
        fft.transform(&re, &im)
        for k in 0 ..< n {
            var r = 0.0, j = 0.0
            for t in 0 ..< n { r += x[t] * cos(-2 * .pi * Double(k * t) / Double(n)); j += x[t] * sin(-2 * .pi * Double(k * t) / Double(n)) }
            #expect(abs(re[k] - r) < 1e-9 && abs(im[k] - j) < 1e-9)
        }
    }
}
