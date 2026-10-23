import CoreML
import EarmarkCore
import Foundation

/// LAION CLAP (larger_clap_general) audio embeddings with Core ML, the same
/// vectors Phase 0 made: one per ≤10 s window, averaged over up to six windows
/// and L2-normalised. Full precision runs on the CPU: half precision changed 0.6%
/// of nearest neighbours in the parity test (models/parity_clap.py), so it isn't used.
public final class ClapEmbedder: @unchecked Sendable {
    public static let dimensions = 512
    public static let modelName = "clap-general"
    private let model: MLModel
    /// Workers share one model (271 MB); predictions are serialised to be safe.
    private let lock = NSLock()

    /// `url`: the converted model (`CLAPAudio.mlpackage`, or an already compiled `.mlmodelc`).
    public init(modelAt url: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiled, configuration: config)
    }

    /// The file's vector from mono 48 kHz audio, or nil if it's silent or shorter than 20 ms.
    public func embed(audio48k x: [Float]) throws -> [Float]? {
        guard let prepared = ClapAudio.prepare(x) else { return nil }
        var sum = [Float](repeating: 0, count: Self.dimensions)
        for window in ClapAudio.windows(prepared) {
            let e = try embed(features: ClapAudio.features(window))
            for i in 0 ..< Self.dimensions { sum[i] += e[i] }
        }
        return Self.normalised(sum)
    }

    /// One window's (already normalised) vector from its log-mel features.
    public func embed(features: [Float]) throws -> [Float] {
        let input = try MLMultiArray(shape: [1, 1, NSNumber(value: ClapAudio.frames), NSNumber(value: ClapAudio.mels)],
                                     dataType: .float32)
        features.withUnsafeBufferPointer { src in
            input.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: src.count)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["melspec": input])
        let output = try lock.withLock { try model.prediction(from: provider) }
        guard let e = output.featureValue(for: "embedding")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
        return (0 ..< Self.dimensions).map { e[$0].floatValue }
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let norm = max(1e-12, v.reduce(0) { $0 + $1 * $1 }.squareRoot())
        return v.map { $0 / norm }
    }
}

/// Finds, compiles (once) and loads the CLAP model from a folder, on demand, and
/// lets go of it when analysis pauses so its memory goes back to other apps.
public final class ClapModelStore: @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case notInstalled(URL)
        public var errorDescription: String? {
            switch self { case .notInstalled(let url): "the CLAP model isn't installed (\(url.path))" }
        }
    }

    public let folder: URL
    private let lock = NSLock()
    private var embedder: ClapEmbedder?

    public init(folder: URL) { self.folder = folder }

    public var package: URL { folder.appendingPathComponent("CLAPAudio.mlpackage") }
    var compiled: URL { folder.appendingPathComponent("CLAPAudio.mlmodelc") }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: compiled.path) || FileManager.default.fileExists(atPath: package.path)
    }

    /// The loaded model; loads (and compiles the first time) if needed. Thread-safe.
    public func get() throws -> ClapEmbedder {
        try lock.withLock {
            if let embedder { return embedder }
            let fm = FileManager.default
            if fm.fileExists(atPath: package.path), !isCompiledCurrent {
                let temporary = try MLModel.compileModel(at: package)
                try? fm.removeItem(at: compiled)
                try fm.moveItem(at: temporary, to: compiled)
            }
            guard fm.fileExists(atPath: compiled.path) else { throw Failure.notInstalled(package) }
            let loaded = try ClapEmbedder(modelAt: compiled)
            embedder = loaded
            return loaded
        }
    }

    public func unload() { lock.withLock { embedder = nil } }

    public var isLoaded: Bool { lock.withLock { embedder != nil } }

    /// The compiled copy exists and isn't older than the package.
    private var isCompiledCurrent: Bool {
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let c = modified(compiled) else { return false }
        guard let p = modified(package) else { return true }
        return c >= p
    }
}
