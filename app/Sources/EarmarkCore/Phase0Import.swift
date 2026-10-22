import Foundation

/// Tempo and key results for one song, as stored by Earmark.
public struct SongAnalysis: Sendable, Codable, Equatable {
    public var bpm: Double?
    public var bpmLow: Double?
    public var bpmHigh: Double?
    public var tempoStability: String?
    public var beatsPerBar: Int?
    public var key: MusicKey?
    public var keyConfidence: Double?
    public var keySecondOpinion: MusicKey?
    public var source: String

    public init(bpm: Double? = nil, bpmLow: Double? = nil, bpmHigh: Double? = nil, tempoStability: String? = nil,
                beatsPerBar: Int? = nil, key: MusicKey? = nil, keyConfidence: Double? = nil,
                keySecondOpinion: MusicKey? = nil, source: String) {
        self.bpm = bpm; self.bpmLow = bpmLow; self.bpmHigh = bpmHigh; self.tempoStability = tempoStability
        self.beatsPerBar = beatsPerBar; self.key = key; self.keyConfidence = keyConfidence
        self.keySecondOpinion = keySecondOpinion; self.source = source
    }
}

/// Reads the `music_analysis.json` written by Phase 0's analyze_music.py, so
/// songs analysed there don't need to be analysed again.
public enum Phase0MusicImport {
    struct File: Decodable {
        let format: String?
        let tracks: [Track]
    }

    struct Track: Decodable {
        let file: String?
        let path: String?
        let size: Int64?
        let bpm: Double?
        let bpmRange: [Double]?
        let tempoStability: String?
        let beatsPerBar: Int?
        let keyPc: Int?
        let keyMinor: Bool?
        let keyConfidence: Double?
        let keySecondOpinion: String?
        let title: String?
        let artist: String?
    }

    public struct Entry: Sendable, Equatable {
        public var path: String?
        public var fileName: String
        public var size: Int64?
        public var title: String?
        public var artist: String?
        public var analysis: SongAnalysis
    }

    public enum ImportError: Error, LocalizedError {
        case notPhase0Music
        public var errorDescription: String? { "This isn't a music_analysis.json file from Phase 0." }
    }

    public static func read(_ data: Data) throws -> [Entry] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try decoder.decode(File.self, from: data)
        guard file.format == nil || file.format == "soundlab-music-analysis" else { throw ImportError.notPhase0Music }
        return file.tracks.map { t in
            let key = t.keyPc.map { MusicKey(pitchClass: $0, minor: t.keyMinor ?? false) }
            let bpm = t.bpm.flatMap { (20 ... 400).contains($0) ? $0 : nil }  // drop impossible readings
            let analysis = SongAnalysis(
                bpm: bpm, bpmLow: t.bpmRange?.first, bpmHigh: t.bpmRange?.last, tempoStability: t.tempoStability,
                beatsPerBar: t.beatsPerBar.flatMap { [2, 3, 4, 6].contains($0) ? $0 : nil },
                key: key, keyConfidence: t.keyConfidence,
                keySecondOpinion: t.keySecondOpinion.flatMap { MusicKey(parsing: $0) }, source: "Phase 0")
            let name = (t.path ?? t.file).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return Entry(path: t.path, fileName: name, size: t.size, title: t.title, artist: t.artist, analysis: analysis)
        }
    }
}
