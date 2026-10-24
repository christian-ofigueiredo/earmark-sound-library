import AVFoundation
import EarmarkCore
import EarmarkML
import Foundation
import Observation

/// What a sound still needs. Each job runs the missing stages for one sound.
enum AnalysisStage: String, CaseIterable, Sendable {
    case loudness
    case clap
    /// Runs in batches on the GPU, only while the Mac is idle (see AnalysisEngine.fillPeav()).
    case peav

    var title: String {
        switch self {
        case .loudness: "loudness"
        case .clap: "CLAP embeddings"
        case .peav: "PE-AV embeddings"
        }
    }
}

/// Background analysis: works through sounds without current results, as fast as
/// the governor allows. Mainly runs while the Mac is idle (e.g. overnight), backs
/// off when another app is busy, and saves after every few files so quitting or
/// unplugging a drive loses nothing. Files are only ever opened for reading.
@MainActor @Observable
final class AnalysisEngine {
    private(set) var pace = AnalysisPace(workers: 0, reason: .waitingForIdle)
    private(set) var facts: [Int64: SoundFacts] = [:]
    private(set) var clapStatus: [Int64: SoundEmbedding.Status] = [:]
    /// Sounds still to analyse (not counting the ones in progress), and per stage.
    private(set) var remaining = 0
    private(set) var inProgress = 0
    private(set) var remainingByStage: [AnalysisStage: Int] = [:]
    /// Why CLAP isn't running, if it can't (model missing or failed to load).
    private(set) var clapUnavailable: String?
    private(set) var peavStatus: [Int64: SoundEmbedding.Status] = [:]
    /// Why PE-AV isn't running, if it can't.
    private(set) var peavUnavailable: String?

    var mode: AnalysisGovernor.Mode {
        didSet {
            governor.mode = mode
            // Full speed is for now only; never come back to it after a relaunch.
            if mode != .fullSpeed { UserDefaults.standard.set(mode.rawValue, forKey: "analysisMode") }
            tick()
        }
    }

    /// Where the CLAP model is installed for now: ~/Library/Application Support/Earmark/Models.
    let clapModels = ClapModelStore(folder: AppModel.supportFolder.appendingPathComponent("Models", isDirectory: true))
    /// PE-AV's five parts: ~/Library/Application Support/Earmark/Models/PEAV/PEAV*.mlpackage.
    let peavFolder = AppModel.supportFolder.appendingPathComponent("Models/PEAV", isDirectory: true)
    /// Sounds per PE-AV batch: each of the five parts is loaded once per batch.
    static let peavBatchSize = 32

