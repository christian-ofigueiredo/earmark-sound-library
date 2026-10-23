import Foundation
import Testing
@testable import EarmarkCore

@Suite struct UCSTests {
    let ucs = UCSCatalog.shared

    @Test func bundledListIsComplete() {
        #expect(ucs.entries.count == 753)
        #expect(ucs.categories.count == 82)
        #expect(ucs.entry(catID: "whsh")?.label == "SWOOSHES / WHOOSH")
    }

    @Test(arguments: [
        ("WHSH_Heavy Whoosh 01_SLAB_Lib", "WHSH"),
        ("AMBFORST_Birds_SLAB_Lib", "AMBForst"),
        ("rain_01", nil),
        ("Test_take", nil),
    ] as [(String, String?)])
    func filenameRules(stem: String, expected: String?) {
        #expect(ucs.parseFilename(stem)?.entry.catID == expected)
    }

    @Test func folderAndCategoryText() {
        #expect(ucs.entry(folderName: "WHSH")?.catID == "WHSH")
        #expect(ucs.entry(folderName: "AMBForst_Woods")?.catID == "AMBForst")
        #expect(ucs.entry(folderName: "SWOOSHES-WHOOSH")?.catID == "WHSH")
        #expect(ucs.entry(folderName: "test") == nil)
        #expect(ucs.entry(folderName: "Fire") == nil)
        #expect(ucs.entry(category: "designed", subcategory: "impact")?.catID == "DSGNImpt")
    }
}

@Suite struct MetadataTests {
    @Test func readsSoundminerStyleWAV() throws {
        let dir = TestFiles.tempDir()
        let url = dir.appendingPathComponent("Pack/Some Whoosh.wav")
        TestFiles.write(TestFiles.wav(seconds: 0.5, extra: [
            TestFiles.chunk("bext", TestFiles.bext(description: "Deep whoosh, bext text", originator: "Vendor Co")),
            TestFiles.chunk("iXML", TestFiles.ixml([("CATID", "WHSH"), ("FXNAME", "Deep Whoosh 01"),
                                                    ("DESCRIPTION", "Deep whoosh from iXML"), ("KEYWORDS", "whoosh, deep")])),
            TestFiles.chunk("LIST", TestFiles.info([("INAM", "Info title"), ("IGNR", "Sound Clip")])),
        ]), to: url)
        let raw = MetadataReader.read(url: url)
        #expect(raw.container == "RIFF")
        #expect(raw.technical.sampleRate == 48000)
        #expect(raw.technical.channels == 1)
        #expect(abs((raw.technical.duration ?? 0) - 0.5) < 0.001)
        #expect(raw.bext["Originator"] == "Vendor Co")
        #expect(raw.ixml["BWFXML/USER/CATID"] == "WHSH")
        let n = MetadataNormalizer.normalize(raw, url: url)
        #expect(n.ucs?.catID == "WHSH")
        #expect(n.ucs?.source.hasPrefix("iXML") == true)
        #expect(n[.description] == "Deep whoosh from iXML")   // iXML wins over bext
        #expect(n[.fxName] == "Deep Whoosh 01")
        #expect(n[.manufacturer] == "Vendor Co")
        #expect(n[.category] == "SWOOSHES")
    }

    @Test func ignoresJunkDescriptions() {
        let dir = TestFiles.tempDir()
        let url = dir.appendingPathComponent("Clicks_01.wav")
        TestFiles.write(TestFiles.wav(extra: [TestFiles.chunk("LIST", TestFiles.info([("ICMT", "www.example-download-site.com")]))]), to: url)
        let n = MetadataNormalizer.normalize(MetadataReader.read(url: url), url: url)
        #expect(n[.description] == nil)
        #expect(MetadataNormalizer.isJunk("GET MORE ASSETS - SOMEWHERE"))
        #expect(MetadataNormalizer.isJunk("0000007D6750434D2D44313030000000000000"))
        #expect(!MetadataNormalizer.isJunk("Metallic strike with a long ring-out."))
    }

    @Test func readsAIFF() {
        let dir = TestFiles.tempDir()
        let url = dir.appendingPathComponent("tone.aif")
        TestFiles.write(TestFiles.aiff(seconds: 1.0, name: "Tone A"), to: url)
        let raw = MetadataReader.read(url: url)
        #expect(raw.container == "AIFF")
        #expect(raw.technical.sampleRate == 44100)
        #expect(abs((raw.technical.duration ?? 0) - 1.0) < 0.001)
        #expect(raw.aiff["Title"] == "Tone A")
    }

    @Test func ucsFromFilenameWhenNoChunks() {
        let dir = TestFiles.tempDir()
        let url = dir.appendingPathComponent("DSGNImpt_Low Thud 03_SLAB_PackB.wav")
        TestFiles.write(TestFiles.wav(), to: url)
        let n = MetadataNormalizer.normalize(MetadataReader.read(url: url), url: url)
        #expect(n.ucs?.catID == "DSGNImpt")
        #expect(n.ucs?.source == "UCS filename")
        #expect(n[.fxName] == "Low Thud 03")
    }
}

