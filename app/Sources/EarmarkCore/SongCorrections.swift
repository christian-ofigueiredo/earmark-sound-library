import Foundation
import GRDB

/// A tempo, key or beats per bar the user set for a song by hand. Kept apart from what Phase 0
/// or Earmark found, so Revert always works and rescans, imports and Earmark's own analysis
/// never undo it. Keyed by the file's path with no link to the song row: it survives removing
/// and re-adding the folder. Stored in Earmark's database only; files are never written.
public struct SongCorrection: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public var path: String
    public var bpm: Double?
    /// The tempo range scaled with the tempo (Double, Half), or nil for a tempo typed in:
    /// the analysed range no longer applies then.
    public var bpmLow: Double?
    public var bpmHigh: Double?
    public var keyPitchClass: Int?
    public var keyMinor: Bool?
    public var beatsPerBar: Int?
    public var correctedAt: Date

    public init(path: String, bpm: Double? = nil, bpmLow: Double? = nil, bpmHigh: Double? = nil,
                key: MusicKey? = nil, beatsPerBar: Int? = nil, correctedAt: Date = Date()) {
        self.path = path; self.bpm = bpm; self.bpmLow = bpmLow; self.bpmHigh = bpmHigh
        self.keyPitchClass = key?.pitchClass; self.keyMinor = key?.minor; self.beatsPerBar = beatsPerBar
        self.correctedAt = correctedAt
    }

    public var key: MusicKey? { keyPitchClass.map { MusicKey(pitchClass: $0, minor: keyMinor ?? false) } }
    public var correctsTempo: Bool { bpm != nil }
    public var correctsKey: Bool { keyPitchClass != nil }
    public var correctsBeatsPerBar: Bool { beatsPerBar != nil }
    public var isEmpty: Bool { !correctsTempo && !correctsKey && !correctsBeatsPerBar }
}

/// What Phase 0 or Earmark found for a song the user corrected (its own fields then hold the
/// user's values).
public struct AnalysedValues: Sendable, Hashable {
    public var bpm: Double?
    public var bpmLow: Double?
    public var bpmHigh: Double?
    public var beatsPerBar: Int?
    public var key: MusicKey?
}

/// A change to a song's tempo, key or beats per bar, from the detail pane or the list's menu.
public enum SongEdit: Sendable, Equatable {
    case doubleTempo, halveTempo
    case setTempo(Double)
    case relativeKey
    case setKey(MusicKey)
    case setBeatsPerBar(Int)
    case revertTempo, revertKey, revertBeatsPerBar, revertAll

    /// For the Edit menu's Undo ("Undo Halve Tempo").
    public var title: String {
        switch self {
        case .doubleTempo: "Double Tempo"
        case .halveTempo: "Halve Tempo"
        case .setTempo: "Set Tempo"
        case .relativeKey: "Use Relative Key"
        case .setKey: "Set Key"
        case .setBeatsPerBar: "Set Beats per Bar"
        case .revertTempo: "Revert Tempo"
        case .revertKey: "Revert Key"
        case .revertBeatsPerBar: "Revert Beats per Bar"
        case .revertAll: "Revert to Analysed Values"
        }
    }

    /// Tempos that can be typed in, as Phase 0's import and Earmark's analysis keep.
    public static let tempoRange = 20.0 ... 400.0
}

extension SongRecord {
    /// As Phase 0 or Earmark found it, without the user's corrections.
    public var uncorrected: SongRecord {
        guard let a = analysed else { return self }
        var s = self
        s.bpm = a.bpm; s.bpmLow = a.bpmLow; s.bpmHigh = a.bpmHigh; s.beatsPerBar = a.beatsPerBar
        s.keyPitchClass = a.key?.pitchClass; s.keyMinor = a.key?.minor
        s.analysed = nil
        s.correction = nil
        return s
    }

    /// With this correction laid over what was analysed (nil or empty: as analysed).
    public func applying(_ c: SongCorrection?) -> SongRecord {
        var s = uncorrected
        guard let c, !c.isEmpty else { return s }
        s.analysed = AnalysedValues(bpm: s.bpm, bpmLow: s.bpmLow, bpmHigh: s.bpmHigh, beatsPerBar: s.beatsPerBar, key: s.key)
        s.correction = c
        if let bpm = c.bpm { s.bpm = bpm; s.bpmLow = c.bpmLow; s.bpmHigh = c.bpmHigh }
        if let key = c.key { s.keyPitchClass = key.pitchClass; s.keyMinor = key.minor }
        if let beats = c.beatsPerBar { s.beatsPerBar = beats }
        return s
    }

