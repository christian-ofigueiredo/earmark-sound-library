import CoreML
import EarmarkCore
import Foundation

/// Meta PE-AV large audio embeddings with Core ML, the same vectors Phase 0 made:
/// one per ≤10 s window (reflect-padded to a multiple of 1920 samples), averaged
/// over up to six windows and L2-normalised.
///
/// The audio tower is converted in five parts (models/convert_peav.py) and run
/// part by part over a batch of windows: only one part (≤ 1.1 GB) is loaded at a
/// time, so it fits beside Resolve on a 16 GB Mac. (With three or more float32
/// parts loaded at once, Core ML's CPU path crashed under memory pressure.)
public final class PeavEmbedder: @unchecked Sendable {
    public static let dimensions = 1024
    public static let modelName = "pe-av-large"
    public static let parts = ["PEAVEmbed", "PEAVLayers0", "PEAVLayers1", "PEAVLayers2", "PEAVLayers3"]
    private let folder: URL
    private let computeUnits: MLComputeUnits

    /// `folder` holds the five compiled parts (`<part>.mlmodelc`); nothing is loaded yet.
    public init(compiledIn folder: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        for part in Self.parts where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(part).mlmodelc").path) {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder.appendingPathComponent(part).path])
        }
        self.folder = folder
        self.computeUnits = computeUnits
    }

    /// Phase 0's windows for a file's mono 48 kHz audio (empty if silent or shorter than 20 ms).
    public static func windows(audio48k x: [Float]) -> [[Float]] {
        Phase0Audio.prepare(x).map(Phase0Audio.windows) ?? []
    }

    /// One vector per file from each file's windows (nil for a file with none).
    /// `isCancelled` is checked between windows; returns nil if it says so.
    public func embed(filesWindows: [[[Float]]], isCancelled: () -> Bool = { false }) throws -> [[Float]?]? {
        let flat = filesWindows.flatMap { $0 }
        guard !flat.isEmpty else { return filesWindows.map { _ in nil } }
        var states: [MLMultiArray] = []
        for (index, part) in Self.parts.enumerated() {
            let config = MLModelConfiguration()
            config.computeUnits = computeUnits
            let model = try MLModel(contentsOf: folder.appendingPathComponent("\(part).mlmodelc"), configuration: config)
            let last = index == Self.parts.count - 1
            var next: [MLMultiArray] = []
            next.reserveCapacity(flat.count)
            for w in 0 ..< flat.count {
                if isCancelled() { return nil }
                let input: [String: Any] = index == 0 ? ["input_values": try Self.samples(PeavAudio.input(flat[w]))]
                                                      : ["hidden": states[w]]
                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: input))
                guard let value = output.featureValue(for: last ? "embedding" : "hidden_out")?.multiArrayValue else {
                    throw CocoaError(.coderValueNotFound)
                }
                next.append(value)
            }
            states = next
        }
        var result: [[Float]?] = []
        var w = 0
        for windows in filesWindows {
            guard !windows.isEmpty else { result.append(nil); continue }
            var sum = [Float](repeating: 0, count: Self.dimensions)
            for _ in windows {
                let e = states[w]
                for i in 0 ..< Self.dimensions { sum[i] += e[i].floatValue }
                w += 1
            }
            let norm = max(1e-12, sum.reduce(0) { $0 + $1 * $1 }.squareRoot())
            result.append(sum.map { $0 / norm })
        }
        return result
    }

    private static func samples(_ x: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: x.count)], dataType: .float32)
        x.withUnsafeBufferPointer { src in
            array.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: src.count)
        }
        return array
    }
}

/// Compiles a `.mlpackage` once to a `.mlmodelc` beside it (again only when the package is newer).
public enum CompiledModel {
    @discardableResult
    public static func ensure(package: URL) throws -> URL {
        let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        let fm = FileManager.default
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if fm.fileExists(atPath: package.path), (modified(compiled) ?? .distantPast) < (modified(package) ?? .distantPast) {
            let temporary = try MLModel.compileModel(at: package)
            try? fm.removeItem(at: compiled)
            try fm.moveItem(at: temporary, to: compiled)
        }
        return compiled
    }
}
