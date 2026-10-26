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
extension PeavEmbedder.FileResult {
    var vector: [Float]? { if case .vector(let v) = self { v } else { nil } }
}
extension PeavEmbedder: BatchEmbedder {
    func embed(batch: [[Float]]) throws -> [[Float]?] {
        try (embed(filesWindows: batch.map { PeavEmbedder.windows(audio48k: $0) }) ?? []).map(\.vector)
    }
}

var args = CommandLine.arguments

// Folder suggestions, checked on folders that already have UCS categories:
//   earmark-parity folders <copy of library.sqlite>
if args.count >= 3, args[1] == "folders" {
    let db = try LibraryDatabase(path: args[2])
    let sounds = try db.sounds()
    let index = SimilarityIndex(vectors: try db.vectors(model: "clap-general"))
    let labels = Dictionary(uniqueKeysWithValues: sounds.compactMap { s in s.catID.flatMap { c in s.id.map { ($0, c) } } })
    let groups = Dictionary(grouping: sounds, by: { "\($0.libraryId)|\($0.folder)" })
    let catalog = UCSCatalog.shared
    var n = 0, nameTop1 = 0, soundTop1 = 0, top1 = 0, top3 = 0, category = 0
    for (_, members) in groups where members.count >= 5 {
        let cats = members.compactMap(\.catID)
        guard cats.count == members.count,
              let (truth, count) = Dictionary(grouping: cats, by: { $0 }).mapValues(\.count).max(by: { $0.value < $1.value }),
              Double(count) / Double(members.count) >= 0.6 else { continue }
        let ids = members.compactMap(\.id)
        n += 1
        let names = FolderSuggester.nameScores(folder: members[0].folder, catalog: catalog)
        if names.max(by: { $0.value.score < $1.value.score })?.key == truth { nameTop1 += 1 }
        let shares = FolderSuggester.soundShares(soundIds: ids, index: index, labels: labels)
        if shares.max(by: { $0.value < $1.value })?.key == truth { soundTop1 += 1 }
        let options = FolderSuggester.suggest(folder: members[0].folder, soundIds: ids, index: index, labels: labels)
        if options.first?.entry.catID == truth { top1 += 1 }
        if options.prefix(3).contains(where: { $0.entry.catID == truth }) { top3 += 1 }
        if options.first?.entry.category == catalog.entry(catID: truth)?.category { category += 1 }
        if options.first?.entry.catID != truth, args.contains("--misses") {
            print("  miss: \(members[0].folder.split(separator: "/").suffix(2).joined(separator: "/")) — truth \(truth), got "
                  + options.map { "\($0.entry.catID) \(String(format: "%.2f", $0.score)) [\($0.words.joined(separator: ","))\(String(format: " ♪%.0f%%", $0.soundShare * 100))]" }.joined(separator: " | "))
        }
    }
    func pct(_ k: Int) -> String { String(format: "%.0f%%", 100 * Double(k) / Double(max(1, n))) }
    print("\(n) labelled folders (≥ 5 sounds, ≥ 60% one subcategory):")
    print("  name only \(pct(nameTop1)) · sound only \(pct(soundTop1)) · combined \(pct(top1)) (top 3 \(pct(top3)), category \(pct(category)))")
    // What Map Folders to Categories would offer: folders with sounds that have no category.
    let twins = FormatTwins.group(sounds).hidden
    let unlabelled = Dictionary(grouping: sounds.filter { $0.catID == nil && !twins.contains($0.id ?? -1) },
                                by: { "\($0.libraryId)|\($0.folder)" })
    var strong = (folders: 0, sounds: 0), weak = (folders: 0, sounds: 0)
    for (_, members) in unlabelled {
        let options = FolderSuggester.suggest(folder: members[0].folder, soundIds: members.compactMap(\.id), index: index, labels: labels)
        guard let top = options.first else { continue }
        if top.words.isEmpty && top.soundShare < 0.3 { weak.folders += 1; weak.sounds += members.count }
        else { strong.folders += 1; strong.sounds += members.count }
    }
    print("\n\(unlabelled.count) folders, \(unlabelled.values.map(\.count).reduce(0, +)) sounds without a category (format twins left out):")
    print("  name or sound agree: \(strong.folders) folders, \(strong.sounds) sounds · weak (listen first): \(weak.folders) folders, \(weak.sounds) sounds")
    print("\nLargest uncategorised folders:")
    let open = groups.values.filter { $0.allSatisfy { $0.catID == nil } }.sorted { $0.count > $1.count }.prefix(25)
    for members in open {
        let options = FolderSuggester.suggest(folder: members[0].folder, soundIds: members.compactMap(\.id), index: index, labels: labels)
        let text = options.map { o in
            "\(o.entry.label) [\(o.words.joined(separator: ","))\(o.soundShare > 0 ? String(format: " ♪%.0f%%", o.soundShare * 100) : "")]"
        }.joined(separator: "  |  ")
        print(String(format: "%4d  ", members.count) + members[0].folder.split(separator: "/").suffix(2).joined(separator: "/") + "  →  " + text)
    }
    exit(0)
}

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
        let outcomes = try peav.embed(filesWindows: pending.map(\.windows)) ?? []
        for (item, o) in zip(pending, outcomes) { if case .failed(let why) = o { print("failed: \(item.path): \(why)") } }
        vectors = outcomes.map(\.vector)
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