    /// Whether this edit can apply to the song as shown (Double needs a tempo, Revert a correction…).
    public func allows(_ edit: SongEdit) -> Bool {
        switch edit {
        case .doubleTempo: bpm.map { $0 * 2 <= SongEdit.tempoRange.upperBound } ?? false
        case .halveTempo: bpm.map { $0 / 2 >= SongEdit.tempoRange.lowerBound } ?? false
        case .setTempo(let x): SongEdit.tempoRange.contains(x)
        case .relativeKey: key != nil
        case .setKey(let k): k != key
        case .setBeatsPerBar(let n): [2, 3, 4, 6].contains(n) && n != beatsPerBar
        case .revertTempo: correction?.correctsTempo ?? false
        case .revertKey: correction?.correctsKey ?? false
        case .revertBeatsPerBar: correction?.correctsBeatsPerBar ?? false
        case .revertAll: correction != nil
        }
    }

    /// The correction this song has after the edit; nil when nothing differs from what was
    /// analysed any more (Double then Half, or a key set back to the analysed one).
    public func correction(after edit: SongEdit, at date: Date = Date()) -> SongCorrection? {
        let base = uncorrected
        var c = correction ?? SongCorrection(path: path, correctedAt: date)
        c.correctedAt = date
        func scaleTempo(_ f: Double) {
            guard let bpm else { return }
            c.bpm = bpm * f; c.bpmLow = bpmLow.map { $0 * f }; c.bpmHigh = bpmHigh.map { $0 * f }
        }
        switch edit {
        case .doubleTempo: scaleTempo(2)
        case .halveTempo: scaleTempo(0.5)
        case .setTempo(let x): c.bpm = x; c.bpmLow = nil; c.bpmHigh = nil
        case .relativeKey: if let key { c.keyPitchClass = key.relative.pitchClass; c.keyMinor = key.relative.minor }
        case .setKey(let k): c.keyPitchClass = k.pitchClass; c.keyMinor = k.minor
        case .setBeatsPerBar(let n): c.beatsPerBar = n
        case .revertTempo: c.bpm = nil; c.bpmLow = nil; c.bpmHigh = nil
        case .revertKey: c.keyPitchClass = nil; c.keyMinor = nil
        case .revertBeatsPerBar: c.beatsPerBar = nil
        case .revertAll: return nil
        }
        // Back where the analysis was (a typed tempo equal to it too): no correction for that part.
        func near(_ x: Double?, _ y: Double?) -> Bool {
            switch (x, y) {
            case (nil, nil): true
            case let (x?, y?): abs(x - y) < 0.005
            default: false
            }
        }
        if c.bpm != nil, near(c.bpm, base.bpm),
           (c.bpmLow == nil && c.bpmHigh == nil) || (near(c.bpmLow, base.bpmLow) && near(c.bpmHigh, base.bpmHigh)) {
            c.bpm = nil; c.bpmLow = nil; c.bpmHigh = nil
        }
        if c.key != nil, c.key == base.key { c.keyPitchClass = nil; c.keyMinor = nil }
        if c.beatsPerBar != nil, c.beatsPerBar == base.beatsPerBar { c.beatsPerBar = nil }
        return c.isEmpty ? nil : c
    }
}

public enum SongCorrections {
    /// The songs with the user's corrections laid over what Phase 0 or Earmark found.
    public static func apply(_ corrections: [String: SongCorrection], to songs: [SongRecord]) -> [SongRecord] {
        guard !corrections.isEmpty else { return songs }
        return songs.map { s in corrections[s.path].map { s.applying($0) } ?? s }
    }
}

extension LibraryDatabase {
    public func songCorrections() throws -> [SongCorrection] {
        try dbQueue.read { db in try SongCorrection.fetchAll(db) }
    }

    /// Saves these songs' corrections; a nil correction removes the song's.
    public func setSongCorrections(_ changes: [(path: String, correction: SongCorrection?)]) throws {
        try dbQueue.write { db in
            for (path, correction) in changes {
                if let correction { try correction.save(db) } else { _ = try SongCorrection.deleteOne(db, key: path) }
            }
        }
    }
}
