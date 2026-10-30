import AVFoundation
import CoreML
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
//
//   earmark-parity metadata|scan|twins|keys|phase0|db-new|db-ops|audio|similar|categories|musicsteps|anafile-export|anafile-import|timeline …   (see below; for the Rust engine)

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

// What Swift reads from each file whose path comes on stdin, as JSON lines, for the Rust engine's
// parity check (engine/parity/compare.py). Reads the files only.
//   earmark-parity metadata < paths.txt
if args.count >= 2, args[1] == "metadata" {
    struct Row: Encodable { var path: String; var raw: RawMetadata; var normalized: NormalizedMetadata; var timeReference: Int64 }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    while let path = readLine(), !path.isEmpty {
        let url = URL(fileURLWithPath: path)
        let raw = MetadataReader.read(url: url)
        let row = Row(path: path, raw: raw, normalized: MetadataNormalizer.normalize(raw, url: url),
                      timeReference: MetadataReader.timeReference(url: url))
        FileHandle.standardOutput.write(try encoder.encode(row) + Data("\n".utf8))
    }
    exit(0)
}

// Decoded audio and what Swift measures from it, for the Rust engine's parity check
// (engine/parity/compare.py audio). For each file whose path comes on stdin: <n>.pcm (the file at
// its own rate, float32, channel after channel), <n>.mono (mono 48 kHz, as the CLAP stage decodes
// it) and <n>.clap (CLAP's features of each window), then one JSON line. Reads the files only.
//   earmark-parity audio <work folder> < paths.txt
if args.count >= 3, args[1] == "audio" {
    struct Window: Encodable { var length: Int; var rms: Double }
    struct Row: Encodable {
        var index: Int; var path: String; var rate: Double; var channels: Int; var frames: Int
        var loudness: LoudnessMeter.Result; var monoFrames: Int; var prepared: Int?; var windows: [Window]; var peavLengths: [Int]
    }
    let work = URL(fileURLWithPath: args[2], isDirectory: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var index = 0
    while let path = readLine(), !path.isEmpty {
        defer { index += 1 }
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
        try file.read(into: buffer)
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        var meter = LoudnessMeter(sampleRate: buffer.format.sampleRate, channels: channels)
        var pcm = Data()
        var pointers: [UnsafeBufferPointer<Float>] = []
        for c in 0 ..< channels {
            let p = UnsafeBufferPointer(start: buffer.floatChannelData![c], count: frames)
            pointers.append(p)
            pcm.append(Data(buffer: p))
        }
        // In the app's chunks (64 K frames).
        var start = 0
        while start < frames {
            let n = min(1 << 16, frames - start)
            meter.process(pointers.map { UnsafeBufferPointer(rebasing: $0[start ..< start + n]) }, frames: n)
            start += n
        }
        try pcm.write(to: work.appendingPathComponent("\(index).pcm"))
        let mono = try AudioDecoder.mono(url: url, sampleRate: Double(Phase0Audio.sampleRate), maxSeconds: Phase0Audio.maxSeconds)
        try mono.withUnsafeBufferPointer { try Data(buffer: $0).write(to: work.appendingPathComponent("\(index).mono")) }
        let prepared = Phase0Audio.prepare(mono)
        let windows = prepared.map(Phase0Audio.windows) ?? []
        var clap = Data()
        for w in windows { ClapAudio.features(w).withUnsafeBufferPointer { clap.append(Data(buffer: $0)) } }
        try clap.write(to: work.appendingPathComponent("\(index).clap"))
        let row = Row(index: index, path: path, rate: buffer.format.sampleRate, channels: channels, frames: frames, loudness: meter.result,
                      monoFrames: mono.count, prepared: prepared?.count,
                      windows: windows.map { w in Window(length: w.count, rms: (w.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(w.count)).squareRoot()) },
                      peavLengths: windows.map { PeavAudio.input($0).count })
        FileHandle.standardOutput.write(try encoder.encode(row) + Data("\n".utf8))
    }
    exit(0)
}

// Neighbours and duplicate sets on the database's vectors, for the Rust engine's parity check.
//   earmark-parity similar <library.sqlite> < ids.txt   each sound's 20 nearest by CLAP
//   earmark-parity dupsets <library.sqlite>             identical copies and saved near pairs, as sets
if args.count >= 3, ["similar", "dupsets"].contains(args[1]) {
    let db = try LibraryDatabase(path: args[2], readOnly: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func emit(_ value: some Encodable) throws { FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8)) }
    if args[1] == "similar" {
        struct Row: Encodable { var id: Int64; var ids: [Int64]; var scores: [Float] }
        let index = SimilarityIndex(vectors: try db.vectors(model: "clap-general"))
        while let line = readLine(), let id = Int64(line) {
            let near = index.nearest(to: id, count: 20)
            try emit(Row(id: id, ids: near.map(\.id), scores: near.map(\.score)))
        }
    } else {
        struct Other: Encodable { var id: Int64; var identical: Bool; var similarity: Float }
        struct Out: Encodable { var identical: Int; var near: Int; var members: [[Int64]]; var others: [String: [Other]] }
        let sounds = try db.sounds()
        let identical = Duplicates.identicalPairs(sounds, hidden: FormatTwins.group(sounds).hidden)
        let near = try db.nearDuplicates()
        let sets = Duplicates.sets(identical + near)
        try emit(Out(identical: identical.count, near: near.count, members: sets.members,
                     others: Dictionary(uniqueKeysWithValues: sets.others.map { ("\($0.key)", $0.value.map { Other(id: $0.id, identical: $0.identical, similarity: $0.similarity) }) })))
    }
    exit(0)
}

// Each sound's 15 nearest (the sound map's neighbour search), for the Rust engine's parity check:
//   earmark-parity knn <library.sqlite> <out.json> [category]
if args.count >= 4, args[1] == "knn" {
    let db = try LibraryDatabase(path: args[2], readOnly: true)
    let category = args.count > 4 ? args[4] : nil
    let peav = Dictionary(uniqueKeysWithValues: try db.vectors(model: "pe-av-large").map { ($0.id, $0.vector) })
    let clap = Dictionary(uniqueKeysWithValues: try db.vectors(model: "clap-general").map { ($0.id, $0.vector) })
    let sounds = try db.sounds().filter { s in
        guard let id = s.id, peav[id] != nil, clap[id] != nil else { return false }
        return category == nil || s.category == category
    }.sorted { $0.id! < $1.id! }
    let flat = PageBuffer(count: sounds.count * 1536)
    flat.withFloats { f in
        for (i, s) in sounds.enumerated() { for (c, v) in SoundMap.combine([peav[s.id!]!, clap[s.id!]!]).enumerated() { f[i * 1536 + c] = v } }
    }
    let (indices, distances) = flat.withFloats { SoundMap.nearestNeighbours(UnsafeBufferPointer($0), n: sounds.count, d: 1536, k: 15) }
    struct Out: Encodable { var indices: [Int]; var distances: [Float] }
    try JSONEncoder().encode(Out(indices: indices, distances: distances)).write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}

