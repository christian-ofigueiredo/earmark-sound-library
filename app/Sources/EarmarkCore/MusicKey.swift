import Foundation

/// A musical key: tonic pitch class (C = 0) and mode.
public struct MusicKey: Sendable, Hashable, Codable {
    public var pitchClass: Int
    public var minor: Bool

    public init(pitchClass: Int, minor: Bool) {
        self.pitchClass = ((pitchClass % 12) + 12) % 12
        self.minor = minor
    }

    static let majorNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let minorNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]
    static let pitchClasses: [String: Int] = [
        "C": 0, "B#": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4, "FB": 4, "E#": 5, "F": 5,
        "F#": 6, "GB": 6, "G": 7, "G#": 8, "AB": 8, "A": 9, "A#": 10, "BB": 10, "B": 11, "CB": 11,
    ]

    /// The 24 keys: the major ones from C up, then the minor ones.
    public static let all: [MusicKey] = [false, true].flatMap { minor in (0 ..< 12).map { MusicKey(pitchClass: $0, minor: minor) } }

    /// "A minor", "Bb major".
    public var name: String {
        "\((minor ? Self.minorNames : Self.majorNames)[pitchClass]) \(minor ? "minor" : "major")"
    }

    /// "Am", "Bb".
    public var shortName: String { (minor ? Self.minorNames : Self.majorNames)[pitchClass] + (minor ? "m" : "") }

    /// Camelot wheel code used for harmonic mixing, e.g. "8A" for A minor.
    public var camelot: String {
        let majorPC = minor ? (pitchClass + 3) % 12 : pitchClass
        let n = ((majorPC * 7) % 12 + 7) % 12 + 1
        return "\(n)\(minor ? "A" : "B")"
    }

    /// The relative major/minor (same notes): the most common key-detection mix-up.
    public var relative: MusicKey {
        minor ? MusicKey(pitchClass: pitchClass + 3, minor: false) : MusicKey(pitchClass: pitchClass - 3, minor: true)
    }

    /// Camelot neighbours: same code, ±1 on the wheel, and the relative key.
    public var mixesWith: [MusicKey] {
        let fifthUp = MusicKey(pitchClass: pitchClass + 7, minor: minor)
        let fifthDown = MusicKey(pitchClass: pitchClass + 5, minor: minor)
        return [self, fifthUp, fifthDown, relative]
    }

    /// Parses "Am", "A minor", "C#m", "Dbmaj", "B♭m", "8A" (Camelot), "1m" (Open Key).
    public init?(parsing text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "♯", with: "#")
        guard !t.isEmpty else { return nil }
        if let m = t.wholeMatch(of: /0?(\d{1,2})\s*([ABab])/), let n = Int(m.1), (1 ... 12).contains(n) {
            let minor = m.2.uppercased() == "A"
            guard let majorPC = (0 ..< 12).first(where: { (($0 * 7) % 12 + 7) % 12 + 1 == n }) else { return nil }
            self.init(pitchClass: minor ? majorPC - 3 : majorPC, minor: minor)
            return
        }
        if let m = t.wholeMatch(of: /0?(\d{1,2})\s*([dmDM])/), let n = Int(m.1), (1 ... 12).contains(n) {
            self.init(parsing: "\((n + 6) % 12 + 1)\(m.2.lowercased() == "m" ? "A" : "B")")
            return
        }
        guard let m = t.wholeMatch(of: /([A-Ga-g])\s*([#b]?)\s*(.*)/) else { return nil }
        let note = m.1.uppercased() + m.2.uppercased()
        guard let pc = Self.pitchClasses[note] else { return nil }
        switch m.3.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "maj", "major", "dur": self.init(pitchClass: pc, minor: false)
        case "m", "min", "minor", "moll", "mi": self.init(pitchClass: pc, minor: true)
        default: return nil
        }
    }
}
