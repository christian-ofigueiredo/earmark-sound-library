import AVFoundation
import CoreML
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
    /// Songs, not sounds: tempo and key, one song at a time (see AnalysisEngine.fillSongs()).
    case tempoKey

    var title: String {
        switch self {
        case .loudness: "loudness"
        case .clap: "CLAP embeddings"
        case .peav: "PE-AV embeddings"
        case .tempoKey: "tempo and key"
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
    /// Work left (sound × stage) at recent ticks while analysis ran, for the time estimate.
    private var history: [(time: Date, left: Int)] = []
    /// Why CLAP isn't running, if it can't (model missing or failed to load).
    private(set) var clapUnavailable: String?
    private(set) var peavStatus: [Int64: SoundEmbedding.Status] = [:]
    /// Why PE-AV isn't running, if it can't ("not installed", or the last model error).
    private(set) var peavUnavailable: String?
    /// After a model error (not a missing model), PE-AV is tried again from this time.
    private var peavRetryAt: Date?
    /// Why tempo and key analysis isn't running, if it can't ("model not installed", or the last model error).
    private(set) var musicUnavailable: String?
    private var musicRetryAt: Date?

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
    /// Tempo and key: ~/Library/Application Support/Earmark/Models/BeatThis.mlpackage and SKey.mlpackage.
    let musicModels = MusicModelStore(folder: AppModel.supportFolder.appendingPathComponent("Models", isDirectory: true))
    /// Sounds per PE-AV batch: each of the five parts (1.1 GB) is loaded once per batch,
    /// so bigger batches spend less time loading. Capped by audio held too (PeavBatch).
    static let peavBatchSize = 256

    private weak var model: AppModel?
    private var governor: AnalysisGovernor
    private let monitor = SystemMonitor()
    private let log = SchedulerLog(folder: AppModel.supportFolder.appendingPathComponent("Logs", isDirectory: true))
    private var queue: [(sound: SoundRecord, stages: Set<AnalysisStage>)] = []
    private var running: [Int64: (task: Task<Void, Never>, sound: SoundRecord, stages: Set<AnalysisStage>)] = [:]
    private var peavQueue: [SoundRecord] = []
    private var peavBatch: (task: Task<Void, Never>, sounds: [SoundRecord])?
    /// The batch after it, being decoded while the current one runs on the GPU.
    private var peavNext: (task: Task<PeavBatch.Prepared?, Never>, sounds: [SoundRecord])?
    /// A PE-AV batch ran at some point since the last tick (it may have finished in between).
    private var peavRanSinceTick = false
    /// Songs without tempo and key from Phase 0 or Earmark, analysed one at a time.
    private var songQueue: [SongRecord] = []
    private var songJob: (task: Task<Void, Never>, song: SongRecord, units: MLComputeUnits)?
    /// Songs analysed this session (they may not be saved yet), so they aren't queued again.
    private var analysedSongs: Set<Int64> = []
    /// Songs that couldn't be read this session, and why: tried again after a relaunch.
    private(set) var unreadableSongs: [Int64: String] = [:]
    private var unsavedSongs: [(songId: Int64, analysis: SongAnalysis)] = []
    private var unsavedFacts: [SoundFacts] = []
    private var unsavedEmbeddings: [SoundEmbedding] = []
    private var loop: Task<Void, Never>?
    /// Keeps App Nap from throttling analysis while it runs (idle sleep is still allowed).
    private var activity: NSObjectProtocol?
    /// Embeddings that came in since the groups were last brought up to date, and when that was.
    private var embeddedSinceGrouping = 0
    private var groupedAt = Date()

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

    /// After an import: what's done is read again from the database, so it isn't analysed again.
    func reloadStatus() {
        guard let db = model?.database else { return }
        facts = (try? db.soundFacts()) ?? facts
        clapStatus = (try? db.embeddingStatus(model: ClapEmbedder.modelName)) ?? clapStatus
        peavStatus = (try? db.embeddingStatus(model: PeavEmbedder.modelName)) ?? peavStatus
        rebuildQueue()
    }

    /// A line in Logs/errors.log (the grouping's too).
    func note(_ message: String) { log.error(message) }

    /// Call after the library changes (scan, library added or removed).
    func libraryChanged() {
        rebuildQueue()
        fill()
    }

    /// Stages that can run (their models are installed).
    private var activeStages: [AnalysisStage] {
        AnalysisStage.allCases.filter { stage in
            switch stage {
            case .loudness: true
            case .clap: clapUnavailable != "model not installed"
            case .peav: peavUnavailable != "model not installed"
            case .tempoKey: musicUnavailable != "model not installed"
            }
        }
    }

    /// Share done (0…1) of each stage that isn't finished, in stage order.
    var stageProgress: [(stage: AnalysisStage, done: Double)] {
        let sounds = max(1, model?.soundIndex.shownCount ?? 0), songs = max(1, model?.songs.count ?? 0)
        return activeStages.compactMap { stage in
            let total = stage == .tempoKey ? songs : sounds
            let left = remainingByStage[stage] ?? 0
            return left > 0 ? (stage, max(0, 1 - Double(left) / Double(total))) : nil
        }
    }

    /// The least finished stage's share done, for the status bar's progress bar.
    var progress: Double? { stageProgress.map(\.done).min() }

    /// Estimated time to finish everything, from the speed between batch completions in the
    /// last 20 minutes of work (needs two completions after the first).
    var timeLeft: TimeInterval? {
        guard history.count >= 3, let first = history.first, let last = history.last,
              first.left > last.left else { return nil }
        let rate = Double(first.left - last.left) / last.time.timeIntervalSince(first.time)
        return Double(last.left) / rate
    }

    static func describe(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "about \(minutes) min" }
        let h = minutes / 60, m = (minutes % 60) / 10 * 10
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }

    var statusText: String {
        let sounds = remaining + inProgress, songs = remainingByStage[.tempoKey] ?? 0
        let left = sounds + songs
        let problems = [clapUnavailable.map { "CLAP \($0)" }, peavUnavailable.map { "PE-AV \($0)" },
                        musicUnavailable.map { "tempo and key \($0)" }].compactMap { $0 }
        let missingModel = problems.isEmpty ? "" : " · " + problems.joined(separator: " · ")
        guard left > 0 else { return facts.isEmpty ? "" : "Analysis up to date" + missingModel }
        let count = [sounds > 0 ? "\(sounds.formatted()) sound\(sounds == 1 ? "" : "s")" : nil,
                     songs > 0 ? "\(songs.formatted()) song\(songs == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " and ") + " to analyse"
        let doing = stageProgress.map { "\($0.stage.title) \(Int(($0.done * 100).rounded(.down)))%" }.joined(separator: ", ")
        let eta = !pace.isPaused ? timeLeft.map { " · \(Self.describe($0)) left" } ?? "" : ""
        let what = (doing.isEmpty ? count : "\(count) (\(doing))") + eta
        // Only PE-AV left, and the Mac isn't idle: say what it's waiting for.
        if stageProgress.map(\.stage) == [.peav], !Self.gpuAllowed(pace), !pace.isPaused {
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
        clapUnavailable = clapModels.isInstalled ? nil : "model not installed"
        if !peavInstalled {
            peavUnavailable = "model not installed"
        } else if peavRetryAt.map({ Date() >= $0 }) ?? true {
            peavUnavailable = nil
            peavRetryAt = nil
        }
        let hidden = model.soundIndex.twins.hidden
        let online = Set(model.soundLibraries.filter(\.isOnline).compactMap(\.id))   // one disk check per library
        // Reversed so popLast() works through the library in list order.
        queue = model.sounds.reversed().compactMap { s in
            guard let id = s.id, !hidden.contains(id), running[id] == nil, online.contains(s.libraryId) else { return nil }
            let needed = stages(for: s)
            return needed.isEmpty ? nil : (s, needed)
        }
        let inBatch = Set(((peavBatch?.sounds ?? []) + (peavNext?.sounds ?? [])).compactMap(\.id))
        let pending = model.sounds.filter { s in
            guard let id = s.id, !hidden.contains(id), !inBatch.contains(id), online.contains(s.libraryId) else { return false }
            return needsPeav(s)
        }
        // Mix long sounds (full 10 s windows, run on the GPU) with short ones (run on the CPU)
        // in every batch, so both work at the same time; in folder order, packs of one kind
        // came together and left the other idle. Reversed so popLast() takes the front.
        peavQueue = Self.interleaved(pending.filter { ($0.duration ?? 0) >= 10 },
                                     pending.filter { ($0.duration ?? 0) < 10 }).reversed()
        // Songs with no tempo and key from anyone yet (Phase 0's are never redone).
        let songsLeft = model.songs.filter { s in
            guard let id = s.id else { return false }
            return !s.isAnalysed && !analysedSongs.contains(id) && unreadableSongs[id] == nil
        }
        if !musicModels.isInstalled {
            musicUnavailable = songsLeft.isEmpty ? nil : "model not installed"
        } else if musicRetryAt.map({ Date() >= $0 }) ?? true {
            musicUnavailable = nil
            musicRetryAt = nil
        }
        let musicOnline = Set(model.musicLibraries.filter(\.isOnline).compactMap(\.id))
        // Reversed so popLast() works through them in list order.
        songQueue = musicUnavailable != nil ? [] : songsLeft.reversed().filter { s in
            musicOnline.contains(s.libraryId) && s.id != songJob?.song.id
        }
        countRemaining()
    }

    /// `a` and `b` merged in proportion, keeping each one's order (1 of `a` per `b.count / a.count`).
    static func interleaved<T>(_ a: [T], _ b: [T]) -> [T] {
        guard !a.isEmpty, !b.isEmpty else { return a + b }
        var out: [T] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            // Take from whichever list is further behind its share.
            if j >= b.count || (i < a.count && Double(i) / Double(a.count) <= Double(j) / Double(b.count)) {
                out.append(a[i]); i += 1
            } else {
                out.append(b[j]); j += 1
            }
        }
        return out
    }

    private func countRemaining() {
        // Distinct sounds with any stage left; the PE-AV lane has its own queue.
        var waiting = Set(queue.compactMap(\.sound.id))
        waiting.formUnion(peavQueue.compactMap(\.id))
        var busy = Set(running.keys)
        busy.formUnion(peavBatch?.sounds.compactMap(\.id) ?? [])
        waiting.formUnion(peavNext?.sounds.compactMap(\.id) ?? [])
        remaining = waiting.subtracting(busy).count
        inProgress = busy.count
        var byStage: [AnalysisStage: Int] = [:]
        for job in queue { for stage in job.stages { byStage[stage, default: 0] += 1 } }
        for job in running.values { for stage in job.stages { byStage[stage, default: 0] += 1 } }
        byStage[.peav] = peavQueue.count + (peavBatch?.sounds.count ?? 0) + (peavNext?.sounds.count ?? 0)
        byStage[.tempoKey] = songQueue.count + (songJob != nil ? 1 : 0)
        remainingByStage = byStage.filter { $0.value > 0 }
    }

    private func tick() {
        if [peavRetryAt, musicRetryAt].contains(where: { $0.map { Date() >= $0 } ?? false }) { rebuildQueue() }
        // Newly analysed sounds join the similarity groups every few minutes (once saved).
        if embeddedSinceGrouping > 0, Date().timeIntervalSince(groupedAt) > 180, let model {
            embeddedSinceGrouping = 0
            groupedAt = Date()
            model.soundGuesser.update(model: model)
            model.groupBuilder.update(model: model)
        }
        // A PE-AV batch running since the last tick means Earmark itself used the GPU.
        let signals = monitor.sample(ownGPUWork: peavBatch != nil || peavRanSinceTick)
        peavRanSinceTick = peavBatch != nil
        pace = governor.update(signals)
        // Speed for the time estimate: only while analysis runs (a pause would skew it).
        let left = remainingByStage.values.reduce(0, +)
        // Work finishes in batches, so measure from one completion to the next (sampling
        // every tick made the estimate climb between batches).
        if pace.isPaused {
            history = []
        } else if history.last?.left != left {
            history.append((Date(), left))
            history.removeAll { Date().timeIntervalSince($0.time) > 20 * 60 }
        }
        log.record(signals, totalGPU: monitor.totalGPU, peav: peavBatch != nil, mode: mode, pace: pace, remaining: remaining,
                   running: running.count + (peavBatch?.sounds.count ?? 0), measured: facts.count)
        // The Mac isn't idle any more: stop the PE-AV batch (it uses the GPU); it goes back in the queue.
        if !Self.gpuAllowed(pace) {
            if let next = peavNext {
                next.task.cancel()
                peavNext = nil
                peavQueue.append(contentsOf: next.sounds.reversed())
            }
            if let batch = peavBatch {
                batch.task.cancel()
                peavBatch = nil
                peavQueue.append(contentsOf: batch.sounds.reversed())
            }
        }
        // A song running with the GPU when the Mac is no longer idle, or with no worker left:
        // stop it; it starts again (on the CPU) when there's room.
        if let job = songJob, pace.workers == 0 || (job.units != .cpuOnly && !Self.gpuAllowed(pace)) {
            job.task.cancel()
            songJob = nil
            songQueue.append(job.song)
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
        if musicModels.isLoaded, songJob == nil, pace.isPaused || songQueue.isEmpty { musicModels.unload() }
        updateActivity()
    }

    /// Per-sound workers: the PE-AV batch and the song being analysed, while they run, each take
    /// one of the pace's slots.
    private var cpuWorkers: Int { max(0, pace.workers - (peavBatch != nil ? 1 : 0) - (songJob != nil ? 1 : 0)) }

    private func fill() {
        fillPeav()
        fillSongs()
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

    /// Starts the next song's tempo and key when a worker is free (songs before sounds: there
    /// are fewer, and each takes a few seconds): on the CPU at low priority while you use the
    /// Mac, with the GPU too while it's idle.
    private func fillSongs() {
        guard songJob == nil, musicUnavailable == nil, pace.workers - (peavBatch != nil ? 1 : 0) > 0,
              let song = songQueue.popLast(), let id = song.id else { return }
        let units: MLComputeUnits = Self.gpuAllowed(pace) ? .all : .cpuOnly
        let priority: TaskPriority = pace.reason == .userActive ? .background : .utility
        let models = musicModels, url = song.url
        let task = Task.detached(priority: priority) { [weak self] in
            guard let result = SongAnalyzer.run(songId: id, url: url, models: models, units: units) else { return }
            await self?.finishedSong(result)
        }
        songJob = (task, song, units)
    }

    /// Starts the next PE-AV batch when the Mac is idle and none is running, and has the
    /// one after it decoded meanwhile, so the GPU doesn't wait for files to be read.
    private func fillPeav() {
        guard Self.gpuAllowed(pace) else { return }
        if peavBatch == nil {
            let prepared: Task<PeavBatch.Prepared?, Never>, sounds: [SoundRecord]
            if let next = peavNext {
                (prepared, sounds) = next
                peavNext = nil
            } else if let started = startPreparing() {
                (prepared, sounds) = started
            } else {
                return
            }
            let folder = peavFolder
            let task = Task.detached(priority: .utility) { [weak self] in
                guard let batch = await prepared.value else { return }   // cancelled
                let flag = CancellationFlag()
                let result = await withTaskCancellationHandler {
                    PeavBatch.embed(batch, folder: folder, cancelled: flag)
                } onCancel: {
                    flag.set()
                }
                guard let result else { return }   // cancelled
                await self?.finishedPeav(result)
            }
            peavBatch = (task, sounds)
            peavRanSinceTick = true
        }
        if peavNext == nil, let next = startPreparing() { peavNext = next }
    }

    /// Takes the next sounds off the PE-AV queue and starts decoding them in the background.
    private func startPreparing() -> (task: Task<PeavBatch.Prepared?, Never>, sounds: [SoundRecord])? {
        guard !peavQueue.isEmpty else { return nil }
        let sounds = Array(peavQueue.suffix(Self.peavBatchSize).reversed())
        peavQueue.removeLast(sounds.count)
        let jobs = sounds.compactMap { s in s.id.map { PeavBatch.Job(id: $0, url: s.url, fingerprint: s.fingerprint) } }
        let task = Task.detached(priority: .utility) {
            let flag = CancellationFlag()
            return await withTaskCancellationHandler {
                PeavBatch.prepare(jobs, cancelled: flag)
            } onCancel: {
                flag.set()
            }
        }
        return (task, sounds)
    }

    private func finishedPeav(_ result: PeavBatch.Result) {
        guard peavBatch != nil else { return }   // cancelled meanwhile
        peavBatch = nil
        defer {
            save()
            fill()
        }
        if let problem = result.modelProblem {
            // Often temporary (e.g. GPU memory): wait, then try again, rather than stopping for good.
            log.error("PE-AV: \(problem)")
            peavUnavailable = "paused after an error, retrying in 10 min: \(problem.prefix(80))"
            peavRetryAt = Date().addingTimeInterval(600)
            rebuildQueue()
            return
        }
        if !result.timing.isEmpty { log.error("PE-AV batch: \(result.timing)") }
        if !result.fallbacks.isEmpty {
            log.error("PE-AV: \(result.fallbacks.count) window(s) ran on the CPU after the GPU failed them: "
                      + result.fallbacks.prefix(20).joined(separator: ", "))
        }
        for e in result.embeddings where e.error != nil { log.error("PE-AV sound \(e.soundId): \(e.error!)") }
        // Sounds the batch didn't get to (window cap): next in line.
        if let sounds = model.map({ m in result.notStarted.compactMap { m.sound(id: $0) } }), !sounds.isEmpty {
            peavQueue.append(contentsOf: sounds.reversed())
        }
        for e in result.embeddings {
            // A read error because the drive went away isn't the file's fault: analyse it next time.
            if e.error != nil, let s = model?.sound(id: e.soundId), !(model?.isOnline(libraryId: s.libraryId) ?? false) { continue }
            peavStatus[e.soundId] = .init(fingerprint: e.fingerprint, version: e.version)
            unsavedEmbeddings.append(e)
            embeddedSinceGrouping += 1
        }
    }

    private func finishedSong(_ result: SongAnalyzer.Result) {
        guard let job = songJob, job.song.id == result.songId else { return }   // cancelled meanwhile
        songJob = nil
        defer {
            if unsavedSongs.count >= 5 { save() }
            fill()
        }
        if let problem = result.modelProblem {
            // Often temporary: wait, then try again, rather than stopping for good.
            log.error("Tempo and key: \(problem)")
            musicUnavailable = "paused after an error, retrying in 10 min: \(problem.prefix(80))"
            musicRetryAt = Date().addingTimeInterval(600)
            rebuildQueue()
            return
        }
        if let error = result.error {
            // A read error because the drive went away isn't the file's fault: analyse it next time.
            guard model?.isOnline(libraryId: job.song.libraryId) ?? false else { return }
            log.error("Tempo and key, \(job.song.path): \(error)")
            unreadableSongs[result.songId] = error
            return
        }
        if let analysis = result.analysis {
            analysedSongs.insert(result.songId)
            unsavedSongs.append((result.songId, analysis))
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
            log.error("CLAP: \(problem)")
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
            embeddedSinceGrouping += 1
        }
    }

    private func save() {
        saveSongs()
        guard let db = model?.database, !unsavedFacts.isEmpty || !unsavedEmbeddings.isEmpty else { return }
        let f = unsavedFacts, e = unsavedEmbeddings
        unsavedFacts = []
        unsavedEmbeddings = []
        Task.detached(priority: .utility) {
            try? db.save(f)
            try? db.save(e)
        }
    }

    /// Stores the songs' tempo and key, then shows them (the song list, detail pane and count).
    private func saveSongs() {
        guard let db = model?.database, !unsavedSongs.isEmpty else { return }
        let results = unsavedSongs
        unsavedSongs = []
        Task { [weak self] in
            let updated = (try? await Task.detached(priority: .utility) { try db.saveSongAnalysis(results) }.value) ?? []
            self?.model?.updateSongs(updated)
        }
    }

    private func updateActivity() {
        let working = !running.isEmpty || peavBatch != nil || songJob != nil
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
        peavNext?.task.cancel()
        peavNext = nil
        songJob?.task.cancel()
        songJob = nil
        save()
    }
}

/// Runs PE-AV over a batch of sounds, off the main thread: decodes each file
/// (read-only) to Phase 0's windows, then runs the five parts one at a time
/// over all windows on the GPU.
enum PeavBatch {
    struct Job: Sendable {
        var id: Int64
        var url: URL
        var fingerprint: String?
    }

    /// A batch decoded to Phase 0's windows, ready for the model.
    struct Prepared: Sendable {
        var windows: [[[Float]]] = []
        var jobs: [Job] = []
        /// Files that couldn't be read (stored as errors).
        var unreadable: [SoundEmbedding] = []
        /// Sounds left for the next batch because this one reached its window cap.
        var notStarted: [Int64] = []
        var decodeSeconds = 0.0
        var windowCount: Int { windows.reduce(0) { $0 + $1.count } }
        var sampleCount: Int { windows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } }
    }

    struct Result: Sendable {
        var embeddings: [SoundEmbedding] = []
        var notStarted: [Int64] = []
        /// Windows the GPU couldn't compute and the CPU did ("part length").
        var fallbacks: [String] = []
        /// Where the batch spent its time, for the log.
        var timing = ""
        /// Set when the model itself couldn't be prepared or loaded (not the sounds' fault).
        var modelProblem: String?
    }

    /// At most this much audio per batch (as many samples as 256 full windows): the decoded
    /// windows, and their states between parts, are held in memory.
    static let maxSamples = 256 * Phase0Audio.windowSamples

    /// Decodes the files (read-only) to Phase 0's windows; nil when cancelled.
    static func prepare(_ jobs: [Job], cancelled: CancellationFlag) -> Prepared? {
        var out = Prepared()
        let started = Date()
        for (index, job) in jobs.enumerated() {
            if cancelled.isSet { return nil }
            if out.sampleCount >= maxSamples {
                out.notStarted = jobs[index...].map(\.id)
                break
            }
            do {
                let audio = try AudioDecoder.mono(url: job.url, sampleRate: Double(Phase0Audio.sampleRate),
                                                  maxSeconds: Phase0Audio.maxSeconds)
                out.windows.append(PeavEmbedder.windows(audio48k: audio))
                out.jobs.append(job)
            } catch {
                out.unreadable.append(SoundEmbedding(soundId: job.id, model: PeavEmbedder.modelName, fingerprint: job.fingerprint,
                                                     vector: nil, error: error.localizedDescription))
            }
        }
        out.decodeSeconds = Date().timeIntervalSince(started)
        return out
    }

    /// Runs the five parts over a prepared batch (full windows on the GPU, short ones on the
    /// CPU, side by side); nil when cancelled.
    static func embed(_ batch: Prepared, folder: URL, cancelled: CancellationFlag) -> Result? {
        var result = Result(embeddings: batch.unreadable, notStarted: batch.notStarted)
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
        let started = Date()
        do {
            guard let outcomes = try embedder.embed(filesWindows: batch.windows, isCancelled: { cancelled.isSet }) else { return nil }
            result.fallbacks = embedder.lastFallbacks
            let t = embedder.lastTimings
            let full = batch.windows.joined().filter { $0.count == Phase0Audio.windowSamples }.count
            result.timing = String(format: "%d sounds, %d windows (%d full): decoded ahead %.0f s; load %.0f s, gpu %.0f s, cpu %.0f s (side by side), parts %.0f s, total %.0f s",
                                   batch.jobs.count, batch.windowCount, full, batch.decodeSeconds, t["load"] ?? 0,
                                   t["gpu"] ?? 0, t["cpu"] ?? 0, t["part"] ?? 0, Date().timeIntervalSince(started))
            for (job, outcome) in zip(batch.jobs, outcomes) {
                let vector: [Float]?, error: String?
                switch outcome {
                case .vector(let v): (vector, error) = (v, nil)
                case .silent: (vector, error) = (nil, nil)
                case .failed(let why): (vector, error) = (nil, why)
                }
                result.embeddings.append(SoundEmbedding(soundId: job.id, model: PeavEmbedder.modelName,
                                                        fingerprint: job.fingerprint, vector: vector, error: error))
            }
        } catch {
            result.modelProblem = error.localizedDescription
        }
        return result
    }
}

/// Works out one song's tempo and key. Runs off the main thread; opens the file read-only.
enum SongAnalyzer {
    struct Result: Sendable {
        var songId: Int64
        var analysis: SongAnalysis?
        /// The file couldn't be read or analysed.
        var error: String?
        /// Set when the models themselves couldn't be loaded (not this song's fault).
        var modelProblem: String?
    }

    /// nil when cancelled (the song stays in the queue).
    static func run(songId: Int64, url: URL, models: MusicModelStore, units: MLComputeUnits) -> Result? {
        let analyzer: MusicAnalyzer
        do {
            analyzer = try models.get(units)
        } catch {
            return Result(songId: songId, modelProblem: error.localizedDescription)
        }
        do {
            let audio = try MusicAnalyzer.decode(url: url)
            if Task.isCancelled { return nil }
            guard let found = try analyzer.analyse(audio22k: audio, isCancelled: { Task.isCancelled }) else {
                if Task.isCancelled { return nil }
                // Silent or shorter than 2 s: nothing to find, and nothing to try again.
                return Result(songId: songId, analysis: SongAnalysis(source: SongAnalysis.earmarkSource))
            }
            return Result(songId: songId, analysis: SongAnalysis(tempo: found.tempo, key: found.key))
        } catch {
            return Result(songId: songId, error: error.localizedDescription)
        }
    }
}

/// Set once when a task is cancelled; readable from any thread (the PE-AV work runs on
/// Dispatch threads, where Task.isCancelled doesn't see the task).
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
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
        where ["scheduler-", "analysis-", "analysis2-"].contains(where: url.lastPathComponent.hasPrefix) {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func record(_ s: SystemSignals, totalGPU: Double, peav: Bool, mode: AnalysisGovernor.Mode, pace: AnalysisPace,
                remaining: Int, running: Int, measured: Int) {
        let now = Date()
        let today = Self.dayFormat.string(from: now)
        if today != day { open(today) }
        let time = Self.timeFormat.string(from: now)
        let line = [time, String(format: "%.0f", s.userIdle), String(format: "%.2f", s.otherCPU),
                    String(format: "%.2f", s.gpu), String(format: "%.2f", totalGPU), "\(peav)", "\(s.thermal)", "\(s.onBattery)", "\(s.lowPowerMode)",
                    mode.rawValue, "\(pace.workers)", "\(pace.reason)", "\(running)", "\(remaining)", "\(measured)"]
            .joined(separator: ",") + "\n"
        handle?.write(Data(line.utf8))
    }

    /// Appends to Logs/errors.log (model errors, which would otherwise only show briefly).
    func error(_ message: String) {
        let url = folder.appendingPathComponent("errors.log")
        let line = "\(Self.dayFormat.string(from: Date())) \(Self.timeFormat.string(from: Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8))
        }
    }

    private func open(_ today: String) {
        try? handle?.close()
        day = today
        let url = folder.appendingPathComponent("analysis2-\(today).csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "time,idle_s,other_cpu,other_gpu,total_gpu,peav_running,thermal,battery,low_power,mode,workers,reason,running,queued,measured\n"
            FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}