// The categories as the app works them out, for the Rust engine's parity check
// (engine/parity/compare.py categories). Reads only:
//   earmark-parity categories <library.sqlite>
// 1. every sound's category after folder rules, guesses and per-sound choices (SoundCatalog);
// 2. every open folder's suggestions, as FolderGuesser makes them (all folders, not only the stale);
// 3. SoundGuesser's vote: Earmark's per-sound guesses and the near-duplicate pairs.
if args.count >= 3, args[1] == "categories" {
    let db = try LibraryDatabase(path: args[2], readOnly: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func emit(_ value: some Encodable) throws { FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8)) }
    let rules = try db.folderRules(), guesses = try db.folderGuesses(), choices = try db.soundCategoryChoices()
    let applied = SoundCategories.apply(choices, to: FolderRules.apply(rules, guesses: guesses, to: try db.sounds()))
    struct Applied: Encodable { var id: Int64; var catID: String?; var source: String? }
    for s in applied { try emit(Applied(id: s.id!, catID: s.catID, source: s.categorySource)) }

    let hidden = FormatTwins.group(applied).hidden
    var open: [String: (lib: Int64, folder: String, sounds: [SoundRecord])] = [:]
    for s in applied where s.catID == nil || s.categorySource == FolderRules.source || s.categorySource == FolderRules.guessSource
        || s.categorySource == SoundCategories.soundGuessSource {
        guard let id = s.id, !hidden.contains(id) else { continue }
        open["\(s.libraryId)/\(s.folder)", default: (s.libraryId, s.folder, [])].sounds.append(s)
    }
    let index = SimilarityIndex(vectors: try db.vectors(model: "clap-general"))
    let labels = FolderSuggester.labels(applied), shared = FolderSuggester.sharedDescriptions(applied)
    struct Option: Encodable { var catID: String; var score: Double; var words: [String]; var fileWords: [String]; var soundShare: Double; var uncertain: Bool }
    struct Folder: Encodable { var folder: String; var options: [Option] }
    for key in open.keys.sorted() {
        let f = open[key]!
        let options = FolderSuggester.suggest(folder: f.folder, sounds: f.sounds, index: index, labels: labels, sharedDescriptions: shared)
        try emit(Folder(folder: key, options: options.map {
            Option(catID: $0.entry.catID, score: $0.score, words: $0.words, fileWords: $0.fileWords, soundShare: $0.soundShare,
                   uncertain: $0.isUncertain)
        }))
    }

    // SoundGuesser.run, step by step.
    let owners = choices.filter { $0.value.byOwner }
    let sounds = SoundCategories.apply(owners, to: FolderRules.apply(rules, guesses: guesses, to: try db.sounds()))
    let twinsHidden = FormatTwins.group(sounds).hidden
    let byId = Dictionary(uniqueKeysWithValues: sounds.compactMap { s in s.id.map { ($0, s) } })
    let d = 1536
    var rows: [SoundRecord] = []
    var buffer = PageBuffer(count: 0)
    try db.forEachVectors(models: ["pe-av-large", "clap-general"], count: { buffer = PageBuffer(count: $0 * d) }) { id, blocks in
        guard let s = byId[id], !twinsHidden.contains(id), (rows.count + 1) * d <= buffer.count else { return }
        let r = rows.count
        buffer.withFloats { x in for (c, v) in SoundMap.combine(blocks).enumerated() { x[r * d + c] = v } }
        rows.append(s)
    }
    let k = min(60, rows.count)
    let (indices, distances) = buffer.withFloats { x in
        SoundMap.nearestNeighbours(UnsafeBufferPointer(rebasing: x[0 ..< rows.count * d]), n: rows.count, d: d, k: k)
    }
    let votes = CategoryVotes.votes(indices: indices, distances: distances, k: k, labels: rows.map(\.catID),
                                    folders: rows.map { "\($0.libraryId)/\($0.folder)" })
    let duplicates = Duplicates.nearPairs(ids: rows.map { $0.id! }, durations: rows.map(\.duration), indices: indices,
                                          distances: distances, k: k)
    let folders = Dictionary(grouping: guesses, by: \.libraryId).mapValues { Set($0.map(\.folder)) }
    let byFolder = Dictionary(guesses.map { ("\($0.libraryId)/\($0.folder)", $0) }, uniquingKeysWith: { a, _ in a })
    let made = SoundCategories.guesses(sounds: rows, votes: votes) { s in
        guard let f = FolderRules.ruleFolder(for: s.folder, in: folders[s.libraryId] ?? []),
              let g = byFolder["\(s.libraryId)/\(f)"] else { return [] }
        return Set(g.alternativeIDs)
    }
    struct Guess: Encodable { var guess: Int64; var catID: String; var share: Double?; var replaced: String? }
    for g in made { try emit(Guess(guess: g.soundId, catID: g.catID, share: g.share, replaced: g.replaced)) }
    struct Pair: Encodable { var pair: [Int64]; var similarity: Float }
    for p in duplicates { try emit(Pair(pair: [p.a, p.b], similarity: p.similarity)) }
    struct Top: Encodable { var vote: Int64; var votes: [CategoryVotes.Vote] }
    for (r, v) in votes.enumerated() where r % 50 == 0 { try emit(Top(vote: rows[r].id!, votes: v)) }
    exit(0)
}

