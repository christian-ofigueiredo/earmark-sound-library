import Foundation
import GRDB

/// Sounds that are the same: byte-identical copies (the same fingerprint, anywhere), and the
/// same recording in another file (renamed, in another folder or pack, a little processed),
/// found by their audio. Format twins (the MP3 beside the WAV) are already shown as one sound
/// (`FormatTwins`) and aren't counted. Earmark only shows them; it never deletes or moves files.
public enum Duplicates {
    /// Cosine (PE-AV + CLAP) from which two sounds of the same length are one recording. On the
    /// owner's library (2026-10-27, `earmark-parity duplicates`): every pair of nearest sounds at
    /// 0.998 or more had the same length (299 pairs: the same recording reused under another name,
    /// e.g. a car loop in Automobiles and in Trucks), byte-identical copies are 1.0000; below 0.995
    /// different lengths and real versions (dry and wet, kit layers, takes) come in.
    public static let similarity: Float = 0.998

    public struct Pair: Sendable, Equatable {
        public var a: Int64
        public var b: Int64
        /// Byte-identical files (the same fingerprint), else the same recording by its audio.
        public var identical: Bool
        public var similarity: Float
        public init(a: Int64, b: Int64, identical: Bool, similarity: Float) {
            self.a = min(a, b); self.b = max(a, b); self.identical = identical; self.similarity = similarity
        }
    }

    /// Lengths that count as the same: within 1%, or 0.02 s for short sounds.
    public static func sameLength(_ x: Double?, _ y: Double?) -> Bool {
        guard let x, let y else { return false }
        return abs(x - y) <= max(0.02, 0.01 * max(x, y))
    }

    /// Byte-identical copies: sounds sharing a fingerprint (hidden format twins left out).
    public static func identicalPairs(_ sounds: [SoundRecord], hidden: Set<Int64>) -> [Pair] {
        var byPrint: [String: [Int64]] = [:]
        for s in sounds {
            guard let id = s.id, let fp = s.fingerprint, !hidden.contains(id) else { continue }
            byPrint[fp, default: []].append(id)
        }
        return byPrint.values.filter { $0.count > 1 }.flatMap { ids in
            ids.indices.flatMap { i in ids[(i + 1)...].map { Pair(a: ids[i], b: $0, identical: true, similarity: 1) } }
        }
    }

    /// The same recording, from a neighbour search over `ids` (n × k indices and cosine
    /// distances, each row's nearest first): pairs at `similarity` or more with the same length.
    public static func nearPairs(ids: [Int64], durations: [Double?], indices: [Int], distances: [Float], k: Int) -> [Pair] {
        var seen = Set<Int64>(), out: [Pair] = []
        let n = ids.count
        for i in 0 ..< n {
            for c in 0 ..< k {
                let j = indices[i * k + c], s = 1 - distances[i * k + c]
                guard s >= similarity else { break }
                guard j != i, sameLength(durations[i], durations[j]) else { continue }
                let key = Int64(min(i, j)) * Int64(n) + Int64(max(i, j))
                if seen.insert(key).inserted { out.append(Pair(a: ids[i], b: ids[j], identical: false, similarity: s)) }
            }
        }
        return out
    }

    /// Sounds joined into sets (a copy of a copy is in the same set).
    public struct Sets: Sendable, Equatable {
        /// Each sound in a set → its set's number.
        public var setOf: [Int64: Int] = [:]
        /// Each set's sounds, in id order; sets by their first sound.
        public var members: [[Int64]] = []
        /// Each sound → the others it's the same as, and how (identical, or similarity).
        public var others: [Int64: [(id: Int64, identical: Bool, similarity: Float)]] = [:]

        public init() {}

        public static func == (l: Sets, r: Sets) -> Bool { l.setOf == r.setOf && l.members == r.members }
    }

    public static func sets(_ pairs: [Pair]) -> Sets {
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var r = x
            while let p = parent[r], p != r { r = p }
            var y = x
            while let p = parent[y], p != r { parent[y] = r; y = p }
            return r
        }
        var out = Sets()
        // An identical pair also found by its audio: keep "identical".
        var best: [String: Pair] = [:]
        for p in pairs {
            let key = "\(p.a) \(p.b)"
            if let old = best[key], old.identical || !p.identical { continue }
            best[key] = p
        }
        for p in best.values {
            if parent[p.a] == nil { parent[p.a] = p.a }
            if parent[p.b] == nil { parent[p.b] = p.b }
            parent[find(p.a)] = find(p.b)
            out.others[p.a, default: []].append((p.b, p.identical, p.similarity))
            out.others[p.b, default: []].append((p.a, p.identical, p.similarity))
        }
        for (id, list) in out.others { out.others[id] = list.sorted { ($0.identical ? 0 : 1, $0.id) < ($1.identical ? 0 : 1, $1.id) } }
        let groups = Dictionary(grouping: parent.keys, by: find).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
        out.members = groups
        for (n, g) in groups.enumerated() { for id in g { out.setOf[id] = n } }
        return out
    }
}

extension LibraryDatabase {
    /// The same-recording pairs last found (byte-identical copies come from the fingerprints).
    public func nearDuplicates() throws -> [Duplicates.Pair] {
        try dbQueue.read { db in
            // A database the app hasn't opened since this table came (read-only readers can't migrate).
            guard try db.tableExists("soundDuplicate") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT soundA, soundB, similarity FROM soundDuplicate").map {
                Duplicates.Pair(a: $0[0], b: $0[1], identical: false, similarity: Float($0[2] as Double))
            }
        }
    }

    public func saveNearDuplicates(_ pairs: [Duplicates.Pair]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM soundDuplicate")
            for p in pairs where !p.identical {
                try db.execute(sql: "INSERT OR REPLACE INTO soundDuplicate (soundA, soundB, similarity) VALUES (?, ?, ?)",
                               arguments: [p.a, p.b, Double(p.similarity)])
            }
        }
    }
}
