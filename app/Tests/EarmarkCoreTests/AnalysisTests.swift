import Foundation
import Testing
@testable import EarmarkCore

@Suite struct LoudnessTests {
    static func sine(dBFS: Double, seconds: Double, rate: Double, hz: Double = 1000) -> [Float] {
        let amp = pow(10, dBFS / 20), n = Int(seconds * rate)
        return (0 ..< n).map { Float(amp * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    static func measure(_ channels: [[Float]], rate: Double, chunk: Int = 4096) -> LoudnessMeter.Result {
        var meter = LoudnessMeter(sampleRate: rate, channels: channels.count)
        let frames = channels[0].count
        var start = 0
        while start < frames {
            let end = min(frames, start + chunk)
            meter.process(channels.map { Array($0[start ..< end]) })
            start = end
        }
        return meter.result
    }

    // EBU Tech 3341, cases 1 and 2: stereo 1 kHz sine at -23 / -33 dBFS reads -23 / -33 LUFS (±0.1).
    @Test(arguments: [(-23.0, 48000.0), (-33.0, 48000.0), (-23.0, 44100.0), (-23.0, 96000.0)])
    func stereoSine(level: Double, rate: Double) {
        let s = Self.sine(dBFS: level, seconds: 20, rate: rate)
        let r = Self.measure([s, s], rate: rate)
        #expect(abs(r.integrated! - level) <= 0.1)
        #expect(abs(r.peak! - level) <= 0.01)
    }

    // EBU Tech 3341, case 3: -36 dB for 10 s, -23 dB for 60 s, -36 dB for 10 s reads -23 LUFS.
    @Test func relativeGate() {
        let rate = 48000.0
        let s = Self.sine(dBFS: -36, seconds: 10, rate: rate) + Self.sine(dBFS: -23, seconds: 60, rate: rate)
            + Self.sine(dBFS: -36, seconds: 10, rate: rate)
        let r = Self.measure([s, s], rate: rate, chunk: 48000)
        #expect(abs(r.integrated! - -23) <= 0.1)
    }

    @Test func shortSoundsAndSilence() {
        let rate = 48000.0
        let blip = Self.sine(dBFS: -23, seconds: 0.2, rate: rate)
        let r = Self.measure([blip, blip], rate: rate)
        #expect(abs(r.integrated! - -23) <= 0.3)
        let silence = Self.measure([[Float](repeating: 0, count: 48000)], rate: rate)
        #expect(silence.integrated == nil && silence.peak == nil)
    }
}

@Suite struct GovernorTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { start.addingTimeInterval(s) }
    static let quiet = SystemSignals(userIdle: 2, otherCPU: 0.05, gpu: 0.02)
    static let idle = SystemSignals(userIdle: 600, otherCPU: 0.05, gpu: 0.02)

    @Test func rampsUpSlowlyAndBacksOffAtOnce() {
        var g = AnalysisGovernor(settings: .init(fullWorkers: 4))
        #expect(g.update(Self.quiet, now: Self.at(0)).isPaused)          // waits before starting
        #expect(g.update(Self.quiet, now: Self.at(59)).isPaused)
        #expect(g.update(Self.quiet, now: Self.at(60)) == AnalysisPace(workers: 1, reason: .userActive))
        #expect(g.update(Self.idle, now: Self.at(70)).workers == 1)       // idle, but not for long enough
        #expect(g.update(Self.idle, now: Self.at(130)) == AnalysisPace(workers: 4, reason: .idle))
        #expect(g.update(Self.quiet, now: Self.at(131)).workers == 1)     // user is back: at once
    }

    @Test func pausesWhileAnotherAppIsBusyWithHysteresis() {
        var g = AnalysisGovernor(settings: .init(fullWorkers: 4))
        g.update(Self.idle, now: Self.at(0)); g.update(Self.idle, now: Self.at(60))
        #expect(g.pace.workers == 4)
        let export = SystemSignals(userIdle: 900, otherCPU: 0.3, gpu: 0.8)   // Resolve rendering overnight
        #expect(g.update(export, now: Self.at(61)) == AnalysisPace(workers: 0, reason: .macBusy))
        // Load between the idle quiet and busy thresholds: stays paused.
        let middling = SystemSignals(userIdle: 900, otherCPU: 0.5, gpu: 0.5)
        #expect(g.update(middling, now: Self.at(500)).reason == .macBusy)
        // Quiet again: restarts only after the ramp-up time.
        #expect(g.update(Self.idle, now: Self.at(600)).isPaused)
        #expect(g.update(Self.idle, now: Self.at(660)).workers == 4)
    }

    @Test func resolveOpenBlocksOnlyWhileYouWork() {
        var g = AnalysisGovernor(settings: .init(fullWorkers: 4))
        let editing = SystemSignals(userIdle: 0, otherCPU: 0.1, gpu: 0.4)    // Resolve open, user editing
        #expect(g.update(editing, now: Self.at(0)).reason == .macBusy)
        let leftOpen = SystemSignals(userIdle: 900, otherCPU: 0.1, gpu: 0.4) // same, user away
        g.update(leftOpen, now: Self.at(1))
        #expect(g.update(leftOpen, now: Self.at(61)) == AnalysisPace(workers: 4, reason: .idle))
        #expect(g.update(editing, now: Self.at(62)).reason == .macBusy)        // user is back
        g.mode = .fullSpeed                                                     // and asks for it: at once
        #expect(g.update(editing, now: Self.at(63)) == AnalysisPace(workers: 4, reason: .requested))
    }

    @Test func modesAndSafetyLimits() {
        var g = AnalysisGovernor(mode: .idleOnly, settings: .init(fullWorkers: 4))
        #expect(g.target(for: Self.quiet) == AnalysisPace(workers: 0, reason: .waitingForIdle))
        g.mode = .paused
        #expect(g.update(Self.idle, now: Self.at(0)).reason == .pausedByUser)
        g.mode = .automatic
        #expect(g.update(Self.idle, now: Self.at(1)).workers == 4)          // resuming is immediate
        var hot = Self.idle; hot.thermal = .serious
        #expect(g.update(hot, now: Self.at(2)).reason == .hot)
        var battery = Self.idle; battery.onBattery = true
        #expect(g.target(for: battery).reason == .battery)
        g.mode = .fullSpeed                                   // asked for: runs on battery too
        #expect(g.target(for: battery) == AnalysisPace(workers: 4, reason: .requested))
        var lowPower = battery; lowPower.lowPowerMode = true  // but not in Low Power Mode
        #expect(g.target(for: lowPower).reason == .lowPower)
        var flat = battery; flat.batteryLevel = 0.19           // nor below 20% charge
        #expect(g.target(for: flat).reason == .battery)
        g.mode = .automatic
        var warm = Self.idle; warm.thermal = .fair
        #expect(g.target(for: warm).workers == 2)
    }
}

@Suite struct FactsTests {
    @Test func factsSurviveRemovingAndReAddingALibrary() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("a.wav"))
        var lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let sound = try db.sounds()[0]
        try db.save([SoundFacts(soundId: sound.id!, fingerprint: sound.fingerprint,
                                loudness: .init(integrated: -20, peak: -1))])
        try db.removeLibrary(id: lib.id!)
        lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let again = try db.sounds()[0]
        let facts = try db.soundFacts()[again.id!]
        #expect(facts?.loudness == -20)
        #expect(facts?.isCurrent(for: again) == true)
        var changed = again; changed.fingerprint = "other"
        #expect(facts?.isCurrent(for: changed) == false)
    }
}