// Each step of a song's tempo and key analysis, for the Rust engine's parity check
// (engine/parity/compare.py music). For each song whose path comes on stdin: <n>.m44 (mono
// 44.1 kHz as decoded), <n>.half (after HalfRate), <n>.spect, <n>.beat and <n>.down (the
// aggregated logits), then one JSON line with the key probabilities and the results. Reads only.
//   earmark-parity musicsteps <models folder> <work folder> < paths.txt
if args.count >= 4, args[1] == "musicsteps" {
    let analyzer = try MusicAnalyzer(folder: URL(fileURLWithPath: args[2]))
    let work = URL(fileURLWithPath: args[3], isDirectory: true)
    func save(_ v: [Float], _ name: String) throws {
        try v.withUnsafeBufferPointer { try Data(buffer: $0).write(to: work.appendingPathComponent(name)) }
    }
    struct Row: Encodable {
        var index: Int; var path: String; var keyProbabilities: [Float]; var beats: [Double]; var downbeats: [Double]
        var bpm: Double?; var bpmRange: [Double]?; var stability: String; var beatsPerBar: Int?; var confidence: Double
        var key: MusicKey?; var keyConfidence: Double?; var runnerUp: MusicKey?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var index = 0
    while let path = readLine(), !path.isEmpty {
        defer { index += 1 }
        let m44 = try AudioDecoder.mono(url: URL(fileURLWithPath: path), sampleRate: 44_100, maxSeconds: BeatThisAudio.maxSeconds)
        let half = HalfRate.decimate(m44)
        try save(m44, "\(index).m44"); try save(half, "\(index).half")
        let sr = BeatThisAudio.sampleRate
        let x = half.count > Int(BeatThisAudio.maxSeconds) * sr ? Array(half.prefix(Int(BeatThisAudio.maxSeconds) * sr)) : half
        guard x.count >= 2 * sr, let peak = x.lazy.map(abs).max(), peak >= 1e-5 else { continue }
        let spect = BeatThisAudio.spectrogram(x)
        let frames = BeatThisAudio.frameCount(samples: x.count)
        let starts = BeatThisAudio.chunkStarts(frames: frames)
        var beatOut: [[Float]] = [], downOut: [[Float]] = []
        for start in starts {
            let (b, d) = try analyzer.logits(BeatThisAudio.chunk(spect, frames: frames, start: start))
            beatOut.append(b); downOut.append(d)
        }
        let beat = BeatThisAudio.aggregate(beatOut, starts: starts, frames: frames)
        let down = BeatThisAudio.aggregate(downOut, starts: starts, frames: frames)
        try save(spect, "\(index).spect"); try save(beat, "\(index).beat"); try save(down, "\(index).down")
        let peaks = BeatTracking.peaks(beatLogits: beat, downbeatLogits: down)
        let t = BeatTracking.summarize(beats: peaks.beats, downbeats: peaks.downbeats, beatProbability: beat.map(BeatTracking.sigmoid))
        let probs = try analyzer.keyProbabilities(x.map { $0 / peak })
        let k = KeyDetection.estimate(probabilities: probs)
        let row = Row(index: index, path: path, keyProbabilities: probs, beats: t.beats, downbeats: t.downbeats, bpm: t.bpm,
                      bpmRange: t.bpmRange.map { [$0.lowerBound, $0.upperBound] }, stability: t.stability, beatsPerBar: t.beatsPerBar,
                      confidence: t.confidence, key: k?.key, keyConfidence: k?.confidence, runnerUp: k?.runnerUp)
        FileHandle.standardOutput.write(try encoder.encode(row) + Data("\n".utf8))
    }
    exit(0)
}

// Analysis files and timeline files, for the Rust engine's parity check (engine/parity/compare.py).
//   earmark-parity anafile-export <copy of library.sqlite> <out folder>     one file per library
//   earmark-parity anafile-import <copy of library.sqlite> <file…>  imports them, says what it added
//   earmark-parity timeline < cases.json                            each case's file text or failure
// Numbers in cases.json are text: Foundation's JSONDecoder can be off in the last digit.
if args.count >= 2, ["anafile-export", "anafile-import", "timeline"].contains(args[1]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func emit(_ value: some Encodable) throws { FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8)) }
    switch args[1] {
    case "anafile-export":
        let db = try LibraryDatabase(path: args[2])
        for lib in try db.libraries() {
            try db.writeAnalysisFile(for: lib, includeEmbeddings: true, to: URL(fileURLWithPath: args[3]).appendingPathComponent(AnalysisFile.fileName(for: lib)),
                                     exportedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }
    case "anafile-import":
        struct Report: Encodable {
            var sounds, soundsMatched, facts, embeddings, folderCategories, soundCategories, songs, songsMatched, songAnalyses, corrections: Int
        }
        let db = try LibraryDatabase(path: args[2])
        for path in args[3...] {
            let r = try db.importAnalysis(try AnalysisFile.read(try Data(contentsOf: URL(fileURLWithPath: path))))
            try emit(Report(sounds: r.sounds, soundsMatched: r.soundsMatched, facts: r.facts, embeddings: r.embeddings,
                            folderCategories: r.folderCategories, soundCategories: r.soundCategories, songs: r.songs,
                            songsMatched: r.songsMatched, songAnalyses: r.songAnalyses, corrections: r.corrections))
        }
    default:
        struct RawClip: Decodable {
            var path: String; var name: String; var length: String; var sampleRate: Int; var channels: Int; var timeReference: Int64
            var start: String?; var end: String?; var at: String?
        }
        struct Case: Decodable { var clips: [RawClip]; var rate: String; var start: String; var name: String }
        struct Row: Encodable { var xml: String?; var placements: [TimelineFile.Placement]?; var failure: String? }
        for c in try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile()) {
            let clips = c.clips.map {
                TimelineFile.Clip(path: $0.path, name: $0.name, length: Double($0.length)!, sampleRate: $0.sampleRate, channels: $0.channels,
                                  timeReference: $0.timeReference, start: $0.start.flatMap(Double.init), end: $0.end.flatMap(Double.init),
                                  at: $0.at.flatMap(Double.init))
            }
            do {
                let file = try TimelineFile.fcpxml(clips, rate: TimelineFile.Rate.named(c.rate)!, startTimecode: c.start, name: c.name)
                try emit(Row(xml: file.xml, placements: file.placements, failure: nil))
            } catch {
                try emit(Row(xml: nil, placements: nil, failure: error.localizedDescription))
            }
        }
    }
    exit(0)
}

// The database, for the Rust engine's parity check (engine/parity/compare.py db). Only ever
// given copies of Earmark's database.
//   earmark-parity db-new <path>         a new, empty database
//   earmark-parity db-ops <path> < ops.json   applies the operations in order
if args.count >= 3, ["db-new", "db-ops"].contains(args[1]) {
    let db = try LibraryDatabase(path: args[2])
    if args[1] == "db-ops" {
        struct Op: Decodable {
            var op: String
            var kind: String?
            var path: String?
            var root: String?
            var scanned: [ScannedSound]?
            var files: [File]?
            var file: String?
            var results: [Result]?
        }
        struct File: Decodable {
            var path: String; var fileSize: Int64; var modified: Double
            var title: String?; var artist: String?; var album: String?; var duration: Double?
        }
        struct Result: Decodable { var songId: Int64; var analysis: SongAnalysis }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let ops = try decoder.decode([Op].self, from: FileHandle.standardInput.readDataToEndOfFile())
        func library(_ path: String?) throws -> Int64 {
            guard let lib = try db.libraries().first(where: { $0.path == path }), let id = lib.id else {
                throw CocoaError(.fileNoSuchFile)
            }
            return id
        }
        for op in ops {
            switch op.op {
            case "addLibrary":
                try db.addLibrary(kind: Library.Kind(rawValue: op.kind!)!, path: op.path!, bookmark: nil)
            case "removeLibrary":
                try db.removeLibrary(id: try library(op.path))
            case "replaceSounds":
                try db.replaceSounds(libraryId: try library(op.path), root: URL(fileURLWithPath: op.root!), scanned: op.scanned!)
            case "replaceSongs":
                try db.replaceSongs(libraryId: try library(op.path), root: URL(fileURLWithPath: op.root!), files: op.files!.map {
                    SongFile(path: $0.path, fileSize: $0.fileSize, modified: Date(timeIntervalSince1970: $0.modified),
                             title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration)
                })
            case "applySongAnalysis":
                print(try db.applySongAnalysis(Phase0MusicImport.read(Data(contentsOf: URL(fileURLWithPath: op.file!)))))
            case "saveSongAnalysis":
                print(try db.saveSongAnalysis(op.results!.map { ($0.songId, $0.analysis) }).compactMap(\.id))
            default:
                throw CocoaError(.featureUnsupported)
            }
        }
    }
    exit(0)
}