@Suite struct ScannerTests {
    @Test func scansReadOnlyAndSkipsHiddenFiles() async throws {
        let root = TestFiles.tempDir()
        let files = ["A/WHSH_One_X_Y.wav", "A/B/plain.wav", "C/song.aif"]
        for f in files {
            let data = f.hasSuffix(".aif") ? TestFiles.aiff(seconds: 0.2, name: "x") : TestFiles.wav(seconds: 0.2)
            TestFiles.write(data, to: root.appendingPathComponent(f))
        }
        TestFiles.write(Data("junk".utf8), to: root.appendingPathComponent("A/._WHSH_One_X_Y.wav"))
        TestFiles.write(TestFiles.wav(), to: root.appendingPathComponent(".hidden/skip.wav"))
        TestFiles.write(Data("notes".utf8), to: root.appendingPathComponent("A/readme.txt"))

        func snapshot() throws -> [String: Date] {
            var out: [String: Date] = [:]
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])!
            for case let u as URL in e { out[u.path] = try u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            return out
        }
        let before = try snapshot()
        let sounds = await LibraryScanner().scan(root: root)
        #expect(sounds.count == 3)
        #expect(sounds.first { $0.path.hasSuffix("WHSH_One_X_Y.wav") }?.metadata.ucs?.catID == "WHSH")
        #expect(sounds.allSatisfy { $0.fingerprint != nil })
        #expect(try snapshot() == before)   // nothing added, nothing touched
    }

    @Test func fingerprintFollowsContentNotName() throws {
        let root = TestFiles.tempDir()
        let a = root.appendingPathComponent("a.wav"), b = root.appendingPathComponent("renamed.wav")
        TestFiles.write(TestFiles.wav(seconds: 2), to: a)
        TestFiles.write(TestFiles.wav(seconds: 2), to: b)
        TestFiles.write(TestFiles.wav(seconds: 3), to: root.appendingPathComponent("other.wav"))
        #expect(Fingerprint.of(url: a) == Fingerprint.of(url: b))
        #expect(Fingerprint.of(url: a) != Fingerprint.of(url: root.appendingPathComponent("other.wav")))
    }
}

@Suite struct MusicKeyTests {
    @Test(arguments: [
        ("Am", 9, true), ("A minor", 9, true), ("C#m", 1, true), ("Dbmaj", 1, false), ("B♭m", 10, true),
        ("8A", 9, true), ("08B", 0, false), ("1d", 0, false), ("1m", 9, true), ("G", 7, false), ("Eb minor", 3, true),
    ] as [(String, Int, Bool)])
    func parses(text: String, pc: Int, minor: Bool) {
        #expect(MusicKey(parsing: text) == MusicKey(pitchClass: pc, minor: minor))
    }

    @Test func rejectsNonsense() {
        #expect(MusicKey(parsing: "nonsense") == nil)
        #expect(MusicKey(parsing: "") == nil)
    }

    @Test func camelotAndRelatives() {
        #expect(MusicKey(pitchClass: 0, minor: false).camelot == "8B")
        #expect(MusicKey(pitchClass: 9, minor: true).camelot == "8A")
        #expect(MusicKey(pitchClass: 6, minor: false).camelot == "2B")
        #expect(MusicKey(pitchClass: 9, minor: true).relative == MusicKey(pitchClass: 0, minor: false))
        #expect(MusicKey(pitchClass: 4, minor: true).name == "E minor")
        let mix = Set(MusicKey(pitchClass: 9, minor: true).mixesWith.map(\.camelot))
        #expect(mix == ["8A", "9A", "7A", "8B"])
    }
}

