import Foundation
import Testing
@testable import EarmarkCore

/// PE-AV's reflect padding against PeAudioFeatureExtractor (models/parity_peav.py --fixture).
@Suite struct PeavInputTests {
    struct Fixture: Decodable {
        struct Window: Decodable { var length: Int; var padded: Int; var tail: [Float]; var around_end: [Float] }
        var windows: [Window]
    }

    @Test func paddingMatchesPeAudioFeatureExtractor() throws {
        let url = try #require(Bundle.module.url(forResource: "peav_padding", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for w in fixture.windows {
            let x = (0 ..< w.length).map { Float(sin(Double($0) * 0.01) * 0.5) }
            let padded = PeavAudio.input(x)
            #expect(padded.count == w.padded, "length \(w.length)")
            for (a, b) in zip(padded.suffix(8), w.tail) { #expect(abs(a - b) < 1e-6, "tail, length \(w.length)") }
            let around = Array(padded[max(0, w.length - 4) ..< min(padded.count, w.length + 4)])
            for (a, b) in zip(around, w.around_end) { #expect(abs(a - b) < 1e-6, "around the end, length \(w.length)") }
        }
    }
}