// The scanner, format twins, music keys and the Phase 0 import, for the Rust engine's parity
// check (engine/parity/compare.py). Reads only.
//   earmark-parity scan <folder>          one JSON line per audio file
//   earmark-parity twins <library.sqlite> the sounds and their format twins (read-only)
//   earmark-parity keys < texts.txt       each text parsed as a key
//   earmark-parity phase0 <music_analysis.json>
if args.count >= 2, ["scan", "twins", "keys", "phase0"].contains(args[1]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func emit(_ value: some Encodable) throws { FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8)) }
    struct Key: Encodable {
        var key: MusicKey; var name: String; var shortName: String; var camelot: String; var relative: MusicKey; var mixesWith: [MusicKey]
        init(_ k: MusicKey) {
            key = k; name = k.name; shortName = k.shortName; camelot = k.camelot; relative = k.relative; mixesWith = k.mixesWith
        }
    }
    switch args[1] {
    case "scan":
        struct Row: Encodable {
            var path: String; var fileSize: Int64; var modified: Double; var fingerprint: String?
            var technical: AudioTechnical; var metadata: NormalizedMetadata; var warnings: [String]
        }
        for s in await LibraryScanner().scan(root: URL(fileURLWithPath: args[2])) {
            try emit(Row(path: s.path, fileSize: s.fileSize, modified: s.modified.timeIntervalSince1970, fingerprint: s.fingerprint,
                         technical: s.technical, metadata: s.metadata, warnings: s.warnings))
        }
    case "twins":
        struct Candidate: Encodable {
            var id: Int64; var libraryId: Int64; var fileName: String; var folder: String; var path: String
            var duration: Double?; var sampleRate: Double?; var bitsPerSample: Int?
        }
        struct Out: Encodable { var sounds: [Candidate]; var alternates: [String: [Int64]]; var hidden: [Int64] }
        let sounds = try LibraryDatabase(path: args[2], readOnly: true).sounds()
        let groups = FormatTwins.group(sounds)
        try emit(Out(sounds: sounds.map { Candidate(id: $0.id!, libraryId: $0.libraryId, fileName: $0.fileName, folder: $0.folder,
                                                    path: $0.path, duration: $0.duration, sampleRate: $0.sampleRate,
                                                    bitsPerSample: $0.bitsPerSample) },
                     alternates: Dictionary(uniqueKeysWithValues: groups.alternates.map { ("\($0.key)", $0.value) }),
                     hidden: groups.hidden.sorted()))
    case "keys":
        struct Row: Encodable { var text: String; var parsed: Key? }
        while let text = readLine() { try emit(Row(text: text, parsed: MusicKey(parsing: text).map(Key.init))) }
        for k in MusicKey.all { try emit(Row(text: "all", parsed: Key(k))) }
    default:
        struct Row: Encodable {
            var path: String?; var fileName: String; var size: Int64?; var title: String?; var artist: String?; var analysis: SongAnalysis
        }
        for e in try Phase0MusicImport.read(Data(contentsOf: URL(fileURLWithPath: args[2]))) {
            try emit(Row(path: e.path, fileName: e.fileName, size: e.size, title: e.title, artist: e.artist, analysis: e.analysis))
        }
    }
    exit(0)
}

// Folder suggestions, checked on folders that already have UCS categories:
//   earmark-parity folders <copy of library.sqlite>
if args.count >= 3, args[1] == "folders" {
    let db = try LibraryDatabase(path: args[2])
    let sounds = try db.sounds()
    let index = SimilarityIndex(vectors: try db.vectors(model: "clap-general"))
    let labels = Dictionary(uniqueKeysWithValues: sounds.compactMap { s in s.catID.flatMap { c in s.id.map { ($0, c) } } })
    let groups = Dictionary(grouping: sounds, by: { "\($0.libraryId)|\($0.folder)" })
    let catalog = UCSCatalog.shared
    // EARMARK_TUNING="pack=0,file=0.3,strong=1,leaf=0,sharedw=0,minshare=0.2,other=0" switches parts off to measure them.
    var tuning = FolderSuggester.Tuning()
    for kv in (ProcessInfo.processInfo.environment["EARMARK_TUNING"] ?? "").split(separator: ",") {
        let p = kv.split(separator: "=").map(String.init)
        guard p.count == 2, let v = Double(p[1]) else { continue }
        switch p[0] {
        case "strong": tuning.fileWeightBesideStrongName = v
        case "pack": tuning.packWords = v != 0
        case "file": tuning.fileWeight = v
        case "leaf": tuning.leafOverridesParent = v != 0
        case "sharedw": tuning.sharedDescriptionWeight = v
        case "minshare": tuning.minFileShare = v
        case "other": tuning.otherCategoryLast = v != 0
        case "coverage": tuning.soundCoverage = v
        default: print("unknown tuning \(p[0])")
        }
    }
    let shared = FolderSuggester.sharedDescriptions(sounds)
    let twins = FormatTwins.group(sounds).hidden
    /// Suggestions as the app makes them (format twins left out, the files' words and designer).
    func suggest(_ members: [SoundRecord], count: Int = 3) -> [FolderSuggester.Option] {
        let shown = members.filter { !twins.contains($0.id ?? -1) }
        return FolderSuggester.suggest(folder: members[0].folder, sounds: shown, index: index, labels: labels,
                                       sharedDescriptions: shared, count: count, tuning: tuning)
    }
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
        let options = suggest(members)
        if options.first?.entry.catID == truth { top1 += 1 }
        if options.prefix(3).contains(where: { $0.entry.catID == truth }) { top3 += 1 }
        if options.first?.entry.category == catalog.entry(catID: truth)?.category { category += 1 }
        if options.first?.entry.catID != truth, args.contains("--misses") {
            print("  miss: \(members[0].folder.split(separator: "/").suffix(2).joined(separator: "/")) — truth \(truth), got "
                  + options.map { "\($0.entry.catID) \(String(format: "%.2f", $0.score)) [\($0.words.joined(separator: ","))\(String(format: " ♪%.0f%%", $0.soundShare * 100))]" }.joined(separator: " | "))
        }
    }
    func pct2(_ k: Int, _ n: Int) -> String { String(format: "%.0f%%", 100 * Double(k) / Double(max(1, n))) }
    func pct(_ k: Int) -> String { String(format: "%.0f%%", 100 * Double(k) / Double(max(1, n))) }
    print("\(n) labelled folders (≥ 5 sounds, ≥ 60% one subcategory):")
    print("  name only \(pct(nameTop1)) · sound only \(pct(soundTop1)) · combined \(pct(top1)) (top 3 \(pct(top3)), category \(pct(category)))")
    // What Map Folders to Categories would offer: folders with sounds that have no category.
    let unlabelled = Dictionary(grouping: sounds.filter { $0.catID == nil && !twins.contains($0.id ?? -1) },
                                by: { "\($0.libraryId)|\($0.folder)" })
    var strong = (folders: 0, sounds: 0), weak = (folders: 0, sounds: 0)
    for (_, members) in unlabelled {
        let options = suggest(members)
        guard let top = options.first else { continue }
        // As the app's "listen first".
        if top.isWeak {
            weak.folders += 1; weak.sounds += members.count
        }
        else { strong.folders += 1; strong.sounds += members.count }
    }
    print("\n\(unlabelled.count) folders, \(unlabelled.values.map(\.count).reduce(0, +)) sounds without a category (format twins left out):")
    print("  name or sound agree: \(strong.folders) folders, \(strong.sounds) sounds · weak (listen first): \(weak.folders) folders, \(weak.sounds) sounds")
    // --file-words: the files' words that match UCS, by how many folders have them.
    if args.contains("--file-words") {
        var folders: [String: Int] = [:]
        for members in groups.values {
            for w in FolderSuggester.fileWords(of: members, sharedDescriptions: shared).keys
            where FolderSuggester.nameScores(folder: w, catalog: catalog).isEmpty == false { folders[w, default: 0] += 1 }
        }
        print(folders.sorted { $0.value > $1.value }.prefix(80).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }
    // --truth <tsv>: folders without a category, checked by hand (folder \t CatID[,alternatives]).
    if let t = args.firstIndex(of: "--truth"), t + 1 < args.count {
        let lines = try String(contentsOfFile: args[t + 1], encoding: .utf8).split(separator: "\n")
        let byFolder = Dictionary(grouping: unlabelled.values.flatMap { $0 }, by: \.folder)
        var n = 0, top1 = 0, top3 = 0, category = 0
        var misses: [String] = []
        for line in lines {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count == 2, let members = byFolder[cols[0]] else { continue }
            let accept = Set(cols[1].split(separator: ",").map(String.init))
            let cats = Set(accept.compactMap { catalog.entry(catID: $0)?.category })
            let options = suggest(members)
            n += 1
            if let o = options.first, accept.contains(o.entry.catID) { top1 += 1 }
            if options.prefix(3).contains(where: { accept.contains($0.entry.catID) }) { top3 += 1 }
            if let o = options.first, cats.contains(o.entry.category) { category += 1 }
            else { misses.append("  ✗ \(cols[0].split(separator: "/").suffix(2).joined(separator: "/")) — want \(cols[1]), got \(options.prefix(3).map(\.entry.catID).joined(separator: " "))") }
        }
        print("\n\(n) hand-checked folders without a category: top 1 \(pct2(top1, n)), top 3 \(pct2(top3, n)), category \(pct2(category, n))")
        if args.contains("--misses") { misses.forEach { print($0) } }
    }
    // --list [N] [substring]: the N largest uncategorised folders (all with 0), optionally only
    // those whose path contains the substring. --explain adds the name scores and sound shares.
    let listAt = args.firstIndex(of: "--list") ?? args.firstIndex(of: "--explain")
    let explain = args.contains("--explain")
    let limit = listAt.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 25
    let needle = listAt.flatMap { i in args.dropFirst(i + 1).first { Int($0) == nil && !$0.hasPrefix("--") } }?.lowercased()
    print("\nLargest uncategorised folders:")
    let open = unlabelled.values
        .filter { needle == nil || $0[0].folder.lowercased().contains(needle!) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0].folder < $1[0].folder }
        .prefix(limit == 0 ? Int.max : limit)
    for members in open {
        if explain {
            let folder = members[0].folder, ids = members.compactMap(\.id)
            print("\n\(members.count)  \(folder)")
            print("  words: " + FolderSuggester.folderWords(folder).map { "\($0.word)×\($0.weight)" }.joined(separator: " "))
            let names = FolderSuggester.nameScores(folder: folder, catalog: catalog).sorted { $0.value.score > $1.value.score }.prefix(8)
            print("  name: " + names.map { "\($0.key) \(String(format: "%.2f", $0.value.score))[\($0.value.words.joined(separator: ","))]" }.joined(separator: "  "))
            let shares = FolderSuggester.soundShares(soundIds: ids, index: index, labels: labels).sorted { $0.value > $1.value }.prefix(8)
            print("  sound: " + shares.map { "\($0.key) \(String(format: "%.0f%%", $0.value * 100))" }.joined(separator: "  "))
            print("  files: " + FolderSuggester.fileWords(of: members, sharedDescriptions: shared).sorted { $0.value > $1.value }
                .map { "\($0.key) \(String(format: "%.0f%%", $0.value * 100))" }.joined(separator: " ")
                + "  · designer: " + FolderSuggester.packWords(of: members).sorted().joined(separator: " "))
            let options = suggest(members, count: 5)
            print("  → " + options.map { "\($0.entry.catID) \(String(format: "%.3f", $0.score))[\(($0.words + $0.fileWords).joined(separator: ","))]" }.joined(separator: "  ")
                  + (options.first?.isUncertain == true ? "  (listen first)" : ""))
            continue
        }
        let options = suggest(members)
        let text = options.map { o in
            "\(o.entry.label) [\(o.words.joined(separator: ","))\(o.soundShare > 0 ? String(format: " ♪%.0f%%", o.soundShare * 100) : "")]"
        }.joined(separator: "  |  ")
        let weak = options.first?.isWeak ?? false
        // --tops: one tab-separated line per folder, for comparing two versions.
        if args.contains("--tops") { print("TOP\t" + members[0].folder + "\t" + (options.first?.entry.catID ?? "-") + "\t" + text); continue }
        print(String(format: "%4d  ", members.count) + members[0].folder.split(separator: "/").suffix(2).joined(separator: "/") + "  →  " + text
              + (weak ? "  ⚠︎ listen first" : ""))
    }
    exit(0)
}

