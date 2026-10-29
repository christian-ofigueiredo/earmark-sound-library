import Foundation

/// A timeline file (FCPXML 1.10) with sounds, or parts of them, at their times: what the free
/// DaVinci Resolve, Resolve Studio and Final Cut Pro import (docs/timeline-file-plan.md). Each
/// clip is a cut of the original file, connected below a gap as long as everything, on the first
/// lane free at its time (Resolve makes each lane an audio track). Times are whole frames; a range
/// is rounded outwards, as `ResolveBridge` does.
public enum TimelineFile {
    /// A frame rate: one frame lasts `frameDuration` (numerator/denominator seconds).
    public struct Rate: Sendable, Hashable, Identifiable {
        public var name: String
        public var numerator: Int64
        public var denominator: Int64
        public var dropFrame: Bool
        public var id: String { name }

        /// Frames per second, rounded (the timecode's frame count).
        public var nominal: Int { Int((Double(denominator) / Double(numerator)).rounded()) }
        var fps: Double { Double(denominator) / Double(numerator) }
        var frameDuration: Rational { Rational(numerator, denominator) }

        public static let all: [Rate] = [
            Rate(name: "23.976", numerator: 1001, denominator: 24000, dropFrame: false),
            Rate(name: "24", numerator: 1, denominator: 24, dropFrame: false),
            Rate(name: "25", numerator: 1, denominator: 25, dropFrame: false),
            Rate(name: "29.97", numerator: 1001, denominator: 30000, dropFrame: false),
            Rate(name: "29.97 DF", numerator: 1001, denominator: 30000, dropFrame: true),
            Rate(name: "30", numerator: 1, denominator: 30, dropFrame: false),
            Rate(name: "50", numerator: 1, denominator: 50, dropFrame: false),
            Rate(name: "59.94", numerator: 1001, denominator: 60000, dropFrame: false),
            Rate(name: "59.94 DF", numerator: 1001, denominator: 60000, dropFrame: true),
            Rate(name: "60", numerator: 1, denominator: 60, dropFrame: false),
        ]

