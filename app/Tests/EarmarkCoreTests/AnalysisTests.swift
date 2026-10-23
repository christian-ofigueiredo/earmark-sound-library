import Foundation
import Testing
@testable import EarmarkCore

@Suite struct LoudnessTests {
    static func sine(dBFS: Double, seconds: Double, rate: Double, hz: Double = 1000) -> [Float] {
        let amp = pow(10, dBFS / 20), n = Int(seconds * rate)
        return (0 ..< n).map { Float(amp * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    static func measure(_ channels: [[Float]], rate: Double, chunk: Int = 4096) -> LoudnessMeter.Result {
        var meter = LoudnessMeter(sampleRate: rate, channels: channels.count)
        let frames = channels[0].count
        var start = 0
        while start < frames {
            let end = min(frames, start + chunk)
            meter.process(channels.map { Array($0[start ..< end]) })
            start = end
        }
        return meter.result
    }

    // EBU Tech 3341, cases 1 and 2: stereo 1 kHz sine at -23 / -33 dBFS reads -23 / -33 LUFS (±0.1).
    @Test(arguments: [(-23.0, 48000.0), (-33.0, 48000.0), (-23.0, 44100.0), (-23.0, 96000.0)])
    func stereoSine(level: Double, rate: Double) {
        let s = Self.sine(dBFS: level, seconds: 20, rate: rate)
        let r = Self.measure([s, s], rate: rate)
        #expect(abs(r.integrated! - level) <= 0.1)
        #expect(abs(r.peak! - level) <= 0.01)
    }

    // EBU Tech 3341, case 3: -36 dB for 10 s, -23 dB for 60 s, -36 dB for 10 s reads -23 LUFS.
    @Test func relativeGate() {
        let rate = 48000.0
        let s = Self.sine(dBFS: -36, seconds: 10, rate: rate) + Self.sine(dBFS: -23, seconds: 60, rate: rate)
            + Self.sine(dBFS: -36, seconds: 10, rate: rate)
        let r = Self.measure([s, s], rate: rate, chunk: 48000)
        #expect(abs(r.integrated! - -23) <= 0.1)
    }

    @Test func shortSoundsAndSilence() {
        let rate = 48000.0
        let blip = Self.sine(dBFS: -23, seconds: 0.2, rate: rate)
        let r = Self.measure([blip, blip], rate: rate)
        #expect(abs(r.integrated! - -23) <= 0.3)
        let silence = Self.measure([[Float](repeating: 0, count: 48000)], rate: rate)
        #expect(silence.integrated == nil && silence.peak == nil)
    }
}

@Suite struct GovernorTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { start.addingTimeInterval(s) }
    static let quiet = SystemSignals(userIdle: 2, otherCPU: 0.05, gpu: 0.02)
    static let idle = SystemSignals(userIdle: 600, otherCPU: 0.05, gpu: 0.02)

    @Test func rampsUpSlowlyAndBacksOffAtOnce() {
        var g = AnalysisGovernor(settings: .init(fullWorkers: 4))
        #expect(g.update(Self.quiet, now: Self.at(0)).isPaused)          // waits before starting
        #expect(g.update(Self.quiet, now: Self.at(59)).isPaused)
        #expect(g.update(Self.quiet, now: Self.at(60)) == AnalysisPace(workers: 1, reason: .userActive))
        #expect(g.update(Self.idle, now: Self.at(70)).workers == 1)       // idle, but not for long enough
        #expect(g.update(Self.idle, now: Self.at(130)) == AnalysisPace(workers: 4, reason: .idle))
        #expect(g.update(Self.quiet, now: Self.at(131)).workers == 1)     // user is back: at once
    }

    @Test func pausesWhileAnotherAppIsBusyWithHysteresis() {
        var g = AnalysisGovernor(settings: .init(fullWorkers: 4))
        g.update(Self.idle, now: Self.at(0)); g.update(Self.idle, now: Self.at(60))
        #expect(g.pace.workers == 4)
        let export = SystemSignals(userIdle: 900, otherCPU: 0.3, gpu: 0.8)   // Resolve rendering overnight
        #expect(g.update(export, now: Self.at(61)) == AnalysisPace(workers: 0, reason: .macBusy))
        // Load between the idle quiet and busy thresholds: stays paused.
        let middling = SystemSignals(userIdle: 900, otherCPU: 0.5, gpu: 0.5)
        #expect(g.update(middling, now: Self.at(500)).reason == .macBusy)
        // Quiet again: restarts only after the ramp-up time.
        #expect(g.update(Self.idle, now: Self.at(600)).isPaused)
        #expect(g.update(Self.idle, now: Self.at(660)).workers == 4)
    }

    @Test func resolveOpenBlocksOnlyWhileYouWork() {
        var g = AnalysisGovernor(settings: .init(fullWorkers: 4))
        let editing = SystemSignals(userIdle: 0, otherCPU: 0.1, gpu: 0.4)    // Resolve open, user editing
        #expect(g.update(editing, now: Self.at(0)).reason == .macBusy)
        let leftOpen = SystemSignals(userIdle: 900, otherCPU: 0.1, gpu: 0.4) // same, user away
        g.update(leftOpen, now: Self.at(1))
        #expect(g.update(leftOpen, now: Self.at(61)) == AnalysisPace(workers: 4, reason: .idle))
        #expect(g.update(editing, now: Self.at(62)).reason == .macBusy)        // user is back
        g.mode = .fullSpeed                                                     // and asks for it: at once
        #expect(g.update(editing, now: Self.at(63)) == AnalysisPace(workers: 4, reason: .requested))
    }

    @Test func modesAndSafetyLimits() {
        var g = AnalysisGovernor(mode: .idleOnly, settings: .init(fullWorkers: 4))
        #expect(g.target(for: Self.quiet) == AnalysisPace(workers: 0, reason: .waitingForIdle))
        g.mode = .paused
        #expect(g.update(Self.idle, now: Self.at(0)).reason == .pausedByUser)
        g.mode = .automatic
        #expect(g.update(Self.idle, now: Self.at(1)).workers == 4)          // resuming is immediate
        var hot = Self.idle; hot.thermal = .serious
        #expect(g.update(hot, now: Self.at(2)).reason == .hot)
        var battery = Self.idle; battery.onBattery = true
        #expect(g.target(for: battery).reason == .battery)
        var warm = Self.idle; warm.thermal = .fair
        #expect(g.target(for: warm).workers == 2)
    }
}

@Suite struct FactsTests {
    @Test func factsSurviveRemovingAndReAddingALibrary() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("a.wav"))
        var lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let sound = try db.sounds()[0]
        try db.save([SoundFacts(soundId: sound.id!, fingerprint: sound.fingerprint,
                                loudness: .init(integrated: -20, peak: -1))])
        try db.removeLibrary(id: lib.id!)
        lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let again = try db.sounds()[0]
        let facts = try db.soundFacts()[again.id!]
        #expect(facts?.loudness == -20)
        #expect(facts?.isCurrent(for: again) == true)
        var changed = again; changed.fingerprint = "other"
        #expect(facts?.isCurrent(for: changed) == false)
    }
}