// Tempo and key, checked against the values Phase 0 stored for the same songs:
//   earmark-parity music <folder with BeatThis/SKey.mlpackage> <copy of library.sqlite> [songs=300] [seed=1] [cpu|gpu|all]
// The sound map's layout on real sounds, for models/parity_map.py to compare with umap-learn:
//   earmark-parity map <copy of library.sqlite> <out.json> [category]
if args.count >= 4, args[1] == "map" {
    let db = try LibraryDatabase(path: args[2])
    let category = args.count > 4 ? args[4] : nil
    let peav = Dictionary(uniqueKeysWithValues: try db.vectors(model: "pe-av-large").map { ($0.id, $0.vector) })
    let clap = Dictionary(uniqueKeysWithValues: try db.vectors(model: "clap-general").map { ($0.id, $0.vector) })
    let sounds = try db.sounds().filter { s in
        guard let id = s.id, peav[id] != nil, clap[id] != nil else { return false }
        return category == nil || s.category == category
    }.sorted { $0.id! < $1.id! }
    // In a PageBuffer, as the app's: Accelerate's sums depend on where the matrix sits.
    let flat = PageBuffer(count: sounds.count * 1536)
    flat.withFloats { f in
        for (i, s) in sounds.enumerated() { for (c, v) in SoundMap.combine([peav[s.id!]!, clap[s.id!]!]).enumerated() { f[i * 1536 + c] = v } }
    }
    let t = Date()
    let map = flat.withFloats { SoundMap.layout(flat: UnsafeBufferPointer($0), count: sounds.count, dimensions: 1536) }!
    let seconds = Date().timeIntervalSince(t)
    print(String(format: "%d sounds%@: layout in %.1f s", sounds.count, category.map { " in \($0)" } ?? "", seconds))
    struct Out: Encodable { var ids: [Int64]; var x: [Float]; var y: [Float]; var seconds: Double }
    try JSONEncoder().encode(Out(ids: sounds.map { $0.id! }, x: map.map(\.x), y: map.map(\.y), seconds: seconds))
        .write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}

// Similarity groups on real sounds, for models/parity_groups.py to compare with Phase 0's:
//   earmark-parity groups <copy of library.sqlite> <out.json> [CatID,CatID,…]
// Every subcategory (or those given) as the app groups it: effective categories, format twins left out.
if args.count >= 4, args[1] == "groups" {
    let db = try LibraryDatabase(path: args[2])
    let wanted = args.count > 4 ? Set(args[4].split(separator: ",").map(String.init)) : nil
    let peav = Dictionary(uniqueKeysWithValues: try db.vectors(model: "pe-av-large").map { ($0.id, $0.vector) })
    let clap = Dictionary(uniqueKeysWithValues: try db.vectors(model: "clap-general").map { ($0.id, $0.vector) })
    let all = FolderRules.apply(try db.folderRules(), guesses: try db.folderGuesses(), to: try db.sounds())
    let hidden = FormatTwins.group(all).hidden
    var buckets: [String: [SoundRecord]] = [:]
    for s in all {
        guard let id = s.id, let catID = s.catID, !hidden.contains(id), peav[id] != nil, clap[id] != nil,
              wanted?.contains(catID) ?? true else { continue }
        buckets[catID, default: []].append(s)
    }
    var mean = [Float](repeating: 0, count: 1536), counted = 0
    for (id, v) in peav { if let c = clap[id] { for (k, x) in SoundMap.combine([v, c]).enumerated() { mean[k] += x }; counted += 1 } }
    mean = mean.map { $0 / Float(max(1, counted)) }
    struct Bucket: Encodable { var catID: String; var ids: [Int64]; var labels: [Int]; var names: [SoundGroups.Name]; var seconds: Double }
    var out: [Bucket] = []
    let start = Date()
    for (catID, sounds) in buckets.sorted(by: { $0.value.count > $1.value.count }) {
        let ordered = sounds.sorted { $0.id! < $1.id! }
        let x = ordered.flatMap { SoundMap.combine([peav[$0.id!]!, clap[$0.id!]!]) }
        let t = Date()
        let labels = SoundGroups.cluster(x, count: ordered.count, dimensions: 1536)!
        let groups = Set(labels).filter { $0 >= 0 }.sorted().map { g in labels.indices.filter { labels[$0] == g } }
        let names = SoundGroups.names(groups: groups, x: x, dimensions: 1536, members: ordered.map(SoundGroups.Member.init),
                                      libraryMean: mean, exclude: SoundGroups.excludedWords(for: ordered))
        let seconds = Date().timeIntervalSince(t)
        out.append(Bucket(catID: catID, ids: ordered.map { $0.id! }, labels: labels, names: names, seconds: seconds))
        print(String(format: "%@ %d sounds: %d groups, %d left over, %.2f s", catID, ordered.count, groups.count,
                     labels.filter { $0 < 0 }.count, seconds))
    }
    print(String(format: "%d subcategories, %d sounds in %.1f s", out.count, out.reduce(0) { $0 + $1.ids.count },
                 Date().timeIntervalSince(start)))
    try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}

