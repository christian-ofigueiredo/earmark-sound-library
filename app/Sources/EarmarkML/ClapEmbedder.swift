import CoreML
import EarmarkCore
import Foundation

/// LAION CLAP (larger_clap_general) audio embeddings with Core ML, the same
/// vectors Phase 0 made: one per ≤10 s window, averaged over up to six windows
/// and L2-normalised. Full precision runs on the CPU: half precision changed 0.6%
/// of nearest neighbours in the parity test (models/parity_clap.py), so it isn't used.
public final class ClapEmbedder: @unchecked Sendable {
    public static let dimensions = 512
    private let model: MLModel

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
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["melspec": input]))
        guard let e = output.featureValue(for: "embedding")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
        return (0 ..< Self.dimensions).map { e[$0].floatValue }
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let norm = max(1e-12, v.reduce(0) { $0 + $1 * $1 }.squareRoot())
        return v.map { $0 / norm }
    }
}
