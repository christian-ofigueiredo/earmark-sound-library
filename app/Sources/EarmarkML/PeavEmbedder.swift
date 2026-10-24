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
/// With GPU compute units, full 10 s windows run on the GPU and shorter ones on the CPU.
public final class PeavEmbedder: @unchecked Sendable {
    public static let dimensions = 1024
    public static let modelName = "pe-av-large"
    public static let parts = ["PEAVEmbed", "PEAVLayers0", "PEAVLayers1", "PEAVLayers2", "PEAVLayers3"]
    private let folder: URL
    private let computeUnits: MLComputeUnits
    /// Windows the last batch had to run on the CPU because the GPU couldn't compute them
    /// (part and window length), for the app's error log.
    public private(set) var lastFallbacks: [String] = []

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

    /// What came out for one file.
    public enum FileResult: Sendable {
        case vector([Float])
        /// No windows: silent or shorter than 20 ms.
        case silent
        /// Core ML couldn't compute one of the file's windows; the rest of the batch goes on.
        case failed(String)
    }

    /// One result per file from each file's windows. A window Core ML can't compute
    /// fails only its own file. `isCancelled` is checked between windows; returns nil if it says so.
    public func embed(filesWindows: [[[Float]]], isCancelled: () -> Bool = { false }) throws -> [FileResult]? {
        let owner = filesWindows.enumerated().flatMap { file, windows in windows.map { _ in file } }
        let flat = filesWindows.flatMap { $0 }
        var failures: [Int: String] = [:]
        var states: [MLMultiArray?] = Array(repeating: nil, count: flat.count)
        lastFallbacks = []
        // Full 10 s windows all have one shape, so the GPU compiles each part once for them.
        // Shorter windows each have their own length; on the GPU every new length means a
        // new graph compiled on the CPU (slower than computing it), so they run on the CPU.
        let full = flat.indices.filter { flat[$0].count == Phase0Audio.windowSamples }
        let short = flat.indices.filter { flat[$0].count != Phase0Audio.windowSamples }
        for (index, part) in Self.parts.enumerated() where !flat.isEmpty {
            let url = folder.appendingPathComponent("\(part).mlmodelc")
            let last = index == Self.parts.count - 1
            for (group, units) in [(full, computeUnits), (short, MLComputeUnits.cpuOnly)] where !group.isEmpty {
                let config = MLModelConfiguration()
                config.computeUnits = units
                let model = try MLModel(contentsOf: url, configuration: config)
                // Loaded only if the GPU fails a window: the CPU computed every length in the parity tests.
                var cpuModel: MLModel?
                for w in group {
                    if isCancelled() { return nil }
                    guard failures[owner[w]] == nil else { states[w] = nil; continue }
                    do {
                        let input: [String: Any]
                        if index == 0 {
                            input = ["input_values": try Self.samples(PeavAudio.input(flat[w]))]
                        } else {
                            guard let state = states[w] else { continue }
                            input = ["hidden": state]
                        }
                        let features = try MLDictionaryFeatureProvider(dictionary: input)
                        let output: MLFeatureProvider
                        do {
                            output = try model.prediction(from: features)
                        } catch where units != .cpuOnly {
                            if cpuModel == nil {
                                let cpu = MLModelConfiguration()
                                cpu.computeUnits = .cpuOnly
                                cpuModel = try MLModel(contentsOf: url, configuration: cpu)
                            }
                            output = try cpuModel!.prediction(from: features)
                            lastFallbacks.append("\(part) \(index == 0 ? PeavAudio.input(flat[w]).count : states[w]?.shape[1].intValue ?? 0)")
                        }
                        guard let value = output.featureValue(for: last ? "embedding" : "hidden_out")?.multiArrayValue else {
                            throw CocoaError(.coderValueNotFound)
                        }
                        states[w] = value
                    } catch {
                        let samples = PeavAudio.input(flat[w]).count
                        failures[owner[w]] = "\(part), window of \(samples) samples: \(error.localizedDescription)"
                        states[w] = nil
                    }
                }
            }
        }
        var result: [FileResult] = []
        var w = 0
        for (file, windows) in filesWindows.enumerated() {
            defer { w += windows.count }
            if windows.isEmpty { result.append(.silent); continue }
            if let failure = failures[file] { result.append(.failed(failure)); continue }
            var sum = [Float](repeating: 0, count: Self.dimensions)
            for k in w ..< w + windows.count {
                guard let e = states[k] else { continue }
                for i in 0 ..< Self.dimensions { sum[i] += e[i].floatValue }
            }
            let norm = max(1e-12, sum.reduce(0) { $0 + $1 * $1 }.squareRoot())
            result.append(.vector(sum.map { $0 / norm }))
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
