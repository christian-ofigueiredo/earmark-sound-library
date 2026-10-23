import AVFoundation
import EarmarkCore
import Foundation
import Observation

/// Background analysis: works through sounds without current results, as fast as
/// the governor allows. Mainly runs while the Mac is idle (e.g. overnight), backs
/// off when another app is busy, and saves after every few files so quitting or
/// unplugging a drive loses nothing. Files are only ever opened for reading.
@MainActor @Observable
final class AnalysisEngine {
    private(set) var pace = AnalysisPace(workers: 0, reason: .waitingForIdle)
    private(set) var facts: [Int64: SoundFacts] = [:]
    /// Sounds still to measure (not counting the ones in progress).
    private(set) var remaining = 0
    private(set) var inProgress = 0

    var mode: AnalysisGovernor.Mode {
        didSet {
            governor.mode = mode
            // Full speed is for now only; never come back to it after a relaunch.
            if mode != .fullSpeed { UserDefaults.standard.set(mode.rawValue, forKey: "analysisMode") }
            tick()
        }
    }

    private weak var model: AppModel?
    private var governor: AnalysisGovernor
    private let monitor = SystemMonitor()
    private var queue: [SoundRecord] = []
    private var running: [Int64: Task<Void, Never>] = [:]
    private var unsaved: [SoundFacts] = []
    private var loop: Task<Void, Never>?
    /// Keeps App Nap from throttling analysis while it runs (idle sleep is still allowed).
    private var activity: NSObjectProtocol?

    init() {
        let saved = AnalysisGovernor.Mode(rawValue: UserDefaults.standard.string(forKey: "analysisMode") ?? "")
        mode = saved ?? .automatic
        // Leave cores for the system and for whatever the user starts next.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        governor = AnalysisGovernor(mode: saved ?? .automatic, settings: .init(fullWorkers: max(1, cores / 2)))
    }

    func start(model: AppModel) {
        self.model = model
        if let db = model.database { facts = (try? db.soundFacts()) ?? [:] }
        rebuildQueue()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Call after the library changes (scan, library added or removed).
    func libraryChanged() {
        rebuildQueue()
        fill()
    }

    var statusText: String {
        let left = remaining + inProgress
        guard left > 0 else { return facts.isEmpty ? "" : "Loudness measured for every sound" }
        let count = "\(left.formatted()) sound\(left == 1 ? "" : "s") to measure"
        switch pace.reason {
        case .idle: return "Measuring loudness at full speed: \(count)"
        case .requested: return "Measuring loudness at full speed, as asked: \(count)"
        case .userActive: return "Measuring loudness gently while you work: \(count)"
        case .pausedByUser: return "Analysis paused: \(count)"
        case .waitingForIdle: return "Analysis waits for the Mac to be idle: \(count)"
        case .macBusy: return "Analysis paused while another app is busy: \(count)"
        case .hot: return "Analysis paused while the Mac is hot: \(count)"
        case .battery: return "Analysis paused on battery: \(count)"
        case .lowPower: return "Analysis paused in Low Power Mode: \(count)"
        }
    }

    // MARK: work

    private func rebuildQueue() {
        guard let model else { return }
        let hidden = model.soundIndex.twins.hidden
        let online = Set(model.soundLibraries.filter(\.isOnline).compactMap(\.id))   // one disk check per library
        // Reversed so popLast() works through the library in list order.
        queue = model.sounds.reversed().filter { s in
            guard let id = s.id, !hidden.contains(id), running[id] == nil,
                  online.contains(s.libraryId) else { return false }
            return !(facts[id]?.isCurrent(for: s) ?? false)
        }
        remaining = queue.count
    }

    private func tick() {
        pace = governor.update(monitor.sample())
        // Over the limit (the Mac got busy): stop the newest files; they go back in the queue.
        while running.count > pace.workers, let (id, task) = running.max(by: { $0.key < $1.key }) {
            task.cancel()
            running[id] = nil
            if let s = model?.sound(id: id) { queue.append(s) }
        }
        fill()
        save()
        updateActivity()
    }

    private func fill() {
        while running.count < pace.workers, let sound = queue.popLast() {
            guard let id = sound.id else { continue }
            let url = sound.url, fingerprint = sound.fingerprint
            let priority: TaskPriority = pace.reason == .userActive ? .background : .utility
            running[id] = Task.detached(priority: priority) { [weak self] in
                guard let result = SoundAnalyzer.facts(soundId: id, url: url, fingerprint: fingerprint) else { return }
                await self?.finished(result)
            }
        }
        remaining = queue.count
        inProgress = running.count
    }

    private func finished(_ result: SoundFacts) {
        guard running.removeValue(forKey: result.soundId) != nil else { return }   // cancelled meanwhile
        // A read error because the drive went away isn't the file's fault: measure it next time.
        if result.error != nil, let s = model?.sound(id: result.soundId), !(model?.isOnline(libraryId: s.libraryId) ?? false) {
            fill()
            return
        }
        facts[result.soundId] = result
        unsaved.append(result)
        if unsaved.count >= 50 { save() }
        fill()
    }

    private func save() {
        guard !unsaved.isEmpty, let db = model?.database else { return }
        let batch = unsaved
        unsaved = []
        Task.detached(priority: .utility) { try? db.save(batch) }
    }

    private func updateActivity() {
        let working = !running.isEmpty
        if working, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Analysing sounds")
        } else if !working, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    func stop() {
        loop?.cancel()
        running.values.forEach { $0.cancel() }
        running = [:]
        save()
    }
}

/// Measures one sound. Runs off the main thread; opens the file read-only.
enum SoundAnalyzer {
    /// nil when cancelled (the sound stays in the queue).
    static func facts(soundId: Int64, url: URL, fingerprint: String?) -> SoundFacts? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat   // float32, one buffer per channel
            let channels = Int(format.channelCount)
            var meter = LoudnessMeter(sampleRate: format.sampleRate, channels: channels)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16),
                  let data = buffer.floatChannelData else {
                return SoundFacts(soundId: soundId, fingerprint: fingerprint, loudness: nil, error: "unsupported format")
            }
            while file.framePosition < file.length {
                if Task.isCancelled { return nil }
                try file.read(into: buffer)
                let n = Int(buffer.frameLength)
                if n == 0 { break }
                meter.process((0 ..< channels).map { UnsafeBufferPointer(start: data[$0], count: n) }, frames: n)
            }
            return SoundFacts(soundId: soundId, fingerprint: fingerprint, loudness: meter.result)
        } catch {
            return SoundFacts(soundId: soundId, fingerprint: fingerprint, loudness: nil, error: error.localizedDescription)
        }
    }
}