    private weak var model: AppModel?
    private var governor: AnalysisGovernor
    private let monitor = SystemMonitor()
    private let log = SchedulerLog(folder: AppModel.supportFolder.appendingPathComponent("Logs", isDirectory: true))
    private var queue: [(sound: SoundRecord, stages: Set<AnalysisStage>)] = []
    private var running: [Int64: (task: Task<Void, Never>, sound: SoundRecord, stages: Set<AnalysisStage>)] = [:]
    private var peavQueue: [SoundRecord] = []
    private var peavBatch: (task: Task<Void, Never>, sounds: [SoundRecord])?
    private var unsavedFacts: [SoundFacts] = []
    private var unsavedEmbeddings: [SoundEmbedding] = []
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
        if let db = model.database {
            facts = (try? db.soundFacts()) ?? [:]
            clapStatus = (try? db.embeddingStatus(model: ClapEmbedder.modelName)) ?? [:]
            peavStatus = (try? db.embeddingStatus(model: PeavEmbedder.modelName)) ?? [:]
        }
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
        let missing = [clapUnavailable != nil ? "CLAP" : nil, peavUnavailable != nil ? "PE-AV" : nil].compactMap { $0 }
        let missingModel = missing.isEmpty ? "" : " · \(missing.joined(separator: " and ")) model not installed"
        guard left > 0 else { return facts.isEmpty ? "" : "Analysis up to date" + missingModel }
        let count = "\(left.formatted()) sound\(left == 1 ? "" : "s") to analyse"
        let doing = AnalysisStage.allCases.filter { (remainingByStage[$0] ?? 0) > 0 }.map(\.title).joined(separator: ", ")
        let what = doing.isEmpty ? count : "\(count) (\(doing))"
        // Only PE-AV left, and the Mac isn't idle: say what it's waiting for.
        if doing == AnalysisStage.peav.title, !Self.gpuAllowed(pace), !pace.isPaused {
            return "PE-AV embeddings wait for the Mac to be idle: \(count)" + missingModel
        }
        switch pace.reason {
        case .idle: return "Analysing at full speed: \(what)" + missingModel
        case .requested: return "Analysing at full speed, as asked: \(what)" + missingModel
        case .userActive: return "Analysing gently while you work: \(what)" + missingModel
        case .pausedByUser: return "Analysis paused: \(what)" + missingModel
        case .waitingForIdle: return "Analysis waits for the Mac to be idle: \(what)" + missingModel
        case .macBusy: return "Analysis paused while another app is busy: \(what)" + missingModel
        case .hot: return "Analysis paused while the Mac is hot: \(what)" + missingModel
        case .battery: return "Analysis paused on battery: \(what)" + missingModel
        case .lowPower: return "Analysis paused in Low Power Mode: \(what)" + missingModel
        }
    }

    // MARK: work

    private func stages(for s: SoundRecord) -> Set<AnalysisStage> {
        guard let id = s.id else { return [] }
        var needed: Set<AnalysisStage> = []
        if !(facts[id]?.isCurrent(for: s) ?? false) { needed.insert(.loudness) }
        if clapUnavailable == nil,
           !SoundEmbedding.isCurrent(clapStatus[id], model: ClapEmbedder.modelName, for: s) { needed.insert(.clap) }
        return needed
    }

    /// Whether this sound still needs a PE-AV embedding.
    private func needsPeav(_ s: SoundRecord) -> Bool {
        guard let id = s.id, peavUnavailable == nil else { return false }
        return !SoundEmbedding.isCurrent(peavStatus[id], model: PeavEmbedder.modelName, for: s)
    }

    /// PE-AV uses the GPU, so it runs only while the Mac is idle or when the user asked for full speed.
    static func gpuAllowed(_ pace: AnalysisPace) -> Bool {
        pace.workers > 0 && (pace.reason == .idle || pace.reason == .requested)
    }

    private var peavInstalled: Bool {
        PeavEmbedder.parts.allSatisfy { part in
            ["mlpackage", "mlmodelc"].contains { FileManager.default.fileExists(atPath: peavFolder.appendingPathComponent("\(part).\($0)").path) }
        }
    }

    private func rebuildQueue() {
        guard let model else { return }
        clapUnavailable = clapModels.isInstalled ? nil : "not installed"
        if peavUnavailable == nil || peavUnavailable == "not installed" { peavUnavailable = peavInstalled ? nil : "not installed" }
        let hidden = model.soundIndex.twins.hidden
        let online = Set(model.soundLibraries.filter(\.isOnline).compactMap(\.id))   // one disk check per library
        // Reversed so popLast() works through the library in list order.
        queue = model.sounds.reversed().compactMap { s in
            guard let id = s.id, !hidden.contains(id), running[id] == nil, online.contains(s.libraryId) else { return nil }
            let needed = stages(for: s)
            return needed.isEmpty ? nil : (s, needed)
        }
        let inBatch = Set(peavBatch?.sounds.compactMap(\.id) ?? [])
        peavQueue = model.sounds.reversed().filter { s in
            guard let id = s.id, !hidden.contains(id), !inBatch.contains(id), online.contains(s.libraryId) else { return false }
            return needsPeav(s)
        }
        countRemaining()
    }

    private func countRemaining() {
        // Distinct sounds with any stage left; the PE-AV lane has its own queue.
        var waiting = Set(queue.compactMap(\.sound.id))
        waiting.formUnion(peavQueue.compactMap(\.id))
        var busy = Set(running.keys)
        busy.formUnion(peavBatch?.sounds.compactMap(\.id) ?? [])
        remaining = waiting.subtracting(busy).count
        inProgress = busy.count
        var byStage: [AnalysisStage: Int] = [:]
        for job in queue { for stage in job.stages { byStage[stage, default: 0] += 1 } }
        for job in running.values { for stage in job.stages { byStage[stage, default: 0] += 1 } }
        byStage[.peav] = peavQueue.count + (peavBatch?.sounds.count ?? 0)
        remainingByStage = byStage.filter { $0.value > 0 }
    }

    private func tick() {
        let signals = monitor.sample()
        pace = governor.update(signals)
        log.record(signals, ownGPU: monitor.ownGPU, mode: mode, pace: pace, remaining: remaining,
                   running: running.count + (peavBatch?.sounds.count ?? 0), measured: facts.count)
        // The Mac isn't idle any more: stop the PE-AV batch (it uses the GPU); it goes back in the queue.
        if let batch = peavBatch, !Self.gpuAllowed(pace) {
            batch.task.cancel()
            peavBatch = nil
            peavQueue.append(contentsOf: batch.sounds.reversed())
        }
        // Over the limit (the Mac got busy): stop the newest files; they go back in the queue.
        while running.count > cpuWorkers, let (id, job) = running.max(by: { $0.key < $1.key }) {
            job.task.cancel()
            running[id] = nil
            queue.append((job.sound, job.stages))
        }
        fill()
        save()
        // Give CLAP's memory back while nothing needs it (e.g. paused while you edit).
        if clapModels.isLoaded, !running.values.contains(where: { $0.stages.contains(.clap) }),
           pace.isPaused || !queue.contains(where: { $0.stages.contains(.clap) }) {
            clapModels.unload()
        }
        updateActivity()
    }

    /// Per-sound workers: the PE-AV batch, while it runs, takes one of the pace's slots.
    private var cpuWorkers: Int { max(0, pace.workers - (peavBatch != nil ? 1 : 0)) }

    private func fill() {
        fillPeav()
        while running.count < cpuWorkers, let job = queue.popLast() {
            guard let id = job.sound.id else { continue }
            let url = job.sound.url, fingerprint = job.sound.fingerprint, stages = job.stages, models = clapModels
            let priority: TaskPriority = pace.reason == .userActive ? .background : .utility
            let task = Task.detached(priority: priority) { [weak self] in
                guard let result = SoundAnalyzer.run(soundId: id, url: url, fingerprint: fingerprint,
                                                     stages: stages, clap: models) else { return }
                await self?.finished(result)
            }
            running[id] = (task, job.sound, stages)
        }
        countRemaining()
    }

    /// Starts the next PE-AV batch when the Mac is idle and none is running.
    private func fillPeav() {
        guard peavBatch == nil, Self.gpuAllowed(pace), !peavQueue.isEmpty else { return }
        let sounds = Array(peavQueue.suffix(Self.peavBatchSize).reversed())
        peavQueue.removeLast(sounds.count)
        let folder = peavFolder
        let jobs = sounds.compactMap { s in s.id.map { (id: $0, url: s.url, fingerprint: s.fingerprint) } }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let result = PeavBatch.run(jobs, folder: folder) else { return }   // cancelled
            await self?.finishedPeav(result)
        }
        peavBatch = (task, sounds)
    }

    private func finishedPeav(_ result: PeavBatch.Result) {
        guard peavBatch != nil else { return }   // cancelled meanwhile
        peavBatch = nil
        defer {
            save()
            fill()
        }
        if let problem = result.modelProblem {
            peavUnavailable = problem
            rebuildQueue()
            return
        }
        for e in result.embeddings {
            // A read error because the drive went away isn't the file's fault: analyse it next time.
            if e.error != nil, let s = model?.sound(id: e.soundId), !(model?.isOnline(libraryId: s.libraryId) ?? false) { continue }
            peavStatus[e.soundId] = .init(fingerprint: e.fingerprint, version: e.version)
            unsavedEmbeddings.append(e)
        }
    }

    private func finished(_ result: SoundAnalyzer.Result) {
        guard running.removeValue(forKey: result.soundId) != nil else { return }   // cancelled meanwhile
        defer {
            if unsavedFacts.count + unsavedEmbeddings.count >= 50 { save() }
            fill()
        }
        if let problem = result.modelProblem {
            // The model, not the sound: stop CLAP for now and say why.
            clapUnavailable = problem
            rebuildQueue()
        }
        // A read error because the drive went away isn't the file's fault: analyse it next time.
        let failed = result.facts?.error != nil || result.embedding?.error != nil
        if failed, let s = model?.sound(id: result.soundId), !(model?.isOnline(libraryId: s.libraryId) ?? false) { return }
        if let f = result.facts {
            facts[result.soundId] = f
            unsavedFacts.append(f)
        }
        if let e = result.embedding {
            clapStatus[result.soundId] = .init(fingerprint: e.fingerprint, version: e.version)
            unsavedEmbeddings.append(e)
        }
    }

    private func save() {
        guard let db = model?.database, !unsavedFacts.isEmpty || !unsavedEmbeddings.isEmpty else { return }
        let f = unsavedFacts, e = unsavedEmbeddings
        unsavedFacts = []
        unsavedEmbeddings = []
        Task.detached(priority: .utility) {
            try? db.save(f)
            try? db.save(e)
        }
    }

    private func updateActivity() {
        let working = !running.isEmpty || peavBatch != nil
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
        running.values.forEach { $0.task.cancel() }
        running = [:]
        peavBatch?.task.cancel()
        peavBatch = nil
        save()
    }
}

