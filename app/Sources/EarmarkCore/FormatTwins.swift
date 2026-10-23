import Foundation

/// Packs often ship the same sounds twice, e.g. "Pack - WAV/Hits/01 Hit.wav" and
/// "Pack - MP3/Hits/01 Hit.mp3". Twins are files in the same library with the same
/// name apart from the extension, in folders that only differ by format words,
/// and with lengths within half a second. The list shows the best-quality one.
public enum FormatTwins {
    /// Lower is better: lossless first, then lossy.
    static let rank: [String: Int] = [
        "wav": 0, "wave": 0, "bwf": 0, "rf64": 0, "w64": 0, "aif": 1, "aiff": 1, "aifc": 1, "caf": 1,
        "flac": 2, "alac": 2, "m4a": 3, "mp4": 3, "aac": 3, "ogg": 4, "oga": 4, "opus": 4, "mp3": 5,
    ]

    static let formatWords: Set<String> = Set(rank.keys).union(["lossless", "lossy", "hq", "hd"])

    public struct Groups: Sendable, Equatable {
        /// Shown sound id → its other copies, best first.
        public var alternates: [Int64: [Int64]] = [:]
        /// Ids hidden from the list because a better copy is shown.
        public var hidden: Set<Int64> = []

        public init() {}
    }

    public static func group(_ sounds: [SoundRecord]) -> Groups {
        var buckets: [String: [SoundRecord]] = [:]
        for s in sounds where s.id != nil {
            let name = s.fileName as NSString
            let key = "\(s.libraryId)|\(normalizedFolder(s.folder))|\(name.deletingPathExtension.lowercased())"
            buckets[key, default: []].append(s)
        }
        var out = Groups()
        for bucket in buckets.values where bucket.count > 1 {
            let sorted = bucket.sorted { quality($0) < quality($1) }
            var pending = sorted[...]
            while let best = pending.popFirst() {
                // Same name and folder but a clearly different length is a different sound.
                let twins = pending.filter { sameLength(best, $0) && ext(best) != ext($0) }
                guard !twins.isEmpty else { continue }
                let ids = twins.compactMap(\.id)
                out.alternates[best.id!] = ids
                out.hidden.formUnion(ids)
                pending.removeAll { ids.contains($0.id!) }
            }
        }
        return out
    }

    static func ext(_ s: SoundRecord) -> String { (s.fileName as NSString).pathExtension.lowercased() }

    static func quality(_ s: SoundRecord) -> (Int, Int, Double, String) {
        (rank[ext(s)] ?? 9, -(s.bitsPerSample ?? 0), -(s.sampleRate ?? 0), s.path)
    }

    static func sameLength(_ a: SoundRecord, _ b: SoundRecord) -> Bool {
        guard let x = a.duration, let y = b.duration else { return true }
        return abs(x - y) <= 0.5
    }

    /// Folder with format words ("MP3", "WAV", "(MP3,WAV)") blanked out, lowercased.
    static func normalizedFolder(_ folder: String) -> String {
        folder.lowercased()
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { part in
                part.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .filter { !formatWords.contains(String($0)) }
                    .joined(separator: " ")
            }
            .joined(separator: "/")
    }
}
