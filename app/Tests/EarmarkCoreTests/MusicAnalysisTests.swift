import Foundation
import Testing
@testable import EarmarkCore

/// Checks the Swift port of Beat This!'s input, chunking and peak picking, and of Phase 0's
/// tempo summary, against Python (models/parity_music.py --fixture). The beat logits in the
/// fixture come from the PyTorch model on two generated drum loops.
@Suite struct MusicAnalysisTests {
    struct Fixture: Decodable {
        struct Spectrogram: Decodable { var shape: [Int]; var index: [Int]; var values: [Float]; var mean: Double }
        struct Aggregate: Decodable { var frames: Int; var beat: [Float] }
        struct Song: Decodable {
            var name: String
            var beat_logits: [Float], downbeat_logits: [Float]
            var peaks: [Double], downbeats: [Double], refined: [Double]
            var bpm: Double?, bpm_range: [Double]?, stability: String, beats_per_bar: Int?, confidence: Double
        }
        var spectrogram: Spectrogram
        var chunk_starts: [String: [Int]]
        var aggregate: Aggregate
        struct HalfRate: Decodable { var taps: [Float]; var index: [Int]; var values: [Float]; var length: Int }
        var songs: [Song]
        var key_labels: [String]
        var half_rate: HalfRate
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "music_analysis", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    /// Same formula as parity_music.drums().
    static func drums(seconds: Double, bpm0: Double, bpm1: Double, perBar: Double) -> [Float] {
        let sr = Double(BeatThisAudio.sampleRate)
        return (0 ..< Int(seconds * sr)).map { i -> Float in
            let t = Double(i) / sr
            let bpm = bpm0 + (bpm1 - bpm0) * t / seconds
            let phase = (bpm0 * t + 0.5 * (bpm1 - bpm0) * t * t / seconds) / 60
            let k = phase.rounded(.down)
            let since = (phase - k) * 60 / bpm
            let eighth = (2 * phase - (2 * phase).rounded(.down)) * 30 / bpm
            let accent = k.truncatingRemainder(dividingBy: perBar) == 0 ? 1.0 : 0.6
            let kick = sin(2 * .pi * 55 * since) * exp(-30 * since) * accent
            let snare = (k.truncatingRemainder(dividingBy: 2) == 1 ? sin(2 * .pi * 1800 * since + 40 * sin(2 * .pi * 370 * since)) : 0)
                * exp(-40 * since) * 0.3
            let hats = sin(2 * .pi * 7000 * eighth + 30 * sin(2 * .pi * 1130 * eighth)) * exp(-80 * eighth) * 0.15
            let chord = 0.1 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 277.18 * t)
            return Float(kick + snare + hats + chord)
        }
    }

    @Test func spectrogramMatchesLogMelSpect() {
        let ref = Self.fixture.spectrogram
        let x = Self.drums(seconds: 40, bpm0: 123, bpm1: 123, perBar: 4)
        #expect(BeatThisAudio.frameCount(samples: x.count) == ref.shape[0])
        let spect = BeatThisAudio.spectrogram(x)
        #expect(spect.count == ref.shape[0] * ref.shape[1])
        var worst: Float = 0
        for (i, v) in zip(ref.index, ref.values) { worst = max(worst, abs(spect[i] - v)) }
        #expect(worst < 1e-3, "largest difference \(worst)")
        let mean = spect.reduce(0.0) { $0 + Double($1) } / Double(spect.count)
        #expect(abs(mean - ref.mean) < 1e-5)
    }