// A second opinion per sound (CategoryVotes), checked two ways:
//   earmark-parity votes <copy of library.sqlite> [--truth <tsv>] [--strong 0.6] [--weak 0.1] [--show 20]
// 1. sounds with a category of their own (UCS in the file): does the vote of their nearest in
//    other folders name it? 2. sounds in folders checked by hand (--truth, as for `folders`): when
//    the vote disagrees with Earmark's guess, how often is the vote right, the guess wrong?
if args.count >= 3, args[1] == "votes" {
    let db = try LibraryDatabase(path: args[2])
    func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let strong = option("--strong").flatMap(Double.init) ?? 0.6, weak = option("--weak").flatMap(Double.init) ?? 0.1
    let all = FolderRules.apply(try db.folderRules(), guesses: try db.folderGuesses(), to: try db.sounds())
    let hidden = FormatTwins.group(all).hidden
    let byId = Dictionary(uniqueKeysWithValues: all.compactMap { s in s.id.map { ($0, s) } })
    var ids: [Int64] = [], capacity = 0
    var buffer = PageBuffer(count: 0)
    try db.forEachVectors(models: ["pe-av-large", "clap-general"], count: { capacity = $0; buffer = PageBuffer(count: $0 * 1536) }) { id, blocks in
        guard let s = byId[id], !hidden.contains(id), ids.count < capacity else { return }
        let r = ids.count
        buffer.withFloats { x in for (c, v) in SoundMap.combine(blocks).enumerated() { x[r * 1536 + c] = v } }
        ids.append(id)
        _ = s
    }
    let sounds = ids.map { byId[$0]! }
    let t = Date()
    // --own: only sounds whose files carry a category vote (not Earmark's guesses).
    let ownOnly = args.contains("--own")
    let labels = sounds.map { s in
        ownOnly && (s.categorySource == FolderRules.guessSource || s.categorySource == nil) ? nil : s.catID
    }
    let votes = buffer.withFloats { x in
        CategoryVotes.votes(UnsafeBufferPointer(rebasing: x[0 ..< ids.count * 1536]), count: ids.count, dimensions: 1536,
                            labels: labels, folders: sounds.map { "\($0.libraryId)/\($0.folder)" })!
    }
    // --alternatives: a flag only names one of the folder guess's runners-up.
    let guesses = try db.folderGuesses()
    let guessFolders = Dictionary(grouping: guesses, by: \.libraryId).mapValues { Set($0.map(\.folder)) }
    let guessByKey = Dictionary(guesses.map { ("\($0.libraryId)/\($0.folder)", $0) }, uniquingKeysWith: { a, _ in a })
    func alternatives(_ s: SoundRecord) -> Set<String> {
        guard let f = FolderRules.ruleFolder(for: s.folder, in: guessFolders[s.libraryId] ?? []),
              let g = guessByKey["\(s.libraryId)/\(f)"] else { return [] }
        return Set(g.alternativeIDs)
    }
    let onlyAlternatives = args.contains("--alternatives")
    func flagged(_ i: Int) -> Bool {
        guard CategoryVotes.disagrees(votes[i], with: sounds[i].catID, strong: strong, weak: weak) else { return false }
        return !onlyAlternatives || alternatives(sounds[i]).contains(votes[i][0].catID)
    }
    print(String(format: "%d sounds voted in %.1f s", ids.count, Date().timeIntervalSince(t)))
    let catalog = UCSCatalog.shared
    var own = 0, top1 = 0, top3 = 0, cat = 0
    for (i, s) in sounds.enumerated() where s.categorySource != nil && s.categorySource != FolderRules.guessSource
        && s.categorySource != FolderRules.source {
        own += 1
        if votes[i].first?.catID == s.catID { top1 += 1 }
        if votes[i].contains(where: { $0.catID == s.catID }) { top3 += 1 }
        if catalog.entry(catID: votes[i].first?.catID)?.category == s.category { cat += 1 }
    }
    print(String(format: "Own categories (%d sounds): vote top 1 %.0f%%, top 3 %.0f%%, category %.0f%%", own,
                 100 * Double(top1) / Double(max(1, own)), 100 * Double(top3) / Double(max(1, own)), 100 * Double(cat) / Double(max(1, own))))
    if let path = option("--truth") {
        var truth: [String: Set<String>] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 { truth[String(parts[0])] = Set(parts[1].split(separator: ",").map(String.init)) }
        }
        func truthFor(_ s: SoundRecord) -> Set<String>? {
            var folder = s.folder
            while true {
                if let t = truth[folder] { return t }
                guard let slash = folder.lastIndex(of: "/") else { return nil }
                folder = String(folder[..<slash])
            }
        }
        var checked = 0, guessRight = 0, flaggedCount = 0, voteRight = 0, guessWrongToo = 0, harmful = 0
        var shown = 0, show = option("--show").flatMap(Int.init) ?? 0
        for (i, s) in sounds.enumerated() {
            guard let t = truthFor(s), s.categorySource == FolderRules.guessSource else { continue }
            checked += 1
            let right = t.contains(s.catID ?? "")
            if right { guessRight += 1 }
            guard flagged(i) else { continue }
            flaggedCount += 1
            let v = votes[i][0].catID
            if t.contains(v) { voteRight += 1 }
            if !right { guessWrongToo += 1 }
            if right && !t.contains(v) { harmful += 1 }
            if shown < show {
                shown += 1
                print("  \(s.fileName.prefix(60)) — guess \(s.catID ?? "-") \(right ? "✓" : "✗"), vote \(v) \(Int(votes[i][0].share * 100))% \(t.contains(v) ? "✓" : "✗")")
            }
        }
        print(String(format: "Hand-checked folders: %d guessed sounds, guess right %.0f%%", checked, 100 * Double(guessRight) / Double(max(1, checked))))
        print(String(format: "Flagged (vote ≥ %.0f%% for another, own < %.0f%%): %d; vote right %d, guess wrong %d, guess right but vote wrong %d",
                     strong * 100, weak * 100, flaggedCount, voteRight, guessWrongToo, harmful))
    }
    // Over the whole library: how many sounds would be flagged.
    let library = sounds.indices.filter(flagged)
    let bySource = Dictionary(grouping: library) { sounds[$0].categorySource ?? "none" }.mapValues(\.count)
    print("Flagged in the library: \(library.count) (\(bySource.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")))")
    exit(0)
}