        /// "25", "29.97 DF", "29.97df", "29.97": one of `all`.
        public static func named(_ text: String) -> Rate? {
            let t = text.lowercased().replacingOccurrences(of: " ", with: "")
            return all.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == t }
        }
    }

    /// One sound to place.
    public struct Clip: Sendable {
        public var path: String
        public var name: String
        /// The file's length in seconds, sample rate and channels, as Earmark knows them.
        public var length: Double
        public var sampleRate: Int
        public var channels: Int
        /// Where the file's audio starts in its own timecode, in samples (a BWF time reference).
        public var timeReference: Int64
        /// Seconds into the file; nil: from the start, to the end.
        public var start: Double?
        public var end: Double?
        /// Seconds from the timeline's start; nil: where the previous clip ends.
        public var at: Double?

        public init(path: String, name: String, length: Double, sampleRate: Int, channels: Int, timeReference: Int64 = 0,
                    start: Double? = nil, end: Double? = nil, at: Double? = nil) {
            self.path = path; self.name = name; self.length = length; self.sampleRate = sampleRate
            self.channels = channels; self.timeReference = timeReference
            self.start = start; self.end = end; self.at = at
        }
    }

    /// Where a clip went: its lane (1 is just below the gap: Resolve's first audio track) and its
    /// timeline timecodes.
    public struct Placement: Sendable, Equatable, Codable {
        public var lane: Int
        public var start: String
        public var end: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case badTimecode(String)
        case tooShort(String)
        case nothing

        public var errorDescription: String? {
            switch self {
            case .badTimecode(let tc): "“\(tc)” isn't a timecode like 01:00:00:00."
            case .tooShort(let name): "The part of “\(name)” is shorter than a frame."
            case .nothing: "There are no sounds to put in the timeline file."
            }
        }
    }

    /// The file's text and where each clip went.
    public static func fcpxml(_ clips: [Clip], rate: Rate, startTimecode: String = "01:00:00:00",
                              name: String) throws -> (xml: String, placements: [Placement]) {
        guard !clips.isEmpty else { throw Failure.nothing }
        guard let first = frames(startTimecode, rate) else { throw Failure.badTimecode(startTimecode) }
        let fd = rate.frameDuration
        let tcStart = fd * first

        struct Cut { var clip: Clip; var asset: Int; var inFrame: Int64; var duration: Int64; var at: Int64; var lane: Int }
        var assets: [String: Int] = [:]
        var assetOrder: [Clip] = []
        var cuts: [Cut] = []
        var lanes: [[(Int64, Int64)]] = []
        var cursor: Int64 = 0
        for clip in clips {
            let available = Int64((clip.length * rate.fps + 1e-6).rounded(.down))
            let inFrame = Int64(((clip.start ?? 0) * rate.fps + 1e-9).rounded(.down))
            let outFrame = min(clip.end.map { Int64(($0 * rate.fps - 1e-9).rounded(.up)) } ?? available, available)
            guard outFrame > inFrame else { throw Failure.tooShort(clip.name) }
            let duration = outFrame - inFrame
            let at = clip.at.map { max(0, Int64(($0 * rate.fps).rounded())) } ?? cursor
            let lane = lanes.firstIndex { $0.allSatisfy { a, b in !(a < at + duration && b > at) } } ?? lanes.count
            if lane == lanes.count { lanes.append([]) }
            lanes[lane].append((at, at + duration))
            let asset = assets[clip.path] ?? {
                assetOrder.append(clip)
                assets[clip.path] = assetOrder.count
                return assetOrder.count
            }()
            cuts.append(Cut(clip: clip, asset: asset, inFrame: inFrame, duration: duration, at: at, lane: lane + 1))
            cursor = at + duration
        }
        let total = cuts.map { $0.at + $0.duration }.max() ?? 1

        var x = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE fcpxml>
            <fcpxml version="1.10">
              <resources>
                <format id="r0" frameDuration="\(fd)" width="1920" height="1080"/>

            """
        for (n, clip) in assetOrder.enumerated() {
            let rateSamples = Int64(max(clip.sampleRate, 1))
            let samples = Int64((clip.length * Double(rateSamples)).rounded())
            x += """
                    <asset id="r\(n + 1)" name="\(escape(clip.name))" start="\(fd * startFrame(clip, rate))" \
                duration="\(Rational(samples, rateSamples))" hasAudio="1" audioSources="1" audioChannels="\(max(clip.channels, 1))" \
                audioRate="\(clip.sampleRate)">
                      <media-rep kind="original-media" src="\(escape(fileURL(clip.path)))"/>
                    </asset>

                """
        }
        x += """
              </resources>
              <library>
                <event name="Earmark">
                  <project name="\(escape(name))">
                    <sequence format="r0" duration="\(fd * total)" tcStart="\(tcStart)" tcFormat="\(rate.dropFrame ? "DF" : "NDF")" \
            audioLayout="stereo" audioRate="48k">
                      <spine>
                        <gap name="Gap" offset="\(tcStart)" start="\(tcStart)" duration="\(fd * total)">

            """
        for cut in cuts {
            let assetStart = fd * startFrame(cut.clip, rate)
            x += """
                              <asset-clip ref="r\(cut.asset)" lane="-\(cut.lane)" offset="\(tcStart + fd * cut.at)" \
                name="\(escape(cut.clip.name))" start="\(assetStart + fd * cut.inFrame)" duration="\(fd * cut.duration)" \
                audioRole="effects"/>

                """
        }
        x += """
                        </gap>
                      </spine>
                    </sequence>
                  </project>
                </event>
              </library>
            </fcpxml>

            """
        let placements = cuts.map {
            Placement(lane: $0.lane, start: timecode(first + $0.at, rate), end: timecode(first + $0.at + $0.duration, rate))
        }
        return (x, placements)
    }

    /// The file's own start (its BWF time reference) in whole frames, rounded to the nearest.
    /// Resolve 21 reads an asset's start that way: given the exact start, a file starting between
    /// two frames had every cut up to half a frame off (checked 2026-10-29 against ⌘T's cuts of
    /// the same files at 25, 29.97 DF and 30 fps).
    static func startFrame(_ clip: Clip, _ rate: Rate) -> Int64 {
        let per = rate.numerator * Int64(max(clip.sampleRate, 1))
        return (clip.timeReference * rate.denominator + per / 2) / per
    }

    // MARK: timecode

    /// "01:00:00:00" (or "01:00:00;00" for drop frame) as a frame count from 00:00:00:00.
    public static func frames(_ tc: String, _ rate: Rate) -> Int64? {
        let parts = tc.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).compactMap { Int64($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 }), parts[1] < 60, parts[2] < 60, parts[3] < Int64(rate.nominal) else {
            return nil
        }
        let nominal = Int64(rate.nominal)
        var n = (parts[0] * 3600 + parts[1] * 60 + parts[2]) * nominal + parts[3]
        if rate.dropFrame {
            let dropped = nominal / 15
            let minutes = 60 * parts[0] + parts[1]
            n -= dropped * (minutes - minutes / 10)
        }
        return n
    }

    /// A frame count from 00:00:00:00 as a timecode (";" before the frames for drop frame).
    public static func timecode(_ frames: Int64, _ rate: Rate) -> String {
        let nominal = Int64(rate.nominal)
        var n = frames
        if rate.dropFrame {
            let dropped = nominal / 15
            let per10 = nominal * 600 - dropped * 9
            let tens = n / per10, rest = n % per10
            n += dropped * 9 * tens + (rest > dropped ? dropped * ((rest - dropped) / (nominal * 60 - dropped)) : 0)
        }
        let f = n % nominal, s = n / nominal
        return String(format: "%02d:%02d:%02d%@%02d", s / 3600, s / 60 % 60, s % 60, rate.dropFrame ? ";" : ":", f)
    }

    /// A file URL keeping the path's characters as they are (Foundation's would decompose accents).
    static func fileURL(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%;?#[]")
        return "file://" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// An exact time in seconds, written as FCPXML wants it ("1001/30000s", "3600s").
struct Rational: Equatable, CustomStringConvertible {
    var numerator: Int64
    var denominator: Int64

    init(_ numerator: Int64, _ denominator: Int64) {
        let g = Rational.gcd(abs(numerator), abs(denominator))
        self.numerator = g == 0 ? 0 : numerator / g
        self.denominator = g == 0 ? 1 : denominator / g
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? a : gcd(b, a % b) }

    static func + (a: Rational, b: Rational) -> Rational {
        let g = gcd(a.denominator, b.denominator)
        let d = a.denominator / g * b.denominator
        return Rational(a.numerator * (d / a.denominator) + b.numerator * (d / b.denominator), d)
    }

    static func * (a: Rational, n: Int64) -> Rational { Rational(a.numerator * n, a.denominator) }

    var description: String { denominator == 1 ? "\(numerator)s" : "\(numerator)/\(denominator)s" }
}