/// Runs PE-AV over a batch of sounds, off the main thread: decodes each file
/// (read-only) to Phase 0's windows, then runs the five parts one at a time
/// over all windows on the GPU.
enum PeavBatch {
    struct Result: Sendable {
        var embeddings: [SoundEmbedding] = []
        /// Set when the model itself couldn't be prepared or loaded (not the sounds' fault).
        var modelProblem: String?
    }

    /// nil when cancelled (the sounds stay in the queue).
    static func run(_ jobs: [(id: Int64, url: URL, fingerprint: String?)], folder: URL) -> Result? {
        var result = Result()
        let embedder: PeavEmbedder
        do {
            for part in PeavEmbedder.parts {
                let package = folder.appendingPathComponent("\(part).mlpackage")
                if FileManager.default.fileExists(atPath: package.path) { try CompiledModel.ensure(package: package) }
            }
            embedder = try PeavEmbedder(compiledIn: folder, computeUnits: .cpuAndGPU)
        } catch {
            result.modelProblem = error.localizedDescription
            return result
        }
        var windows: [[[Float]]] = []
        var ok: [(id: Int64, fingerprint: String?)] = []
        for job in jobs {
            if Task.isCancelled { return nil }
            do {
                let audio = try AudioDecoder.mono(url: job.url, sampleRate: Double(Phase0Audio.sampleRate),
                                                  maxSeconds: Phase0Audio.maxSeconds)
                windows.append(PeavEmbedder.windows(audio48k: audio))
                ok.append((job.id, job.fingerprint))
            } catch {
                result.embeddings.append(SoundEmbedding(soundId: job.id, model: PeavEmbedder.modelName, fingerprint: job.fingerprint,
                                                        vector: nil, error: error.localizedDescription))
            }
        }
        do {
            guard let vectors = try embedder.embed(filesWindows: windows, isCancelled: { Task.isCancelled }) else { return nil }
            for (job, vector) in zip(ok, vectors) {   // nil vector: silent or shorter than 20 ms
                result.embeddings.append(SoundEmbedding(soundId: job.id, model: PeavEmbedder.modelName,
                                                        fingerprint: job.fingerprint, vector: vector))
            }
        } catch {
            result.modelProblem = error.localizedDescription
        }
        return result
    }
}

