import Foundation
import Testing
@testable import EarmarkCore

/// Tempo, key and beats per bar set by hand (SongCorrections).
@Suite struct SongCorrectionTests {
    static let bMinor = MusicKey(pitchClass: 11, minor: true)

    static func song(bpm: Double? = 61.75, key: MusicKey? = bMinor, beats: Int? = 4) -> SongRecord {
        var s = SongRecord(id: 1, libraryId: 1, path: "/Music/a.mp3", fileName: "a.mp3", folder: "", fileSize: 1,
                           modifiedAt: Date(timeIntervalSince1970: 0))
        s.bpm = bpm; s.bpmLow = bpm.map { $0 - 0.5 }; s.bpmHigh = bpm.map { $0 + 0.5 }; s.tempoStability = "steady"
        s.beatsPerBar = beats; s.keyPitchClass = key?.pitchClass; s.keyMinor = key?.minor; s.analysisSource = "Phase 0"
        return s
    }

    /// The song after an edit, as the app shows it.
    static func edit(_ s: SongRecord, _ e: SongEdit) -> SongRecord { s.applying(s.correction(after: e)) }

    @Test func doubleThenHalveGoesBackToTheAnalysis() {
        let s = Self.song()
        let doubled = Self.edit(s, .doubleTempo)
        #expect(doubled.bpm == 123.5 && doubled.bpmLow == 122.5 && doubled.bpmHigh == 124.5)
        #expect(doubled.analysed?.bpm == 61.75 && doubled.correction?.correctsTempo == true)
        #expect(doubled.key == Self.bMinor && doubled.correction?.correctsKey == false)
        let back = Self.edit(doubled, .halveTempo)
        #expect(back.bpm == 61.75 && back.correction == nil && back.analysed == nil)
        #expect(back == s)
    }

    @Test func typedTempoDropsTheRange() {
        let s = Self.edit(Self.song(), .setTempo(120))
        #expect(s.bpm == 120 && s.bpmLow == nil && s.bpmHigh == nil)
        #expect(s.uncorrected.bpmLow == 61.25)
        #expect(Self.edit(s, .setTempo(61.75)).correction == nil)   // typed back to the analysed value
    }

    @Test func relativeKeyTwiceIsNoCorrection() {
        let s = Self.edit(Self.song(), .relativeKey)
        #expect(s.key == MusicKey(pitchClass: 2, minor: false))   // D major
        #expect(s.key?.camelot == "10B" && s.analysed?.key == Self.bMinor)
        #expect(Self.edit(s, .relativeKey).correction == nil)
    }

    @Test func partsAreCorrectedAndRevertedOnTheirOwn() {
        var s = Self.edit(Self.song(), .setKey(MusicKey(pitchClass: 9, minor: true)))
        s = Self.edit(s, .setBeatsPerBar(3))
        s = Self.edit(s, .doubleTempo)
        #expect(s.key?.name == "A minor" && s.beatsPerBar == 3 && s.bpm == 123.5)
        s = Self.edit(s, .revertKey)
        #expect(s.key == Self.bMinor && s.beatsPerBar == 3 && s.bpm == 123.5)
        s = Self.edit(s, .revertBeatsPerBar)
        #expect(s.beatsPerBar == 4 && s.correction?.correctsTempo == true)
        #expect(Self.edit(s, .revertAll) == Self.song())
    }

    @Test func whatEachEditAllows() {
        let s = Self.song()
        #expect(!s.allows(.revertAll) && !s.allows(.revertTempo))
        #expect(!s.allows(.setKey(Self.bMinor)) && s.allows(.setKey(MusicKey(pitchClass: 0, minor: false))))
        #expect(!s.allows(.setBeatsPerBar(4)) && !s.allows(.setBeatsPerBar(5)) && s.allows(.setBeatsPerBar(3)))
        #expect(!Self.song(bpm: 30).allows(.halveTempo) && !Self.song(bpm: 210).allows(.doubleTempo))
        #expect(!s.allows(.setTempo(10)) && s.allows(.setTempo(20)))
        let none = Self.song(bpm: nil, key: nil, beats: nil)
        #expect(!none.allows(.doubleTempo) && !none.allows(.relativeKey) && none.allows(.setTempo(90)))
        #expect(Self.edit(s, .doubleTempo).allows(.revertTempo))
    }

    @Test func correctionsDontCountAsAnalysis() {
        var s = Self.song(bpm: nil, key: nil, beats: nil)
        s.analysisSource = nil
        let set = Self.edit(s, .setTempo(100))
        #expect(set.bpm == 100 && !set.isAnalysed)
    }

    @Test func correctionsSurviveRescansImportsAnalysisAndReAdding() throws {
        let db = try LibraryDatabase(path: nil)
        var lib = try db.addLibrary(kind: .music, path: "/Music/Liked", bookmark: nil)
        let files = [SongFile(path: "/Music/Liked/a.mp3", fileSize: 1, modified: Date()),
                     SongFile(path: "/Music/Liked/b.mp3", fileSize: 2, modified: Date())]
        try db.replaceSongs(libraryId: lib.id!, root: URL(fileURLWithPath: "/Music/Liked"), files: files)
        _ = try db.applySongAnalysis([.init(path: "/Music/Liked/a.mp3", fileName: "a.mp3", size: 1,
                                            analysis: SongAnalysis(bpm: 61.75, key: Self.bMinor, source: "Phase 0"))])
        func shown() throws -> [SongRecord] {
            SongCorrections.apply(Dictionary(uniqueKeysWithValues: try db.songCorrections().map { ($0.path, $0) }), to: try db.songs())
        }
        var a = try shown()[0]
        let b = try shown()[1]
        try db.setSongCorrections([(a.path, a.correction(after: .doubleTempo)), (b.path, b.correction(after: .setTempo(90)))])
        a = try shown()[0]
        #expect(a.bpm == 123.5 && a.uncorrected.bpm == 61.75)
        #expect(try db.songs()[0].bpm == 61.75)   // the stored analysis is untouched
        // a rescan, a new Phase 0 import and Earmark's own analysis leave it alone
        try db.replaceSongs(libraryId: lib.id!, root: URL(fileURLWithPath: "/Music/Liked"), files: files)
        _ = try db.applySongAnalysis([.init(path: "/Music/Liked/a.mp3", fileName: "a.mp3", size: 1,
                                            analysis: SongAnalysis(bpm: 62, key: Self.bMinor, source: "Phase 0"))])
        _ = try db.saveSongAnalysis([(try db.songs()[1].id!, SongAnalysis(bpm: 45, source: "Earmark"))])
        #expect(try shown().map(\.bpm) == [123.5, 90])
        #expect(try shown()[1].uncorrected.bpm == 45)
        // removed and added again
        try db.removeLibrary(id: lib.id!)
        lib = try db.addLibrary(kind: .music, path: "/Music/Liked", bookmark: nil)
        try db.replaceSongs(libraryId: lib.id!, root: URL(fileURLWithPath: "/Music/Liked"), files: files)
        #expect(try shown().map(\.bpm) == [123.5, 90])
        // reverting removes it
        try db.setSongCorrections([(a.path, nil)])
        #expect(try db.songCorrections().map(\.path) == ["/Music/Liked/b.mp3"])
    }
}
