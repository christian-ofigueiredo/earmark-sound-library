import AVFoundation
import Observation

/// Plays one file at a time, optionally just a range of it. Files are only read.
@MainActor @Observable
final class AudioPlayer {
    enum State { case stopped, playing, paused }

    private(set) var url: URL?
    private(set) var state = State.stopped
    private(set) var currentTime: TimeInterval = 0
    private(set) var error: String?
    /// Where playback stops when playing a selected range.
    private(set) var rangeEnd: TimeInterval?

    var isPlaying: Bool { state == .playing }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func plays(_ url: URL) -> Bool { isPlaying && self.url == url }

    /// Playing or paused on this file (the playhead and time are worth showing).
    func isActive(_ url: URL) -> Bool { self.url == url && state != .stopped }

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
        if self.url != url || player == nil {
            player?.stop()
            player = nil
            self.url = url
            currentTime = 0
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                player = p
            } catch {
                state = .stopped
                self.error = "Can't play this file (\(error.localizedDescription))."
                return
            }
        }
        guard let player else { return }
        player.currentTime = max(0, min(start, player.duration))
        rangeEnd = end
        guard player.play() else {
            state = .stopped
            error = "Can't play this file."
            return
        }
        state = .playing
        currentTime = player.currentTime
        startTicker()
    }

    func pause() {
        guard state == .playing, let player else { return }
        player.pause()
        stopTicker()
        currentTime = player.currentTime
        state = .paused
    }

    func resume() {
        guard state == .paused, let player else { return }
        if let rangeEnd, player.currentTime >= rangeEnd { self.rangeEnd = nil }
        guard player.play() else { return }
        state = .playing
        startTicker()
    }

    /// Moves the playhead, keeping playing or paused as it was. Past the selected range, the range is dropped.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let t = max(0, min(time, player.duration))
        player.currentTime = t
        currentTime = t
        if let rangeEnd, t >= rangeEnd { self.rangeEnd = nil }
    }

    /// Play to the end of the file instead of stopping at the end of the selected range.
    func clearRange() { rangeEnd = nil }

    /// Stops and goes back to the start.
    func stop() {
        stopTicker()
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        rangeEnd = nil
        state = .stopped
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
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
        guard let player else { return }
        currentTime = player.currentTime
        if let rangeEnd, currentTime >= rangeEnd {
            stop()
        } else if !player.isPlaying, state == .playing {
            stop()   // reached the end
        }
    }
}