/// Analyses one sound. Runs off the main thread; opens the file read-only.
enum SoundAnalyzer {
    struct Result: Sendable {
        var soundId: Int64
        var facts: SoundFacts?
        var embedding: SoundEmbedding?
        /// Set when the CLAP model itself couldn't be loaded (not this sound's fault).
        var modelProblem: String?
    }

    /// nil when cancelled (the sound stays in the queue).
    static func run(soundId: Int64, url: URL, fingerprint: String?, stages: Set<AnalysisStage>,
                    clap: ClapModelStore) -> Result? {
        var result = Result(soundId: soundId)
        if stages.contains(.loudness) {
            guard let f = facts(soundId: soundId, url: url, fingerprint: fingerprint) else { return nil }
            result.facts = f
        }
        if stages.contains(.clap) {
            if Task.isCancelled { return nil }
            let embedder: ClapEmbedder
            do {
                embedder = try clap.get()
            } catch {
                result.modelProblem = error.localizedDescription
                return result
            }
            do {
                // Phase 0's audio path: mono, 48 kHz, at most the first 10 minutes.
                let audio = try AudioDecoder.mono(url: url, sampleRate: Double(Phase0Audio.sampleRate), maxSeconds: Phase0Audio.maxSeconds)
                if Task.isCancelled { return nil }
                let vector = try embedder.embed(audio48k: audio)   // nil: silent or shorter than 20 ms
                result.embedding = SoundEmbedding(soundId: soundId, model: ClapEmbedder.modelName, fingerprint: fingerprint, vector: vector)
            } catch {
                result.embedding = SoundEmbedding(soundId: soundId, model: ClapEmbedder.modelName, fingerprint: fingerprint,
                                                  vector: nil, error: error.localizedDescription)
            }
        }
        return result
    }

