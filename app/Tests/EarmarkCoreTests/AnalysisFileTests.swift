import Foundation
import Testing
@testable import EarmarkCore

/// Analysis files (AnalysisFiles): what Earmark worked out, taken to "another Mac" (a second
/// database whose libraries are elsewhere, with files moved, renamed and changed).
@Suite struct AnalysisFileTests {
    static let clap = (0 ..< 512).map { Float($0) / 512 }
    static let peav = (0 ..< 1024).map { -Float($0) / 1024 }

    /// A sound library at `root` with these files (relative path → seconds of silence: same
    /// seconds, same content).
    static func soundLibrary(_ db: LibraryDatabase, at root: URL, _ files: [String: Double]) async throws -> Library {
        for (path, seconds) in files { TestFiles.write(TestFiles.wav(seconds: seconds), to: root.appendingPathComponent(path)) }
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        return lib
    }

    static func roundTrip(_ file: AnalysisFile) throws -> AnalysisFile { try AnalysisFile.read(try file.encoded()) }

    @Test func soundsTravelByContentAndOnlyFillGaps() async throws {
        let here = try LibraryDatabase(path: nil), there = try LibraryDatabase(path: nil)
        let lib = try await Self.soundLibrary(here, at: TestFiles.tempDir(), ["Pack/one.wav": 1, "Pack/two.wav": 2])
        for s in try here.sounds() {
            try here.save([SoundFacts(soundId: s.id!, fingerprint: s.fingerprint, loudness: .init(integrated: -20, peak: -1))])
            try here.save([SoundEmbedding(soundId: s.id!, model: "clap-general", fingerprint: s.fingerprint, vector: Self.clap),
                           SoundEmbedding(soundId: s.id!, model: "pe-av-large", fingerprint: s.fingerprint, vector: Self.peav)])
        }
        try here.save([FolderRule(libraryId: lib.id!, folder: "Pack", catID: "AMBForst")])
        let one = try #require(try here.sounds().first { $0.fileName == "one.wav" })
        try here.setSoundCategory([(one.id!, one.fingerprint)], catID: "DOORWood")
        // The other Mac: one.wav moved and renamed, two.wav changed (other content).
        let theirs = try await Self.soundLibrary(there, at: TestFiles.tempDir(), ["Moved/uno.wav": 1, "Pack/two.wav": 3])

        let file = try Self.roundTrip(try here.analysisFile(for: lib, includeEmbeddings: true))
        #expect(file.sounds?.count == 2 && file.folderCategories == [.init(folder: "Pack", catID: "AMBForst")])
        let report = try there.importAnalysis(file)
        #expect(report.sounds == 2 && report.soundsMatched == 1 && report.facts == 1 && report.embeddings == 2)
        #expect(report.folderCategories == 1 && report.soundCategories == 1)
        let uno = try #require(try there.sounds().first { $0.fileName == "uno.wav" })
        #expect(try there.soundCategoryChoices()[uno.id!]?.catID == "DOORWood")
        #expect(try there.soundCategoryChoices()[uno.id!]?.byOwner == true)
        let two = try #require(try there.sounds().first { $0.fileName == "two.wav" })
        #expect(try there.soundFacts()[uno.id!]?.loudness == -20)
        #expect(try there.soundFacts()[uno.id!]?.isCurrent(for: uno) == true)
        #expect(try there.embedding(soundId: uno.id!, model: "clap-general")?.values == Self.clap)   // bit-exact
        #expect(try there.embedding(soundId: uno.id!, model: "pe-av-large")?.values == Self.peav)
        #expect(SoundEmbedding.isCurrent(try there.embeddingStatus(model: "pe-av-large")[uno.id!], model: "pe-av-large", for: uno))
        #expect(try there.soundFacts()[two.id!] == nil)   // changed: analysed again there, as usual
        #expect(try there.folderRules() == [FolderRule(libraryId: theirs.id!, folder: "Pack", catID: "AMBForst",
                                                        createdAt: try there.folderRules()[0].createdAt)])
        // A second import adds nothing.
        #expect(try there.importAnalysis(file).soundCategories == 0)
        #expect(try there.importAnalysis(file).facts == 0)
        #expect(try there.importAnalysis(file).embeddings == 0)
    }

    @Test func localResultsAndChoicesWin() async throws {
        let here = try LibraryDatabase(path: nil), there = try LibraryDatabase(path: nil)
        let lib = try await Self.soundLibrary(here, at: TestFiles.tempDir(), ["Pack/one.wav": 1])
        let mine = try here.sounds()[0]
        try here.save([SoundFacts(soundId: mine.id!, fingerprint: mine.fingerprint, loudness: .init(integrated: -20, peak: -1))])
        try here.save([FolderRule(libraryId: lib.id!, folder: "Pack", catID: "AMBForst")])
        let theirs = try await Self.soundLibrary(there, at: TestFiles.tempDir(), ["Pack/one.wav": 1])
        let s = try there.sounds()[0]
        try there.save([SoundFacts(soundId: s.id!, fingerprint: s.fingerprint, loudness: .init(integrated: -30, peak: -6))])
        try there.save([FolderRule(libraryId: theirs.id!, folder: "Pack", catID: "AIRBrst")])
        let report = try there.importAnalysis(try Self.roundTrip(try here.analysisFile(for: lib, includeEmbeddings: false)))
        #expect(report.soundsMatched == 1 && report.facts == 0 && report.folderCategories == 0)
        #expect(try there.soundFacts()[s.id!]?.loudness == -30)
        #expect(try there.folderRules().map(\.catID) == ["AIRBrst"])
    }

    @Test func writtenFileIsTheSameAsTheOneBuiltInMemory() async throws {
        let db = try LibraryDatabase(path: nil)
        let lib = try await Self.soundLibrary(db, at: TestFiles.tempDir(), ["Pack/one.wav": 1, "Pack/two.wav": 2, "b.wav": 3])
        for s in try db.sounds() {
            try db.save([SoundFacts(soundId: s.id!, fingerprint: s.fingerprint, loudness: .init(integrated: -20, peak: -1))])
            try db.save([SoundEmbedding(soundId: s.id!, model: "clap-general", fingerprint: s.fingerprint, vector: Self.clap)])
        }
        try db.save([FolderRule(libraryId: lib.id!, folder: "Pack", catID: "AMBForst")])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = TestFiles.tempDir().appendingPathComponent(AnalysisFile.fileName(for: lib))
        for _ in 0 ..< 2 {   // the second time over the first
            let bytes = try db.writeAnalysisFile(for: lib, includeEmbeddings: true, to: url, exportedAt: date)
            let data = try Data(contentsOf: url)
            #expect(bytes == data.count)
            let written = try AnalysisFile.read(data), built = try db.analysisFile(for: lib, includeEmbeddings: true, exportedAt: date)
            #expect(written.sounds == built.sounds && written.sounds?.count == 3)
            #expect(written.folderCategories == built.folderCategories && written.library == built.library)
            #expect(written.exportedAt == built.exportedAt)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [url.lastPathComponent])
    }

    @Test func embeddingsCanBeLeftOut() async throws {
        let db = try LibraryDatabase(path: nil)
        let lib = try await Self.soundLibrary(db, at: TestFiles.tempDir(), ["a.wav": 1])
        let s = try db.sounds()[0]
        try db.save([SoundEmbedding(soundId: s.id!, model: "clap-general", fingerprint: s.fingerprint, vector: Self.clap)])
        #expect(try db.analysisFile(for: lib, includeEmbeddings: false).sounds?.isEmpty == true)
        #expect(try db.analysisFile(for: lib, includeEmbeddings: true).sounds?.first?.embeddings?["clap-general"] != nil)
    }

    @Test func songsTravelWithSourceAndCorrections() async throws {
        let here = try LibraryDatabase(path: nil), there = try LibraryDatabase(path: nil)
        let a = TestFiles.tempDir(), b = TestFiles.tempDir()
        for (path, seconds) in ["s1.wav": 1.0, "s2.wav": 2, "sub/s3.wav": 3] {
            TestFiles.write(TestFiles.wav(seconds: seconds), to: a.appendingPathComponent(path))
        }
        // The other Mac: s1 moved, s2 in place, s3 missing.
        TestFiles.write(TestFiles.wav(seconds: 1), to: b.appendingPathComponent("other/s1.wav"))
        TestFiles.write(TestFiles.wav(seconds: 2), to: b.appendingPathComponent("s2.wav"))
        func songs(_ root: URL, _ paths: [String]) -> [SongFile] {
            paths.map { p in
                let url = root.appendingPathComponent(p)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                return SongFile(path: url.path, fileSize: size, modified: Date())
            }
        }
        let lib = try here.addLibrary(kind: .music, path: a.path, bookmark: nil)
        try here.replaceSongs(libraryId: lib.id!, root: a, files: songs(a, ["s1.wav", "s2.wav", "sub/s3.wav"]))
        let ids = Dictionary(uniqueKeysWithValues: try here.songs().map { ($0.fileName, $0) })
        _ = try here.saveSongAnalysis([
            (ids["s1.wav"]!.id!, SongAnalysis(bpm: 61.75, key: MusicKey(pitchClass: 11, minor: true), keyConfidence: 0.8, source: "Phase 0")),
            (ids["s2.wav"]!.id!, SongAnalysis(bpm: 90, source: "Earmark")),
            (ids["s3.wav"]!.id!, SongAnalysis(bpm: 100, source: "Earmark")),
        ])
        let s1 = try here.songs().first { $0.fileName == "s1.wav" }!
        try here.setSongCorrections([(s1.path, s1.correction(after: .doubleTempo))])

        let theirLib = try there.addLibrary(kind: .music, path: b.path, bookmark: nil)
        try there.replaceSongs(libraryId: theirLib.id!, root: b, files: songs(b, ["other/s1.wav", "s2.wav"]))
        let theirS2 = try there.songs().first { $0.fileName == "s2.wav" }!
        _ = try there.saveSongAnalysis([(theirS2.id!, SongAnalysis(bpm: 45, source: "Earmark"))])   // already there

        let file = try Self.roundTrip(try here.analysisFile(for: lib, includeEmbeddings: true))
        #expect(file.songs?.count == 3 && file.songs?.allSatisfy { $0.fingerprint != nil } == true)
        let report = try there.importAnalysis(file)
        #expect(report.songs == 3 && report.songsMatched == 2 && report.songAnalyses == 1 && report.corrections == 1)
        let theirS1 = try there.songs().first { $0.fileName == "s1.wav" }!
        #expect(theirS1.bpm == 61.75 && theirS1.analysisSource == "Phase 0" && theirS1.keyConfidence == 0.8)
        #expect(theirS1.key == MusicKey(pitchClass: 11, minor: true))
        #expect(try there.songCorrections().map(\.path) == [theirS1.path])
        #expect(try there.songCorrections().first?.bpm == 123.5)
        #expect(try there.songs().first { $0.fileName == "s2.wav" }?.bpm == 45)   // theirs stays
    }

    @Test func songsWithoutFingerprintMatchByPlaceAndSize() throws {
        let db = try LibraryDatabase(path: nil)
        let lib = try db.addLibrary(kind: .music, path: "/Music/Liked", bookmark: nil)
        try db.replaceSongs(libraryId: lib.id!, root: URL(fileURLWithPath: "/Music/Liked"), files: [
            SongFile(path: "/Music/Liked/sub/a.mp3", fileSize: 10, modified: Date()),
            SongFile(path: "/Music/Liked/b.mp3", fileSize: 10, modified: Date()),
        ])
        var file = AnalysisFile(exportedAt: Date(), library: .init(kind: .music, name: "Liked", path: "/elsewhere"))
        file.songs = [.init(path: "sub/a.mp3", size: 10, fingerprint: nil,
                            analysis: .init(bpm: 120, source: "Phase 0"), correction: nil)]
        let report = try db.importAnalysis(file, fingerprint: { _ in nil })
        #expect(report.songsMatched == 1 && report.songAnalyses == 1)
        #expect(try db.songs().map(\.bpm) == [nil, 120])   // b.mp3, sub/a.mp3 (by path)
    }

    @Test func readsOnlyAnalysisFilesAndRefusesLibraryFolders() throws {
        #expect(throws: AnalysisFile.ReadError.self) { try AnalysisFile.read(Data(#"{"format": "soundlab-music-analysis", "tracks": []}"#.utf8)) }
        let newer = #"{"format": "earmark-analysis", "version": 2, "exportedAt": "2026-10-26T00:00:00Z", "library": {"kind": "music", "name": "x", "path": "/x"}}"#
        #expect(throws: AnalysisFile.ReadError.self) { try AnalysisFile.read(Data(newer.utf8)) }
        #expect(AnalysisFile.formatOf(Data(#"{"format": "soundlab-music-analysis"}"#.utf8)) == "soundlab-music-analysis")
        let lib = Library(id: 1, kind: .sounds, path: "/Volumes/Banana 01/SoundFX", bookmark: nil, addedAt: Date())
        #expect(AnalysisFile.library(containing: URL(fileURLWithPath: "/Volumes/Banana 01/SoundFX/Exports"), in: [lib]) == lib)
        #expect(AnalysisFile.library(containing: URL(fileURLWithPath: "/Volumes/Banana 01/SoundFX"), in: [lib]) == lib)
        #expect(AnalysisFile.library(containing: URL(fileURLWithPath: "/Volumes/Banana 01/SoundFX Exports"), in: [lib]) == nil)
        #expect(AnalysisFile.fileName(for: lib) == "SoundFX.earmark-analysis.json")
    }
}
