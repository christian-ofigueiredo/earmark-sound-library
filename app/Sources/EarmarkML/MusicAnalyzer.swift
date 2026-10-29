import CoreML
import EarmarkCore
import Foundation

/// Tempo and key with Core ML, worked out as Phase 0 did: Beat This! (final0) over 30 s chunks
/// of the song's log-mel spectrogram, then Phase 0's tempo summary; S-KEY over the whole song,
/// peak-normalised. Takes the song's first 20 minutes, mono 22.05 kHz (models/convert_music.py).
public final class MusicAnalyzer: @unchecked Sendable {
    public static let packages = ["BeatThis.mlpackage", "SKey.mlpackage"]
    private let beat: MLModel, key: MLModel
    /// Workers share the models; predictions are serialised to be safe.
    private let lock = NSLock()

    public struct Result: Sendable {
        public var tempo: BeatTracking.Summary
        public var key: KeyDetection.Estimate?
        public var seconds: Double
        /// Where the time went (seconds): "spectrogram", "beats", "key".
        public var timings: [String: Double]
    }

    /// `folder` holds the two packages (compiled beside them the first time).
    public init(folder: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let urls = try Self.packages.map { name -> URL in
            let package = folder.appendingPathComponent(name)
            let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
            guard FileManager.default.fileExists(atPath: package.path) || FileManager.default.fileExists(atPath: compiled.path)
            else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: package.path]) }
            return try CompiledModel.ensure(package: package)
        }
        beat = try MLModel(contentsOf: urls[0], configuration: config)
        key = try MLModel(contentsOf: urls[1], configuration: config)
    }

    /// A song decoded as Phase 0 did it: mono, the first 20 minutes, at 44.1 kHz, then halved
    /// with a filter shaped like Phase 0's (`HalfRate`). The file is only read.
    public static func decode(url: URL) throws -> [Float] {
        HalfRate.decimate(try AudioDecoder.mono(url: url, sampleRate: 44_100, maxSeconds: BeatThisAudio.maxSeconds))
    }

    /// nil for audio shorter than 2 s or silent (Phase 0 skipped those), or when `isCancelled` says so
    /// (checked between chunks).
    public func analyse(audio22k audio: [Float], isCancelled: () -> Bool = { false }) throws -> Result? {
        let sr = BeatThisAudio.sampleRate
        let x = audio.count > Int(BeatThisAudio.maxSeconds) * sr ? Array(audio.prefix(Int(BeatThisAudio.maxSeconds) * sr)) : audio
        guard x.count >= 2 * sr, let peak = x.lazy.map(abs).max(), peak >= 1e-5 else { return nil }
        var timings: [String: Double] = [:]
        var clock = Date()
        func lap(_ name: String) { timings[name] = Date().timeIntervalSince(clock); clock = Date() }

        let spect = BeatThisAudio.spectrogram(x)
        let frames = BeatThisAudio.frameCount(samples: x.count)
        lap("spectrogram")
        let starts = BeatThisAudio.chunkStarts(frames: frames)
        var beatOut: [[Float]] = [], downbeatOut: [[Float]] = []
        for start in starts {
            if isCancelled() { return nil }
            let (b, d) = try logits(BeatThisAudio.chunk(spect, frames: frames, start: start))
            beatOut.append(b)
            downbeatOut.append(d)
        }
        let beatLogits = BeatThisAudio.aggregate(beatOut, starts: starts, frames: frames)
        let downbeatLogits = BeatThisAudio.aggregate(downbeatOut, starts: starts, frames: frames)
        let peaks = BeatTracking.peaks(beatLogits: beatLogits, downbeatLogits: downbeatLogits)
        let tempo = BeatTracking.summarize(beats: peaks.beats, downbeats: peaks.downbeats,
                                           beatProbability: beatLogits.map(BeatTracking.sigmoid))
        lap("beats")
        if isCancelled() { return nil }
        let estimate = try KeyDetection.estimate(probabilities: keyProbabilities(x.map { $0 / peak }))
        lap("key")
        return Result(tempo: tempo, key: estimate, seconds: Double(x.count) / Double(sr), timings: timings)
    }

    /// Beat and downbeat logits for one chunk.
    public func logits(_ chunk: [Float]) throws -> ([Float], [Float]) {
        let input = try MLMultiArray(shape: [1, NSNumber(value: BeatThisAudio.chunk), NSNumber(value: BeatThisAudio.mels)],
                                     dataType: .float32)
        chunk.withUnsafeBufferPointer { src in
            input.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: src.count)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["spect": input])
        let output = try lock.withLock { try beat.prediction(from: provider) }
        guard let b = output.featureValue(for: "beat")?.multiArrayValue,
              let d = output.featureValue(for: "downbeat")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
        return (Self.floats(b), Self.floats(d))
    }

    /// S-KEY's 24 probabilities for the whole (peak-normalised) song.
    public func keyProbabilities(_ x: [Float]) throws -> [Float] {
        let input = try MLMultiArray(shape: [1, NSNumber(value: x.count)], dataType: .float32)
        x.withUnsafeBufferPointer { src in
            input.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: src.count)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
        let output = try lock.withLock { try key.prediction(from: provider) }
        guard let p = output.featureValue(for: "probs")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
        return Self.floats(p)
    }

    /// The values of a float32 output, in order (outputs here are (1, n), contiguous).
    static func floats(_ a: MLMultiArray) -> [Float] {
        if a.dataType == .float32, a.strides.last == 1 {
            return Array(UnsafeBufferPointer(start: a.dataPointer.assumingMemoryBound(to: Float.self), count: a.count))
        }
        return (0 ..< a.count).map { a[$0].floatValue }
    }
}

/// Finds, compiles (once) and loads the tempo and key models from a folder on demand, for the
/// compute units asked for, and lets go of them when analysis pauses.
public final class MusicModelStore: @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case notInstalled(URL)
        public var errorDescription: String? {
            switch self { case .notInstalled(let url): "the tempo and key models aren't installed (\(url.path))" }
        }
    }

    public let folder: URL
    private let lock = NSLock()
    private var loaded: (units: MLComputeUnits, analyzer: MusicAnalyzer)?

    public init(folder: URL) { self.folder = folder }

    public var isInstalled: Bool {
        MusicAnalyzer.packages.allSatisfy { name in
            let package = folder.appendingPathComponent(name)
            return ["mlpackage", "mlmodelc"].contains {
                FileManager.default.fileExists(atPath: package.deletingPathExtension().appendingPathExtension($0).path)
            }
        }
    }

    /// The models for these compute units; loads (and compiles the first time) if needed. Thread-safe.
    public func get(_ units: MLComputeUnits) throws -> MusicAnalyzer {
        try lock.withLock {
            if let loaded, loaded.units == units { return loaded.analyzer }
            loaded = nil
            guard isInstalled else { throw Failure.notInstalled(folder) }
            let analyzer = try MusicAnalyzer(folder: folder, computeUnits: units)
            loaded = (units, analyzer)
            return analyzer
        }
    }

    public func unload() { lock.withLock { loaded = nil } }

    public var isLoaded: Bool { lock.withLock { loaded != nil } }
}
