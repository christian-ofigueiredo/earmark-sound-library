import EarmarkCore
import EarmarkEngine
import Foundation
import Testing

/// The library database through the Rust engine reads and writes as Swift's LibraryDatabase.
/// (On a real library: `earmark-parity enginedbread`, and `compare.py enginedb` on two copies.)
struct EngineDatabaseTests {
    let empty = try! JSONDecoder().decode(NormalizedMetadata.self, from: Data(#"{"fields":{},"sources":{}}"#.utf8))

    func scanned(_ n: Int) -> [ScannedSound] {
        (0 ..< n).map { (i: Int) -> ScannedSound in
            let path: String = "/Lib/Folder \(i % 3)/Sound é \(i).wav"
            let modified = Date(timeIntervalSince1970: 1_700_000_000.123456 + Double(i))
            let technical = AudioTechnical(sampleRate: 48_000, channels: 2, bitsPerSample: 24, duration: Double(i) + 0.5)
            let warnings: [String] = i == 2 ? ["odd chunk"] : []
            return ScannedSound(path: path, fileSize: Int64(1000 + i), modified: modified, fingerprint: "fp\(i)",
                                technical: technical, metadata: empty, warnings: warnings)
        }
    }

    @Test func sameAsSwift() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stores: [any LibraryStore] = [try LibraryDatabase(path: dir.appendingPathComponent("swift.sqlite").path),
                                          try EngineLibraryDatabase(path: dir.appendingPathComponent("engine.sqlite").path)]
        let when = Date(timeIntervalSinceReferenceDate: 785_000_000.5)
        var seen: [[String]] = []
        for db in stores {
            var out: [String] = []
            let lib = try db.addLibrary(kind: .sounds, path: "/Lib", bookmark: Data([9, 8, 7]))
            try db.replaceSounds(libraryId: lib.id!, root: URL(fileURLWithPath: "/Lib"), scanned: scanned(12))
            let sounds = try db.sounds()
            out.append(sounds.map { "\($0.id!) \($0.folder) \($0.fileName) \($0.modifiedAt.timeIntervalSinceReferenceDate)" }.joined(separator: ";"))
            try db.save(sounds.map { SoundFacts(soundId: $0.id!, fingerprint: $0.fingerprint,
                                                loudness: LoudnessMeter.Result(integrated: -20.25, peak: -0.5), analyzedAt: when) })
            try db.save(sounds.prefix(4).map { SoundEmbedding(soundId: $0.id!, model: "clap-general", fingerprint: $0.fingerprint,
                                                              vector: [0.25, -0.5, Float($0.id!)], analyzedAt: when) })
            out.append("\(try db.soundFacts().sorted { $0.key < $1.key }.map(\.value))")
            out.append("\(try db.vectors(model: "clap-general").map { "\($0.id) \($0.vector)" })")
            var streamed: [String] = []
            try db.forEachVectors(models: ["clap-general"]) { id, v in streamed.append("\(id) \(v)") }
            out.append(streamed.joined(separator: ";"))
            try db.setSoundCategory([(id: sounds[0].id!, fingerprint: sounds[0].fingerprint)], catID: "DOORWood")
            out.append("\(try db.soundCategoryChoices().mapValues(\.catID).sorted { $0.key < $1.key })")
            try db.save([FolderRule(libraryId: lib.id!, folder: "Folder 1", catID: "AMBForst", createdAt: when)])
            out.append("\(try db.folderRules())")
            let group = try db.newGroup(catID: "DOORWood", name: "Mine", sounds: [(id: sounds[1].id!, fingerprint: sounds[1].fingerprint)])
            try db.renameGroup(group, to: "Renamed")
            let snap = try db.soundGroupSnapshot()
            out.append("\(snap.groups) \(snap.membership) \(snap.memberFingerprints)")
            out.append("\(try db.libraries().map { "\($0.id!) \($0.kind) \($0.path) \([UInt8]($0.bookmark ?? Data()))" })")
            seen.append(out)
        }
        for (a, b) in zip(seen[0], seen[1]) { #expect(a == b) }
    }

    @Test func failuresCarryTheEnginesMessage() {
        #expect(throws: EngineDatabaseFailure.self) { try EngineLibraryDatabase(path: "/nonexistent/earmark.sqlite", readOnly: true) }
    }
}
