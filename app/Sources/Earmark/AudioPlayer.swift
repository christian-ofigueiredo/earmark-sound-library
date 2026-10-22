import AVFoundation
import Observation

/// Plays one file at a time, optionally just a range of it. Files are only read.
@MainActor @Observable
final class AudioPlayer {
    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var error: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var endTime: TimeInterval?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func plays(_ url: URL) -> Bool { isPlaying && self.url == url }

    func toggle(_ url: URL) {
        if plays(url) { stop() } else { play(url) }
    }

    func play(_ url: URL, from start: TimeInterval = 0, to end: TimeInterval? = nil) {
        stop()
        error = nil
        if self.url != url || player == nil {
            player = nil
            self.url = url
            currentTime = 0
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                player = p
            } catch {
                self.error = "Can't play this file (\(error.localizedDescription))."
                return
            }
        }
        guard let player else { return }
        player.currentTime = max(0, min(start, player.duration))
        endTime = end
        guard player.play() else {
            error = "Can't play this file."
            return
        }
        isPlaying = true
        currentTime = player.currentTime
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        isPlaying = false
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if let endTime, currentTime >= endTime {
            stop()
        } else if !player.isPlaying {
            stop()
        }
    }
}