    /// Loudness and peak; nil when cancelled.
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

/// One CSV line per scheduler tick (every 5 s), so a night's decisions can be
/// checked and the thresholds tuned. Kept for the last 7 days; one file per day.
@MainActor
final class SchedulerLog {
    private let folder: URL
    private var handle: FileHandle?
    private var day = ""
    // Local time, so the log reads like the clock on the wall.
    private static let dayFormat = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let timeFormat = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-7 * 86400)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.lastPathComponent.hasPrefix("scheduler-") || url.lastPathComponent.hasPrefix("analysis-") {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func record(_ s: SystemSignals, ownGPU: Double, mode: AnalysisGovernor.Mode, pace: AnalysisPace,
                remaining: Int, running: Int, measured: Int) {
        let now = Date()
        let today = Self.dayFormat.string(from: now)
        if today != day { open(today) }
        let time = Self.timeFormat.string(from: now)
        let line = [time, String(format: "%.0f", s.userIdle), String(format: "%.2f", s.otherCPU),
                    String(format: "%.2f", s.gpu), String(format: "%.2f", ownGPU), "\(s.thermal)", "\(s.onBattery)", "\(s.lowPowerMode)",
                    mode.rawValue, "\(pace.workers)", "\(pace.reason)", "\(running)", "\(remaining)", "\(measured)"]
            .joined(separator: ",") + "\n"
        handle?.write(Data(line.utf8))
    }

    private func open(_ today: String) {
        try? handle?.close()
        day = today
        let url = folder.appendingPathComponent("analysis-\(today).csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "time,idle_s,other_cpu,other_gpu,own_gpu,thermal,battery,low_power,mode,workers,reason,running,queued,measured\n"
            FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}