@Suite struct DatabaseTests {
    @Test func soundsAreReplacedNotDuplicated() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(), to: root.appendingPathComponent("TSK-03/Footsteps/one.wav"))
        TestFiles.write(TestFiles.wav(), to: root.appendingPathComponent("two.wav"))
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        let scan1 = await LibraryScanner().scan(root: root)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: scan1)
        let first = try db.sounds()
        #expect(first.count == 2)
        #expect(first.contains { $0.folder == "TSK-03/Footsteps" })
        try FileManager.default.removeItem(at: root.appendingPathComponent("two.wav"))
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let second = try db.sounds()
        #expect(second.count == 1)
        #expect(second[0].id == first.first { $0.fileName == "one.wav" }?.id)
        #expect(try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil).id == lib.id)
        try db.removeLibrary(id: lib.id!)
        #expect(try db.sounds().isEmpty)
    }

    @Test func soundsKeepTheirIdThroughRenamesAndReAdding() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("A/one.wav"))
        TestFiles.write(TestFiles.wav(seconds: 2), to: root.appendingPathComponent("two.wav"))
        var lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let ids = Dictionary(uniqueKeysWithValues: try db.sounds().map { ($0.fileName, $0.id!) })

        // Moved and renamed: same content, same id.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("A/one.wav"),
                                         to: root.appendingPathComponent("B/renamed.wav"))
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let moved = try db.sounds()
        #expect(moved.count == 2)
        #expect(moved.first { $0.fileName == "renamed.wav" }?.id == ids["one.wav"])
        #expect(moved.first { $0.fileName == "renamed.wav" }?.folder == "B")

        // Removed from Earmark, then added again: ids come back.
        try db.removeLibrary(id: lib.id!)
        #expect(try db.sounds().isEmpty)
        lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let back = try db.sounds()
        #expect(back.first { $0.fileName == "renamed.wav" }?.id == ids["one.wav"])
        #expect(back.first { $0.fileName == "two.wav" }?.id == ids["two.wav"])

        // A file deleted on disk and later restored also gets its id back.
        let two = root.appendingPathComponent("two.wav"), saved = try Data(contentsOf: two)
        try FileManager.default.removeItem(at: two)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        #expect(try db.sounds().count == 1)
        TestFiles.write(saved, to: two)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        #expect(try db.sounds().first { $0.fileName == "two.wav" }?.id == ids["two.wav"])
    }

    @Test func formatTwinsKeepTheBestCopy() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("Pack (MP3,WAV)/Pack - WAV/Hits/01 Hit.wav"))
        TestFiles.write(Data("not really an mp3".utf8), to: root.appendingPathComponent("Pack (MP3,WAV)/Pack - MP3/Hits/01 Hit.mp3"))
        // Same name and folder pattern, clearly different length: a different sound.
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("Other/Long.wav"))
        TestFiles.write(TestFiles.aiff(seconds: 3, name: "x"), to: root.appendingPathComponent("Other/long.aif"))
        // Same name in an unrelated folder: not a twin.
        TestFiles.write(Data("mp3".utf8), to: root.appendingPathComponent("Elsewhere/01 Hit.mp3"))
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let sounds = try db.sounds()
        func id(_ suffix: String) -> Int64 { sounds.first { $0.path.hasSuffix(suffix) }!.id! }

        let groups = FormatTwins.group(sounds)
        #expect(groups.hidden == [id("Pack - MP3/Hits/01 Hit.mp3")])
        #expect(groups.alternates == [id("Pack - WAV/Hits/01 Hit.wav"): [id("Pack - MP3/Hits/01 Hit.mp3")]])
        #expect(FormatTwins.normalizedFolder("Pack (MP3,WAV)/Pack - WAV/Hits") == "pack/pack/hits")
    }

    @Test func importsPhase0MusicAnalysis() throws {
        let db = try LibraryDatabase(path: nil)
        let lib = try db.addLibrary(kind: .music, path: "/Music/Liked", bookmark: nil)
        try db.replaceSongs(libraryId: lib.id!, root: URL(fileURLWithPath: "/Music/Liked"), files: [
            SongFile(path: "/Music/Liked/01 Loser.mp3", fileSize: 1000, modified: Date(), title: "Loser"),
            SongFile(path: "/Music/Liked/sub/02 Dragonborn.mp3", fileSize: 2000, modified: Date()),
            SongFile(path: "/Music/Liked/03 Untouched.mp3", fileSize: 3000, modified: Date()),
        ])
        let json = """
        {"format": "soundlab-music-analysis", "version": 1, "tracks": [
          {"file": "01 Loser.mp3", "path": "/Volumes/Old/Liked/01 Loser.mp3", "size": 1000, "bpm": 83.0,
           "bpm_range": [82.9, 83.1], "tempo_stability": "steady", "beats_per_bar": 4, "key_pc": 5, "key_minor": true,
           "key_confidence": 0.84, "key_second_opinion": "F minor"},
          {"file": "sub/02 Dragonborn.mp3", "path": "/elsewhere/02 Dragonborn.mp3", "size": 2000, "bpm": 2.63,
           "beats_per_bar": 1, "key_pc": 11, "key_minor": true, "key_confidence": 0.51}
        ]}
        """
        let entries = try Phase0MusicImport.read(Data(json.utf8))
        #expect(entries.count == 2)
        #expect(entries[1].analysis.bpm == nil)          // 2.6 BPM is impossible: dropped
        #expect(entries[1].analysis.beatsPerBar == nil)  // "1 beat per bar" dropped
        #expect(try db.applySongAnalysis(entries) == 2)  // matched by file name + size
        let songs = try db.songs()
        let loser = songs.first { $0.fileName == "01 Loser.mp3" }!
        #expect(loser.bpm == 83.0)
        #expect(loser.key?.name == "F minor")
        #expect(loser.key?.camelot == "4A")
        #expect(songs.first { $0.fileName == "03 Untouched.mp3" }?.bpm == nil)
        // a later rescan keeps the analysis
        try db.replaceSongs(libraryId: lib.id!, root: URL(fileURLWithPath: "/Music/Liked"), files: [
            SongFile(path: "/Music/Liked/01 Loser.mp3", fileSize: 1000, modified: Date(), title: "Loser"),
        ])
        #expect(try db.songs().map(\.bpm) == [83.0])
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: (any Error).self) { try Phase0MusicImport.read(Data(#"{"format": "something-else", "tracks": []}"#.utf8)) }
    }
}
