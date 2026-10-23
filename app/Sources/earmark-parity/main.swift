import EarmarkCore
import EarmarkML
import Foundation

// Checks the app's embedding pipeline (decode → Phase 0 prep → model input →
// Core ML) against Phase 0's vectors for the same files. Reads the audio only.
//
//   swift run -c release earmark-parity clap <CLAPAudio.mlpackage> <clap_reference.json> [files] [seed]
//   swift run -c release earmark-parity peav <folder of PEAV*.mlpackage> <peav_reference.json> [files] [seed]
//   swift run -c release earmark-parity <clap|peav> <model> <reference> --file <path>
//
// The reference files come from models/parity_clap.py / parity_peav.py --reference.

/// Embeds a batch of files (PE-AV runs part by part over the whole batch).
protocol BatchEmbedder { func embed(batch: [[Float]]) throws -> [[Float]?] }
extension ClapEmbedder: BatchEmbedder {
    func embed(batch: [[Float]]) throws -> [[Float]?] { try batch.map { try embed(audio48k: $0) } }
}
extension PeavEmbedder: BatchEmbedder {
    func embed(batch: [[Float]]) throws -> [[Float]?] {
        try embed(filesWindows: batch.map { PeavEmbedder.windows(audio48k: $0) }) ?? []
    }
}

var args = CommandLine.arguments
guard args.count >= 4, ["clap", "peav"].contains(args[1]) else {
    print("usage: earmark-parity <clap|peav> <model> <reference.json> [files=300] [seed=1]")
    exit(2)
}
let kind = args.remove(at: 1)
func makeEmbedder(_ path: String) throws -> BatchEmbedder {
    let url = URL(fileURLWithPath: path)
    if kind == "clap" { return try ClapEmbedder(modelAt: url) }
    for part in PeavEmbedder.parts { try CompiledModel.ensure(package: url.appendingPathComponent("\(part).mlpackage")) }
    return try PeavEmbedder(compiledIn: url)
}
let reference0 = try JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))

// Diagnostics for one file: earmark-parity <model> <reference> --file <path>
if args.count > 4, args[3] == "--file" {
    let path = args[4]
    let audio = try AudioDecoder.mono(url: URL(fileURLWithPath: path), sampleRate: Double(Phase0Audio.sampleRate),
                                      maxSeconds: Phase0Audio.maxSeconds)
    let prepared = Phase0Audio.prepare(audio)
    print("decoded \(audio.count)  prepared \(prepared?.count ?? 0)  windows \(prepared.map { Phase0Audio.windows($0).map(\.count) } ?? [])")
    if let e = try makeEmbedder(args[1]).embed(batch: [audio])[0], let r = reference0[path] {
        print("cosine to Phase 0: \(zip(e, r).reduce(0) { $0 + $1.0 * $1.1 })")
    }
    exit(0)
}
let count = args.count > 3 ? Int(args[3]) ?? 300 : 300
let seed = args.count > 4 ? UInt64(args[4]) ?? 1 : 1
let reference = reference0

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var rng = SplitMix(state: seed)
let paths = Array(reference.keys.sorted().shuffled(using: &rng).prefix(count))

let embedder = try makeEmbedder(args[1])
var ours: [[Float]] = [], theirs: [[Float]] = [], names: [String] = []
let started = Date()
// Files go through in batches of 32 (PE-AV loads one part at a time per batch);
// only each file's windows are kept, not its whole audio.
let batchSize = kind == "peav" ? 32 : 1
var pending: [(path: String, windows: [[Float]])] = []
@MainActor func flush() throws {
    guard !pending.isEmpty else { return }
    let vectors: [[Float]?]
    if let peav = embedder as? PeavEmbedder {
        vectors = try peav.embed(filesWindows: pending.map(\.windows)) ?? []
    } else {
        vectors = try pending.map { try (embedder as! ClapEmbedder).embed(windows: $0.windows) }
    }
    for (item, v) in zip(pending, vectors) {
        guard let v else { print("skip (silent): \(item.path)"); continue }
        ours.append(v); theirs.append(reference[item.path]!); names.append(item.path)
    }
    pending = []
}
for (i, path) in paths.enumerated() {
    do {
        let audio = try AudioDecoder.mono(url: URL(fileURLWithPath: path), sampleRate: Double(Phase0Audio.sampleRate),
                                          maxSeconds: Phase0Audio.maxSeconds)
        pending.append((path, PeavEmbedder.windows(audio48k: audio)))
        if pending.count >= batchSize { try flush() }
    } catch {
        print("skip (\(error.localizedDescription)): \(path)")
    }
    if (i + 1) % 50 == 0 { print("\(i + 1)/\(paths.count)") }
}
try flush()
let seconds = Date().timeIntervalSince(started)

func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
func neighbours(_ E: [[Float]], k: Int = 5) -> [Set<Int>] {
    E.indices.map { i in
        Set(E.indices.filter { $0 != i }.sorted { dot(E[i], E[$0]) > dot(E[i], E[$1]) }.prefix(k))
    }
}

let pairCosines = zip(ours, theirs).map { dot($0, $1) }
let worst = pairCosines.indices.min { pairCosines[$0] < pairCosines[$1] } ?? 0
let cosines = pairCosines.sorted()
let a = neighbours(ours), b = neighbours(theirs)
let kept = zip(a, b).map { Double($0.intersection($1).count) / 5 }.reduce(0, +) / Double(max(1, a.count))
print(String(format: "\n%d files in %.0f s (%.2f s/file)", ours.count, seconds, seconds / Double(max(1, ours.count))))
print(String(format: "Swift + Core ML vs Phase 0: cosine min %.5f  p1 %.5f  median %.6f   top-5 neighbours kept %.1f%%",
             cosines.first ?? 0, cosines[cosines.count / 100], cosines[cosines.count / 2], kept * 100))
if !names.isEmpty { print("lowest: \(names[worst])") }