@Suite struct EmbeddingStoreTests {
    @Test func embeddingsRoundTripAndSurviveReAdding() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("a.wav"))
        var lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let sound = try db.sounds()[0]
        let vector = (0 ..< 512).map { Float($0) / 512 }
        try db.save([SoundEmbedding(soundId: sound.id!, model: "clap-general", fingerprint: sound.fingerprint, vector: vector)])
        try db.removeLibrary(id: lib.id!)
        lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let again = try db.sounds()[0]
        #expect(try db.embedding(soundId: again.id!, model: "clap-general")?.values == vector)
        let status = try db.embeddingStatus(model: "clap-general")
        #expect(SoundEmbedding.isCurrent(status[again.id!], model: "clap-general", for: again))
        var changed = again; changed.fingerprint = "other"
        #expect(!SoundEmbedding.isCurrent(status[again.id!], model: "clap-general", for: changed))
        #expect(try db.embeddingStatus(model: "pe-av-large").isEmpty)
    }
}

@Suite struct SimilarityTests {
    static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / n }
    }

    @Test func nearestByCosineBestFirst() {
        let index = SimilarityIndex(vectors: [
            (1, Self.unit([1, 0, 0])), (2, Self.unit([0.9, 0.1, 0])), (3, Self.unit([0, 1, 0])),
            (4, Self.unit([0.7, 0.7, 0])), (5, Self.unit([-1, 0, 0])), (6, [1, 0]),   // wrong length: skipped
        ])
        #expect(index.count == 5)
        let r = index.nearest(to: 1, count: 3)
        #expect(r.map(\.id) == [2, 4, 3])
        #expect(r[0].score > r[1].score && r[1].score > r[2].score)
        #expect(index.nearest(to: 1, count: 3, excluding: [2]).map(\.id) == [4, 3, 5])
        #expect(index.nearest(to: 1, count: 10).count == 4)
        #expect(index.nearest(to: 99, count: 3).isEmpty)
    }

    @Test func vectorsComeBackFromTheDatabaseOnlyWhileCurrent() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("a.wav"))
        TestFiles.write(TestFiles.wav(seconds: 2), to: root.appendingPathComponent("b.wav"))
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let sounds = try db.sounds()
        try db.save([
            SoundEmbedding(soundId: sounds[0].id!, model: "clap-general", fingerprint: sounds[0].fingerprint, vector: [1, 0]),
            SoundEmbedding(soundId: sounds[1].id!, model: "clap-general", fingerprint: "stale", vector: [0, 1]),
        ])
        let v = try db.vectors(model: "clap-general")
        #expect(v.map(\.id) == [sounds[0].id!])
        #expect(v.first?.vector == [1, 0])
    }

    /// The sound map's vectors: sounds with a current vector from every model, in id order.
    @Test func vectorsFromSeveralModelsComeTogether() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        for (i, name) in ["a.wav", "b.wav", "c.wav"].enumerated() {
            TestFiles.write(TestFiles.wav(seconds: Double(i + 1)), to: root.appendingPathComponent(name))
        }
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        let s = try db.sounds().sorted { $0.id! < $1.id! }
        try db.save([
            SoundEmbedding(soundId: s[2].id!, model: "pe-av-large", fingerprint: s[2].fingerprint, vector: [3, 3, 3]),
            SoundEmbedding(soundId: s[2].id!, model: "clap-general", fingerprint: s[2].fingerprint, vector: [3]),
            SoundEmbedding(soundId: s[0].id!, model: "pe-av-large", fingerprint: s[0].fingerprint, vector: [1, 1, 1]),
            SoundEmbedding(soundId: s[0].id!, model: "clap-general", fingerprint: s[0].fingerprint, vector: [1]),
            SoundEmbedding(soundId: s[1].id!, model: "pe-av-large", fingerprint: s[1].fingerprint, vector: [2, 2, 2]),   // no CLAP
        ])
        var count = -1, got: [(Int64, [[Float]])] = []
        try db.forEachVectors(models: ["pe-av-large", "clap-general"], count: { count = $0 }) { got.append(($0, $1)) }
        #expect(count == 2)
        #expect(got.map(\.0) == [s[0].id!, s[2].id!])
        #expect(got.first?.1 == [[1, 1, 1], [1]])
    }

    @Test func pageBuffersStartAsZerosAndHoldWhatsWritten() {
        let page = PageBuffer(count: 1_000_000)
        #expect(page.count == 1_000_000)
        page.withFloats { f in
            #expect(f[0] == 0 && f[999_999] == 0)
            f[123_456] = 4.5
        }
        #expect(page.withFloats { $0[123_456] } == 4.5)
        #expect(PageBuffer(count: 0).count == 0)
    }
}

