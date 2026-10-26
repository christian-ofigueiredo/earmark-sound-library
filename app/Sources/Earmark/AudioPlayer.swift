import AVFoundation
import Observation

/// Plays one file at a time, optionally just a range of it, at a gain (loudness normalising
/// for previews, `gain`). Files are only read. AVAudioEngine rather than AVAudioPlayer, whose
/// volume can't go above the file's own level: a sound at −44 LUFS couldn't be brought up.
@MainActor @Observable
final class AudioPlayer {
    enum State { case stopped, playing, paused }

    private(set) var url: URL?
    private(set) var state = State.stopped
    /// Updated a few times a second; `liveTime` is exact.
    private(set) var currentTime: TimeInterval = 0
    private(set) var error: String?
    /// Where playback stops when playing a selected range.
    private(set) var rangeEnd: TimeInterval?

    var isPlaying: Bool { state == .playing }

    /// The gain to play a file at, dB. Asked when a file starts and by `refreshGain`.
    @ObservationIgnored var gain: (URL) -> Double = { _ in 0 }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    /// Two stages: each goes from −96 to +24 dB, and a quiet sound may need more than +24.
    @ObservationIgnored private let boost = [AVAudioUnitEQ(numberOfBands: 0), AVAudioUnitEQ(numberOfBands: 0)]
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    @ObservationIgnored private var file: AVAudioFile?
    /// The file time where the scheduled segment starts (the node counts from there).
    @ObservationIgnored private var segmentStart: TimeInterval = 0
    /// Bumped whenever a segment is scheduled or dropped, so an old one's end is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        engine.attach(node)
        boost.forEach(engine.attach)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    func plays(_ url: URL) -> Bool { isPlaying && self.url == url }

    /// Playing or paused on this file (the playhead and time are worth showing).
    func isActive(_ url: URL) -> Bool { self.url == url && state != .stopped }

    /// The time right now, for drawing at the display's rate.
    var liveTime: TimeInterval { state == .playing ? playedTime() : currentTime }

    /// Play ↔ pause for this file (the play button and Space); starts it if another file is loaded.
    func toggle(_ url: URL) {
        guard self.url == url else { return play(url) }
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .stopped: play(url)
        }
    }

    func play(_ url: URL, from start: TimeInterval = 0, to end: TimeInterval? = nil) {
        stopTicker()
        error = nil
        if self.url != url || file == nil {
            node.stop()
            generation += 1
            self.url = url
            currentTime = 0
            do {
                let f = try AVAudioFile(forReading: url)
                try connect(f.processingFormat)
                file = f
            } catch {
                file = nil
                state = .stopped
                self.error = "Can't play this file (\(error.localizedDescription))."
                return
            }
        }
        refreshGain()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            state = .stopped
            self.error = "Can't play this file (\(error.localizedDescription))."
            return
        }
        schedule(from: start, to: end)
        node.play()
        state = .playing
        currentTime = playedTime()
        startTicker()
    }

    func pause() {
        guard state == .playing else { return }
        currentTime = playedTime()
        node.pause()
        engine.pause()
        stopTicker()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if let rangeEnd, currentTime >= rangeEnd { clearRange() }
        do { try engine.start() } catch { return }
        node.play()
        state = .playing
        startTicker()
    }

    /// Moves the playhead, keeping playing or paused as it was. Past the selected range, the range is dropped.
    func seek(to time: TimeInterval) {
        guard file != nil, state != .stopped else { return }
        let t = max(0, min(time, duration))
        if let rangeEnd, t >= rangeEnd { self.rangeEnd = nil }
        schedule(from: t, to: rangeEnd)
        currentTime = t
        if state == .playing { node.play() }
    }

    /// Moves the playhead by `delta` seconds (the arrow keys), playing or paused as it was;
    /// past the end it stops, as at the end of the file.
    func skip(by delta: TimeInterval) {
        guard file != nil, state != .stopped else { return }
        let t = liveTime + delta
        guard t < duration else { return stop() }
        seek(to: max(0, t))
    }

    /// Play to the end of the file instead of stopping at the end of the selected range.
    func clearRange() {
        guard rangeEnd != nil else { return }
        rangeEnd = nil
        guard state != .stopped else { return }
        let t = liveTime
        schedule(from: t, to: nil)
        currentTime = t
        if state == .playing { node.play() }
    }

    /// Stops and goes back to the start.
    func stop() {
        stopTicker()
        node.stop()
        engine.pause()
        generation += 1
        currentTime = 0
        rangeEnd = nil
        state = .stopped
    }

    /// Applies the gain for the loaded file again (the preference changed, or its loudness came in).
    func refreshGain() {
        let db = url.map(gain) ?? 0
        boost[0].globalGain = Float(max(-96, min(db, 24)))
        boost[1].globalGain = Float(max(0, min(db - 24, 24)))
    }

    // MARK: engine

    private var duration: TimeInterval {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Node → two gain stages → the output, in the file's format (re-made when it changes).
    private func connect(_ format: AVAudioFormat) throws {
        guard format != connectedFormat else { return }
        let wasRunning = engine.isRunning
        engine.stop()
        engine.connect(node, to: boost[0], format: format)
        engine.connect(boost[0], to: boost[1], format: format)
        engine.connect(boost[1], to: engine.mainMixerNode, format: format)
        connectedFormat = format
        if wasRunning { try engine.start() }
    }

    /// Replaces what's scheduled with `start…end` of the file (the node stays stopped).
    private func schedule(from start: TimeInterval, to end: TimeInterval?) {
        guard let file else { return }
        node.stop()
        generation += 1
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, min(start, duration)) * rate)
        let last = end.map { AVAudioFramePosition(max(0, min($0, duration)) * rate) } ?? file.length
        segmentStart = Double(first) / rate
        rangeEnd = end
        guard last > first else { return }
        let ending = generation
        node.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(last - first), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentEnded(ending) }
        }
    }

    private func segmentEnded(_ ending: Int) {
        // Reached the end of the file or of the range (not a segment dropped by a seek or stop).
        if ending == generation, state == .playing { stop() }
    }

    private func playedTime() -> TimeInterval {
        guard let renderTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: renderTime),
              time.sampleRate > 0 else { return currentTime }
        return min(segmentStart + Double(time.sampleTime) / time.sampleRate, duration)
    }

    /// The output device changed (headphones, a display's speakers): the engine stopped; carry on.
    private func outputChanged() {
        guard let format = connectedFormat else { return }
        let wasPlaying = state == .playing, t = liveTime
        connectedFormat = nil
        try? connect(format)
        guard state != .stopped else { return }
        schedule(from: t, to: rangeEnd)
        currentTime = t
        if wasPlaying {
            try? engine.start()
            node.play()
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        currentTime = playedTime()
        if let rangeEnd, currentTime >= rangeEnd { stop() }
    }
}