    @Test func halfRateFilterMatchesScipy() {
        let ref = Self.fixture.half_rate
        let taps = HalfRate.taps
        #expect(taps.count % 8 == 0 && taps[ref.taps.count...].allSatisfy { $0 == 0 })
        #expect(zip(taps, ref.taps).allSatisfy { abs($0 - $1) < 1e-8 })
        // parity_music.py's sweep: 100 Hz to 20 kHz over 2 s at 44.1 kHz.
        let sweep = (0 ..< 2 * 44_100).map { i -> Float in
            let t = Double(i) / 44_100
            return Float(0.5 * sin(2 * .pi * (100 * t + 5000 * t * t)))
        }
        let half = HalfRate.decimate(sweep)
        #expect(half.count == ref.length)
        #expect(zip(ref.index, ref.values).allSatisfy { abs(half[$0] - $1) < 1e-5 })
        #expect(HalfRate.decimate([1, 2, 3]).count == 2)
    }

    @Test func chunksStartWhereSplitPieceStartsThem() {
        for (n, starts) in Self.fixture.chunk_starts {
            #expect(BeatThisAudio.chunkStarts(frames: Int(n)!) == starts, "\(n) frames")
        }
    }

    @Test func chunkIsZeroOutsideTheSong() {
        let n = 2000, mels = BeatThisAudio.mels
        let spect = (0 ..< n * mels).map { Float($0 / mels + 1) }   // each frame holds its number + 1
        let first = BeatThisAudio.chunk(spect, frames: n, start: -6)
        #expect(first[5 * mels] == 0 && first[6 * mels] == 1 && first[1499 * mels] == 1494)
        let last = BeatThisAudio.chunk(spect, frames: n, start: n - 1494)
        #expect(last[0] == Float(n - 1494 + 1) && last[1493 * mels] == Float(n) && last[1494 * mels] == 0)
    }

    @Test func aggregateKeepsTheEarlierChunk() {
        let ref = Self.fixture.aggregate
        let starts = BeatThisAudio.chunkStarts(frames: ref.frames)
        let outputs = starts.indices.map { i in (0 ..< BeatThisAudio.chunk).map { Float($0) + Float(10_000 * (i + 1)) } }
        #expect(BeatThisAudio.aggregate(outputs, starts: starts, frames: ref.frames) == ref.beat)
    }

    @Test(arguments: ["steady", "ramp"])
    func tempoMatchesPhase0(name: String) throws {
        let song = try #require(Self.fixture.songs.first { $0.name == name })
        let (beats, downbeats) = BeatTracking.peaks(beatLogits: song.beat_logits, downbeatLogits: song.downbeat_logits)
        #expect(beats == song.peaks)
        #expect(downbeats == song.downbeats)
        let prob = song.beat_logits.map(BeatTracking.sigmoid)
        let refined = BeatTracking.refine(beats, prob)
        #expect(refined.count == song.refined.count)
        #expect(zip(refined, song.refined).allSatisfy { abs($0 - $1) < 1e-6 })
        let s = BeatTracking.summarize(beats: beats, downbeats: downbeats, beatProbability: prob)
        #expect(s.bpm == song.bpm)
        #expect(s.bpmRange.map { [$0.lowerBound, $0.upperBound] } == song.bpm_range)
        #expect(s.stability == song.stability)
        #expect(s.beatsPerBar == song.beats_per_bar)
        #expect(abs(s.confidence - song.confidence) <= 0.001)
    }

    @Test func fewBeatsMeanNoTempo() {
        let s = BeatTracking.summarize(beats: [0.5, 1.0, 1.5], downbeats: [], beatProbability: [Float](repeating: 0.9, count: 100))
        #expect(s.bpm == nil && s.stability == "no steady beat")
    }

    @Test func keyLabelsFollowSKeysOrder() {
        #expect(KeyDetection.labels == Self.fixture.key_labels.map { MusicKey(parsing: $0)! })
        var p = [Float](repeating: 0.01, count: 24)
        p[22] = 0.7; p[3] = 0.2
        let e = KeyDetection.estimate(probabilities: p)
        #expect(e?.key == MusicKey(pitchClass: 9, minor: true))
        #expect(e?.runnerUp == MusicKey(pitchClass: 0, minor: false))
        #expect(KeyDetection.estimate(probabilities: [0.5, 0.5]) == nil)
    }
}