@Suite struct FolderRuleTests {
    @Test func rulesFillOnlyUncategorisedSoundsFromTheNearestFolder() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("Pack/Footsteps/Concrete/a.wav"))
        TestFiles.write(TestFiles.wav(seconds: 2), to: root.appendingPathComponent("Pack/Footsteps/b.wav"))
        TestFiles.write(TestFiles.wav(seconds: 3), to: root.appendingPathComponent("Pack/Footsteps/WHSH_Vendor_X_Y.wav"))
        TestFiles.write(TestFiles.wav(seconds: 4), to: root.appendingPathComponent("Other/c.wav"))
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        try db.save([FolderRule(libraryId: lib.id!, folder: "Pack/Footsteps", catID: "FEETHmn")])
        let sounds = FolderRules.apply(try db.folderRules(), to: try db.sounds())
        func s(_ name: String) -> SoundRecord { sounds.first { $0.fileName == name }! }
        #expect(s("a.wav").catID == "FEETHmn")                          // subfolder: nearest rule above
        #expect(s("a.wav").categorySource == FolderRules.source)
        #expect(s("b.wav").category == "FOOTSTEPS")
        #expect(s("WHSH_Vendor_X_Y.wav").catID == "WHSH")              // the vendor's UCS wins
        #expect(s("c.wav").catID == nil)
        try db.removeFolderRule(libraryId: lib.id!, folder: "Pack/Footsteps")
        #expect(try db.folderRules().isEmpty)
    }

    @Test func guessesFillWhatNeitherFilesNorTheUserCategorised() async throws {
        let db = try LibraryDatabase(path: nil)
        let root = TestFiles.tempDir()
        TestFiles.write(TestFiles.wav(seconds: 1), to: root.appendingPathComponent("Pack/Hits/a.wav"))
        TestFiles.write(TestFiles.wav(seconds: 2), to: root.appendingPathComponent("Pack/Hits/Metal/b.wav"))
        TestFiles.write(TestFiles.wav(seconds: 3), to: root.appendingPathComponent("Pack/Whooshes/c.wav"))
        TestFiles.write(TestFiles.wav(seconds: 4), to: root.appendingPathComponent("Pack/Whooshes/WHSH_Vendor_X_Y.wav"))
        let lib = try db.addLibrary(kind: .sounds, path: root.path, bookmark: nil)
        try db.replaceSounds(libraryId: lib.id!, root: root, scanned: await LibraryScanner().scan(root: root))
        func guess(_ folder: String, _ catID: String) -> FolderGuess {
            FolderGuess(libraryId: lib.id!, folder: folder, catID: catID, alternatives: ["DSGNMisc"], reason: "test",
                        isUnsure: false, analysed: 0)
        }
        try db.updateGuesses(saving: [guess("Pack/Hits/Metal", "METLImpt"), guess("Pack/Whooshes", "DSGNWhsh")], removing: [])
        try db.save([FolderRule(libraryId: lib.id!, folder: "Pack/Hits", catID: "DSGNImpt")])
        let sounds = FolderRules.apply(try db.folderRules(), guesses: try db.folderGuesses(), to: try db.sounds())
        func s(_ name: String) -> SoundRecord { sounds.first { $0.fileName == name }! }
        #expect(s("a.wav").catID == "DSGNImpt")                                   // the user's choice
        #expect(s("b.wav").catID == "DSGNImpt", "a choice above beats a guess below")
        #expect(s("c.wav").catID == "DSGNWhsh" && s("c.wav").categorySource == FolderRules.guessSource)
        #expect(s("WHSH_Vendor_X_Y.wav").catID == "WHSH")                          // the file's own wins
        #expect(try db.folderGuesses().first { $0.folder == "Pack/Whooshes" }?.alternativeIDs == ["DSGNMisc"])
        // Removing the choice brings the guess back; a stale guess is forgotten.
        try db.removeFolderRule(libraryId: lib.id!, folder: "Pack/Hits")
        try db.updateGuesses(saving: [], removing: [(lib.id!, "Pack/Whooshes")])
        let after = FolderRules.apply(try db.folderRules(), guesses: try db.folderGuesses(), to: try db.sounds())
        #expect(after.first { $0.fileName == "b.wav" }?.catID == "METLImpt")
        #expect(after.first { $0.fileName == "c.wav" }?.catID == nil)
        // Labels for the sound signal leave out both kinds of folder category.
        #expect(Set(FolderSuggester.labels(sounds).values) == ["WHSH"])
    }

    @Test func folderNamesPointToUCS() {
        let catalog = UCSCatalog.shared
        func best(_ folder: String) -> String? {
            FolderSuggester.nameScores(folder: folder, catalog: catalog).max { $0.value.score < $1.value.score }
                .flatMap { catalog.entry(catID: $0.key)?.category }
        }
        let feet = best("Sound Ideas - The SFX KIT Disk [Wav] MERRY XMAS 2022/TSK-03/Footsteps/Concrete")
        #expect(feet == "FOOTSTEPS", "\(String(describing: feet)) \(FolderSuggester.folderWords("Sound Ideas - The SFX KIT Disk [Wav] MERRY XMAS 2022/TSK-03/Footsteps/Concrete"))")
        let crowd = best("Sound Ideas - The SFX KIT Disk [Wav] MERRY XMAS 2022/TSK-06/Crowds")
        #expect(crowd == "CROWDS", "\(String(describing: crowd))")
        let words = FolderSuggester.folderWords("Pack/TSK-01/Automobiles").map(\.word)
        #expect(words == ["automobile"], "\(words)")   // "pack" and "tsk" say nothing
    }

    @Test func parentFolderDecidesTheCategoryAndSynonymsTheSubcategory() {
        func top(_ folder: String) -> String? {
            FolderSuggester.suggest(folder: folder, soundIds: [], index: nil, labels: [:]).first?.entry.catID
        }
        #expect(top("Pack/TSK-03/Footsteps/Metal - Steel") == "FEETHmn")
        #expect(top("Pack/TSK-03/Footsteps/Concrete") == "FEETHmn")
        let auto = FolderSuggester.suggest(folder: "Pack/TSK-01/Automobiles", soundIds: [], index: nil, labels: [:])
        // "Automobile" is a synonym of many VEHICLES subcategories: category only, so MISC.
        #expect(auto.first?.entry.catID == "VEHMisc", "\(auto.map { "\($0.entry.catID) \($0.score) \($0.words)" })")
        #expect(top("Pack/TSK-06/Crowds") == "CRWDMisc")
    }

    @Test func wordsAreSpelledAsUCSSpellsThem() {
        #expect(FolderSuggester.words("StreetBall_HitPad2") == ["street", "ball", "hit", "pad"])
        #expect(FolderSuggester.words("Sci-Fi Loops").contains("scifi"))          // UCS: SCIFI; "loop" is a format
        #expect(!FolderSuggester.words("Sci-Fi Loops").contains("loop"))
        #expect(FolderSuggester.words("SCI FI WEAPONS").contains("scifi"))
        #expect(FolderSuggester.words("Powerful Braaams").contains("braam"))      // UCS: BRAAM
        #expect(FolderSuggester.words("Whooshes & Glitches, Boxes") == ["whoosh", "glitch", "box"])
        #expect(FolderSuggester.words("Zombies").contains("zombie") && FolderSuggester.words("Batteries").contains("battery"))
        #expect(FolderSuggester.words("MA_SoundsByGFXSounds_CameraShutter").contains("camera"))
    }

    @Test func vendorNamesCountOnlyWhenTheSoundAgrees() {
        func top(_ folder: String, pack: Set<String> = [], files: [String: Double] = [:]) -> FolderSuggester.Option? {
            FolderSuggester.suggest(folder: folder, soundIds: [], index: nil, labels: [:], fileWords: files, packWords: pack).first
        }
        // The designer ("BOOM Library") isn't DESIGNED / BOOM.
        #expect(top("Boom.Library.Neon", pack: ["boom"], files: ["whoosh": 0.6])?.entry.category != "DESIGNED"
            || top("Boom.Library.Neon", pack: ["boom"], files: ["whoosh": 0.6])?.entry.catID != "DSGNBoom")
        #expect(top("Boom.Library.Neon")?.entry.catID == "DSGNBoom")              // without the designer it would be
        // The library's top folder above a deeper folder is the pack's name.
        let tube = FolderSuggester.suggest(folder: "Lens Distortions - Anticipation SFX/WAV/01 - Risers/Risers - Tube",
                                           soundIds: [], index: nil, labels: [:])
        #expect(tube.first?.entry.catID == "DSGNRise")
        #expect(!tube.contains { $0.entry.catID == "DSGNDist" }, "\(tube.map(\.entry.catID))")
    }

    @Test func aParentCategoryLocksMaterialsButNotAnotherSubject() {
        func top(_ folder: String, files: [String: Double] = [:]) -> String? {
            FolderSuggester.suggest(folder: folder, soundIds: [], index: nil, labels: [:], fileWords: files).first?.entry.catID
        }
        #expect(top("Pack/TSK-03/Footsteps/Snow - Crunchy") == "FEETHmn")              // SNOW is a material here
        #expect(top("Pack/Monsters & Creatures/Creature Footsteps") == "FEETCrea")     // footsteps of creatures
        // A loose parent ("Human Vocal Full Sets": HUMAN, but "vocal" too) gives way when most
        // files name a subcategory of another category (VOICES / MALE)…
        let male = FolderSuggester.suggest(folder: "Pack/Human Vocal Full Sets/Male_LongSet_A", soundIds: [],
                                           index: nil, labels: [:], fileWords: ["male": 1, "grunt": 0.5])
        #expect(male.first?.entry.catID == "VOXMale", "\(male.map(\.entry.catID))")
        // …a parent that is just the category's name doesn't: footsteps on leaves (VEGETATION / LEAVES).
        #expect(top("Pack/TSK-03/Footsteps/Leaves", files: ["foot": 1, "leaf": 1, "leave": 1]) == "FEETHmn")
        // …but files naming a material keep it locked: footsteps on snow.
        #expect(top("Pack/TSK-03/Footsteps/Snow - Crunchy", files: ["foot": 1, "snow": 1, "crunchy": 1]) == "FEETHmn")
        #expect(top("Pack/TSK-03/Footsteps/Glass", files: ["foot": 1, "glass": 1]) == "FEETHmn")      // DOORS / GLASS exists
        #expect(top("Pack/TSK-03/Footsteps/Wood - Hollow Deck", files: ["foot": 1, "wood": 1]) == "FEETHmn")
        // The last of three options comes from another category when the others share one.
        let gears = FolderSuggester.suggest(folder: "Pack/Mechanical", soundIds: [], index: nil, labels: [:])
        #expect(gears.first?.entry.category == "MECHANICAL")
        #expect(gears.last?.entry.category != "MECHANICAL", "\(gears.map(\.entry.catID))")
    }

    @Test func theFilesDecideWhenTheNameIsVague() {
        // "Hockey" is a synonym of six subcategories; the files say it's sticks and pucks on ice.
        let hockey = FolderSuggester.suggest(folder: "Pack/TSK-06/Hockey", soundIds: [], index: nil, labels: [:],
                                             fileWords: ["hockey": 1, "skating": 0.5, "ice": 0.4])
        #expect(hockey.first?.entry.catID == "SPRTWntr", "\(hockey.map { "\($0.entry.catID) \($0.fileWords)" })")
        #expect(hockey.first?.fileWords.contains("skating") == true)
    }

    @Test func fileWordsSkipVendorPartsAndKeepCommonWords() {
        func sound(_ name: String, _ details: String? = nil, folder: String = "Pack/Hits") -> SoundRecord {
            var s = SoundRecord(libraryId: 1, root: URL(fileURLWithPath: "/L"), scanned: ScannedSound(
                path: "/L/\(folder)/\(name)", fileSize: 1, modified: Date(), fingerprint: nil,
                technical: AudioTechnical(), metadata: NormalizedMetadata(), warnings: []))
            s.details = details
            return s
        }
        // A UCS file name: only the FXName describes the sound, the rest names the vendor and collection.
        let ucs = (1 ... 4).map { sound("DSGNImpt_Metal Hit \($0)_Ocular Sounds_Deep Impacts_The Complete Ambiences Collection.wav") }
        let words = FolderSuggester.fileWords(of: ucs)
        #expect(words["metal"] == 1 && words["hit"] == 1, "\(words)")
        #expect(words["ambience"] == nil && words["ocular"] == nil, "\(words)")
        // A description many folders share counts less than the folder's own words.
        let shared = (1 ... 4).map { sound("Hockey_Puck\($0).wav", "Sports & Recreation") }
        let w2 = FolderSuggester.fileWords(of: shared, sharedDescriptions: ["Sports & Recreation"])
        #expect(w2["hockey"] == 1 && (w2["sport"] ?? 0) < 0.5, "\(w2)")
    }

    @Test func vagueNamesAreFlaggedAndArchivedIsNeverSuggested() {
        // "Pickup" is a synonym of METAL, GLASS, WOOD… / HANDLE: worth listening first.
        let pickups = FolderSuggester.suggest(folder: "Pack/TSK-02/Pickups", soundIds: [], index: nil, labels: [:])
        #expect(pickups.first?.isUncertain == true)
        let steel = FolderSuggester.suggest(folder: "Pack/TSK-03/Footsteps/Metal - Steel", soundIds: [], index: nil, labels: [:])
        #expect(steel.first?.isUncertain == false)
        // ARCHIVED holds production material (ADR, bounces, scenes), not library sounds.
        let scenes = FolderSuggester.suggest(folder: "Pack/Scene Sequences", soundIds: [], index: nil, labels: [:])
        #expect(!scenes.contains { $0.entry.category == "ARCHIVED" }, "\(scenes.map(\.entry.catID))")
        // RAIN calls its base subcategory GENERAL: chosen when nothing points to another one.
        #expect(FolderSuggester.suggest(folder: "Pack/Rain", soundIds: [], index: nil, labels: [:]).first?.entry.catID == "RAIN")
    }

    @Test func soundPicksTheSubcategoryWhenTheNameOnlyGivesTheCategory() {
        // Folder "Footsteps" (category only); its sounds' neighbours are labelled FEETHmn.
        func v(_ x: Float, _ y: Float) -> [Float] { let n = (x * x + y * y).squareRoot(); return [x / n, y / n] }
        let index = SimilarityIndex(vectors: [(1, v(1, 0.1)), (2, v(1, 0.12)), (10, v(1, 0.11)), (11, v(1, 0.09)), (20, v(0, 1))])
        let labels: [Int64: String] = [10: "FEETHmn", 11: "FEETHmn", 20: "WHSHSwsh"]
        let options = FolderSuggester.suggest(folder: "Pack/Footsteps", soundIds: [1, 2], index: index, labels: labels)
        #expect(options.first?.entry.catID == "FEETHmn")
        #expect((options.first?.soundShare ?? 0) > 0.5)
    }
}