// How alike copies of one recording are, against takes of one sound, to set the duplicates'
// threshold: each sound's nearest (PE-AV + CLAP, cosine), pairs sorted into byte-identical
// copies, format twins (FormatTwins), numbered takes in one folder ("Hit 01"/"Hit 02") and the rest.
//   earmark-parity duplicates <copy of library.sqlite> [--band <low> <high>] [--show <from cosine>]
// --band counts the pairs in that cosine band with the same length or not; --show prints some.
if args.count >= 3, args[1] == "duplicates" {
    let db = try LibraryDatabase(path: args[2])
    let all = try db.sounds()
    let byId = Dictionary(uniqueKeysWithValues: all.compactMap { s in s.id.map { ($0, s) } })
    let twins = FormatTwins.group(all)
    var twinPairs = Set<String>()
    for (best, others) in twins.alternates { for o in others { twinPairs.insert("\(min(best, o)) \(max(best, o))") } }
    var ids: [Int64] = [], capacity = 0
    var buffer = PageBuffer(count: 0)
    try db.forEachVectors(models: ["pe-av-large", "clap-general"], count: { capacity = $0; buffer = PageBuffer(count: $0 * 1536) }) { id, blocks in
        guard byId[id] != nil, ids.count < capacity else { return }
        let r = ids.count
        buffer.withFloats { x in for (c, v) in SoundMap.combine(blocks).enumerated() { x[r * 1536 + c] = v } }
        ids.append(id)
    }
    let k = 6
    let found = buffer.withFloats { x in
        SoundMap.nearestNeighbours(UnsafeBufferPointer(rebasing: x[0 ..< ids.count * 1536]), n: ids.count, d: 1536, k: k)
    }
    func stem(_ s: SoundRecord) -> String {
        let name = (s.fileName as NSString).deletingPathExtension.lowercased()
        return String(name.map { $0.isNumber ? "#" : $0 })
    }
    var sims: [String: [Float]] = [:], seen = Set<String>()
    var durationOff: [String: [Double]] = [:], bandCounts: [String: Int] = [:]
    for i in 0 ..< ids.count {
        for c in 0 ..< k {
            let j = found.indices[i * k + c]
            guard j != i else { continue }
            let key = "\(min(ids[i], ids[j])) \(max(ids[i], ids[j]))"
            guard seen.insert(key).inserted else { continue }
            let a = byId[ids[i]]!, b = byId[ids[j]]!
            let kind: String
            if a.fingerprint != nil && a.fingerprint == b.fingerprint { kind = "identical" }
            else if twinPairs.contains(key) { kind = "format twins" }
            else if a.folder == b.folder && a.libraryId == b.libraryId && stem(a) == stem(b) && a.fileName != b.fileName { kind = "numbered takes" }
            else { kind = "other" }
            sims[kind, default: []].append(1 - found.distances[i * k + c])
            let cos = 1 - found.distances[i * k + c]
            let band = args.firstIndex(of: "--band").map { (Float(args[$0 + 1])!, Float(args[$0 + 2])!) }
            if let (lo, hi) = band, kind != "identical", cos >= lo, cos < hi, let x = a.duration, let y = b.duration {
                let same = abs(x - y) <= max(0.02, 0.01 * max(x, y))
                bandCounts[same ? "same length" : "other length", default: 0] += 1
            }
            if args.contains("--show"), kind != "identical", cos >= Float(args.last!) ?? 0.999, Int.random(in: 0 ..< 8) == 0 {
                func d(_ s: SoundRecord) -> String {
                    String(format: "%@/%@ %.2fs %.0fHz %db", String(s.folder.split(separator: "/").suffix(2).joined(separator: "/")), s.fileName,
                           s.duration ?? 0, s.sampleRate ?? 0, s.bitsPerSample ?? 0)
                }
                print(String(format: "  %.4f %@ | %@ | %@", cos, kind, d(a), d(b)))
            }
            if let x = a.duration, let y = b.duration, max(x, y) > 0 { durationOff[kind, default: []].append(abs(x - y) / max(x, y)) }
        }
    }
    if !bandCounts.isEmpty { print("band: \(bandCounts)") }
    for (kind, list) in sims.sorted(by: { $0.key < $1.key }) {
        let s = list.sorted()
        func p(_ q: Double) -> Float { s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        let d = (durationOff[kind] ?? []).sorted()
        func dp(_ q: Double) -> Double { d.isEmpty ? 0 : d[min(d.count - 1, Int(Double(d.count - 1) * q))] }
        print(String(format: "%@: %d pairs; cosine min %.4f, 1%% %.4f, 5%% %.4f, median %.4f, 99%% %.4f; length off median %.3f, 95%% %.3f",
                     kind, s.count, s[0], p(0.01), p(0.05), p(0.5), p(0.99), dp(0.5), dp(0.95)))
        for t: Float in [0.98, 0.99, 0.995, 0.998, 0.999] { print(String(format: "    ≥ %.3f: %d", t, s.filter { $0 >= t }.count)) }
    }
    exit(0)
}

// Analysis files at full size, on copies (never the app's own database):
//   earmark-parity analysis-files <copy of library.sqlite> <out folder>
// Exports every library, clears the analysis in a second copy, imports into it, compares the two.
if args.count >= 4, args[1] == "analysis-files" {
    func peakMB() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1_048_576 }
    let source = try LibraryDatabase(path: args[2])
    let out = URL(fileURLWithPath: args[3], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var files: [URL] = []
    // ONLY_IMPORT=1: use the files already in <out folder> (to measure the import alone).
    if ProcessInfo.processInfo.environment["ONLY_IMPORT"] != nil {
        files = try source.libraries().map { out.appendingPathComponent(AnalysisFile.fileName(for: $0)) }
    } else { for lib in try source.libraries() {
        let t = Date()
        let url = out.appendingPathComponent(AnalysisFile.fileName(for: lib))
        let bytes = try source.writeAnalysisFile(for: lib, includeEmbeddings: true, to: url)
        files.append(url)
        print(String(format: "export %@: %.1f MB in %.1f s (peak memory so far %.0f MB)",
                     lib.name, Double(bytes) / 1_048_576, Date().timeIntervalSince(t), peakMB()))
    } }
    // The second copy: the same libraries and files, with no analysis at all.
    let cleared = out.appendingPathComponent("cleared.sqlite")
    try? FileManager.default.removeItem(at: cleared)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: cleared)
    let target = try LibraryDatabase(path: cleared.path)
    try target.clearAnalysisForTesting()
    for pass in 1 ... 2 {
        var report = AnalysisImportReport()
        let t = Date()
        for url in files { report = report + (try target.importAnalysis(try AnalysisFile.read(try Data(contentsOf: url)))) }
        print(String(format: "import pass %d in %.1f s (peak memory %.0f MB): ", pass, Date().timeIntervalSince(t), peakMB()) + "\(report)")
    }
    // Item by item: the copy now has what the source has.
    let (a, b) = (try source.soundFacts(), try target.soundFacts())
    let factsSame = a.filter { $0.value.error == nil }.allSatisfy { id, f in b[id].map { $0.loudness == f.loudness && $0.peak == f.peak && $0.fingerprint == f.fingerprint } ?? false }
    print("facts: source \(a.count) (\(a.values.filter { $0.error != nil }.count) unreadable, not exported), copy \(b.count), all the same: \(factsSame)")
    for model in SoundEmbedding.versions.keys.sorted() {
        let (va, vb) = (try source.vectors(model: model), try target.vectors(model: model))
        let byId = Dictionary(uniqueKeysWithValues: vb.map { ($0.id, $0.vector) })
        print("\(model): source \(va.count) vectors, copy \(vb.count), bit-exact: \(va.allSatisfy { byId[$0.id] == $0.vector })")
    }
    let (sa, sb) = (try source.songs(), try target.songs())
    let songsById = Dictionary(uniqueKeysWithValues: sb.map { ($0.id!, $0) })
    let songsSame = sa.allSatisfy { s in songsById[s.id!].map { $0.bpm == s.bpm && $0.key == s.key && $0.beatsPerBar == s.beatsPerBar
        && $0.tempoStability == s.tempoStability && $0.keyConfidence == s.keyConfidence && $0.analysisSource == s.analysisSource } ?? false }
    print("songs: \(sa.filter(\.isAnalysed).count) analysed in the source, \(sb.filter(\.isAnalysed).count) in the copy, all the same: \(songsSame)")
    print("folder categories: \(try source.folderRules().count) / \(try target.folderRules().count); corrections: \(try source.songCorrections().count) / \(try target.songCorrections().count)")
    exit(0)
}

// The app's decode of one song, as raw float32 (mono 22.05 kHz): earmark-parity decode <file> <out.f32>
if args.count >= 4, args[1] == "decode" {
    let audio = try MusicAnalyzer.decode(url: URL(fileURLWithPath: args[2]))
    try audio.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: args[3])) }
    print("\(audio.count) samples")
    exit(0)
}

// One song already decoded (raw float32, mono 22.05 kHz), to tell decoding apart from the rest:
//   earmark-parity music-raw <models folder> <audio.f32>   (writes the spectrogram to <audio>.spect.f32)
if args.count >= 4, args[1] == "music-raw" {
    let raw = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    let audio = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let analyzer = try MusicAnalyzer(folder: URL(fileURLWithPath: args[2]))
    let spect = BeatThisAudio.spectrogram(audio)
    try spect.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: args[3] + ".spect.f32")) }
    guard let r = try analyzer.analyse(audio22k: audio) else { print("silent or short"); exit(0) }
    print("BPM \(r.tempo.bpm ?? 0), \(r.tempo.beats.count) beats, \(r.tempo.beatsPerBar ?? 0) per bar, key \(r.key?.key.name ?? "-")")
    exit(0)
}

if args.count >= 4, args[1] == "music" {
    let units: MLComputeUnits = switch args.count > 6 && !args[6].hasPrefix("--") ? args[6] : "cpu" {
    case "gpu": .cpuAndGPU
    case "all": .all
    default: .cpuOnly
    }
    let analyzer = try MusicAnalyzer(folder: URL(fileURLWithPath: args[2]), computeUnits: units)
    let db = try LibraryDatabase(path: args[3])
    let count = args.count > 4 ? Int(args[4]) ?? 300 : 300
    var rng = SplitMix(state: args.count > 5 ? UInt64(args[5]) ?? 1 : 1)
    let songs = try db.songs().filter { $0.analysisSource == "Phase 0" && FileManager.default.fileExists(atPath: $0.path) }
        .sorted { $0.path < $1.path }.shuffled(using: &rng).prefix(count)
    var n = 0, bpmClose = 0, bpmBoth = 0, bpmExact = 0, octave = 0, steady = 0, bars = 0, barsBoth = 0
    var keySame = 0, keyBoth = 0, keyRelative = 0, keyFifth = 0
    var confidenceDiff: [Double] = [], timings: [String: Double] = [:], decodeTime = 0.0, audioSeconds = 0.0
    var misses: [String] = []
    let started = Date()
    for song in songs {
        let t0 = Date()
        let audio: [Float]
        do {
            audio = try MusicAnalyzer.decode(url: song.url)
        } catch {
            print("skip (\(error.localizedDescription)): \(song.path)")
            continue
        }
        decodeTime += Date().timeIntervalSince(t0)
        guard let r = try analyzer.analyse(audio22k: audio) else { print("skip (silent or short): \(song.path)"); continue }
        n += 1
        audioSeconds += r.seconds
        for (k, v) in r.timings { timings[k, default: 0] += v }
        let name = song.url.lastPathComponent
        // --songs: one line per song, for comparing with models/parity_music.py --paths.
        if args.contains("--songs") {
            print("SONG\t\(song.path)\t\(r.tempo.bpm.map { String(format: "%.2f", $0) } ?? "-")\t\(song.bpm.map { String(format: "%.2f", $0) } ?? "-")\t"
                  + "\(r.tempo.beatsPerBar.map(String.init) ?? "-")\t\(r.key?.key.shortName ?? "-")\t\(r.tempo.beats.count)")
        }
        if let a = r.tempo.bpm, let b = song.bpm {
            bpmBoth += 1
            let ratio = a / b
            if abs(ratio - 1) <= 0.02 { bpmClose += 1 } else {
                if [0.5, 2, 2.0 / 3, 1.5].contains(where: { abs(ratio / $0 - 1) <= 0.02 }) { octave += 1 }
                misses.append(String(format: "  BPM %.2f vs %.2f (%@ vs %@): %@", a, b, r.tempo.stability, song.tempoStability ?? "-", name))
            }
            if abs(a - b) < 0.015 { bpmExact += 1 }
        } else if r.tempo.bpm != nil || song.bpm != nil {
            misses.append("  BPM \(r.tempo.bpm.map { String(format: "%.2f", $0) } ?? "none") vs \(song.bpm.map { String(format: "%.2f", $0) } ?? "none"): \(name)")
        }
        if r.tempo.stability == song.tempoStability { steady += 1 }
        if let b = song.beatsPerBar {
            barsBoth += 1
            if r.tempo.beatsPerBar == b { bars += 1 }
        }
        if let a = r.key?.key, let b = song.key {
            keyBoth += 1
            if a == b { keySame += 1 } else {
                if a == b.relative { keyRelative += 1 } else if b.mixesWith.contains(a) { keyFifth += 1 }
                misses.append(String(format: "  key %@ %.2f vs %@ %.2f: %@", a.name, r.key!.confidence, b.name, song.keyConfidence ?? 0, name))
            }
            if let c = song.keyConfidence { confidenceDiff.append(abs(r.key!.confidence - c)) }
        }
        if n % 25 == 0 { print("\(n)/\(songs.count)") }
    }
    func pct(_ k: Int, _ of: Int) -> String { String(format: "%.1f%% (%d/%d)", 100 * Double(k) / Double(max(1, of)), k, of) }
    let wall = Date().timeIntervalSince(started)
    print(String(format: "\n%d songs, %.0f min of audio in %.0f s (decode %.0f s, spectrogram %.0f s, beats %.0f s, key %.0f s)",
                 n, audioSeconds / 60, wall, decodeTime, timings["spectrogram"] ?? 0, timings["beats"] ?? 0, timings["key"] ?? 0))
    print("BPM within 2%: \(pct(bpmClose, bpmBoth)), equal to 0.01: \(pct(bpmExact, bpmBoth)); the rest half/double/×1.5: \(octave)")
    print("Steadiness the same: \(pct(steady, n)); beats per bar the same: \(pct(bars, barsBoth))")
    print("Key the same: \(pct(keySame, keyBoth)); relative major/minor \(keyRelative), a fifth away \(keyFifth)")
    if !confidenceDiff.isEmpty {
        let s = confidenceDiff.sorted()
        print(String(format: "Key confidence |Δ|: median %.4f, p95 %.4f, max %.4f", s[s.count / 2], s[s.count * 95 / 100], s.last!))
    }
    if !misses.isEmpty { print("\nDifferences:"); misses.forEach { print($0) } }
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
