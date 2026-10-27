import Foundation

/// Similarity groups inside a subcategory, after Phase 0's `group_sounds.py` layer 3 and
/// `soundlab/grouping.py`: the sounds' embeddings (PE-AV + CLAP combined) are centred on the
/// set and laid out in 10 dimensions with UMAP (min_dist 0), as Phase 0; each group is named
/// from words the AI finds closest to it, measured against the set's other groups and the
/// whole library, plus words for its length.
///
/// The groups themselves are Ward's clustering of that layout into 2–12 groups by the set's
/// size, not Phase 0's HDBSCAN: on the whole library HDBSCAN (ported exactly, `HDBSCAN`) made
/// 120 groups of whooshes and 356 of human footsteps, nearly all tiny, with 5–15% left out,
/// in Python as in Swift (Phase 0 had only tried 243 whooshes). Ward on the same layout put
/// every sound in a group, kept the sizes even and kept as many of each sound's 10 nearest in
/// its group as any alternative tried (92–97% on six large subcategories, 2026-10-27).
public enum SoundGroups {
    /// Bump when grouping or naming changes: groups made by an older version are made again
    /// (unless the owner changed them).
    public static let version = 1
    public static let minGroupSize = 5

    // MARK: grouping

    /// How many groups a set of `n` sounds is split into: about √(n/8), 2–12; under 20 sounds, one.
    public static func groupCount(_ n: Int) -> Int {
        n < 20 ? 1 : min(12, max(2, Int((Double(n) / 8).squareRoot().rounded())))
    }

    /// A group per sound: 0 for the largest group, 1 for the next… `x`: `count` rows of
    /// `dimensions` (unit length, combined models). Nil if cancelled.
    public static func cluster(_ x: [Float], count n: Int, dimensions d: Int,
                               isCancelled: () -> Bool = { false }) -> [Int]? {
        x.withUnsafeBufferPointer { cluster($0, count: n, dimensions: d, isCancelled: isCancelled) }
    }

    /// The same from floats kept elsewhere (the app's in a `PageBuffer`: big sets are tens of MB,
    /// and memory the allocator once had stays counted as the app's on macOS 27).
    public static func cluster(_ x: UnsafeBufferPointer<Float>, count n: Int, dimensions d: Int,
                               isCancelled: () -> Bool = { false }) -> [Int]? {
        let k = groupCount(n)
        guard k > 1 else { return Array(repeating: 0, count: n) }
        // Centred on this set: what sets these sounds apart, not what they share (Phase 0: it
        // fixed PE-AV's grouping).
        let buffer = PageBuffer(count: n * d)
        let reduced: [Float]? = buffer.withFloats { space in
            blockNormalise(x, n: n, d: d, into: space)
            if n < 30 {
                // Phase 0: PCA to up to 10 dimensions.
                let m = max(2, min(10, n - 1))
                var rng = SoundMap.SplitMix(seed: 42)
                let p = SoundMap.principal(UnsafeBufferPointer(space), n: n, d: d, count: m, rng: &rng)
                return (0 ..< n).flatMap { i in p.map { $0[i] } }
            }
            // UMAP with the cosine distance: rows to unit length.
            for i in 0 ..< n {
                var s: Float = 0
                for c in 0 ..< d { s += space[i * d + c] * space[i * d + c] }
                let l = max(s.squareRoot(), 1e-12)
                for c in 0 ..< d { space[i * d + c] /= l }
            }
            var settings = SoundMap.Settings.clustering
            settings.neighbours = min(15, n - 1)
            return SoundMap.reduce(flat: UnsafeBufferPointer(space), count: n, dimensions: d, components: min(10, n - 2),
                                   settings: settings, isCancelled: isCancelled)
        }
        guard let reduced else { return nil }
        return ward(reduced, count: n, dimensions: reduced.count / n, groups: k)
    }

    /// Ward's clustering (each merge the one that adds least to the groups' spread) cut at `k`
    /// groups, groups under `minGroupSize` then joined to their nearest. Labels by size, largest
    /// 0. The nearest-neighbour chain over group centres: O(n²·d) time, no distance matrix.
    static func ward(_ z: [Float], count n: Int, dimensions d: Int, groups k: Int) -> [Int] {
        guard n > 1, k > 1 else { return Array(repeating: 0, count: n) }
        // Slot i starts as point i; a merged group stays in the lower slot (one of its points).
        var centre = z.prefix(n * d).map(Double.init)
        var size = [Double](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        func cost(_ a: Int, _ b: Int) -> Double {
            var t = 0.0
            for c in 0 ..< d { let v = centre[a * d + c] - centre[b * d + c]; t += v * v }
            return size[a] * size[b] / (size[a] + size[b]) * t
        }
        func merge(_ a: Int, _ b: Int) {
            let keep = min(a, b), drop = max(a, b), s = size[a] + size[b]
            for c in 0 ..< d { centre[keep * d + c] = (centre[a * d + c] * size[a] + centre[b * d + c] * size[b]) / s }
            size[keep] = s
            active[drop] = false
        }
        var merges: [(a: Int, b: Int, cost: Double)] = []
        merges.reserveCapacity(n - 1)
        var chain: [Int] = []
        var first = 0
        while merges.count < n - 1 {
            if chain.isEmpty {
                while !active[first] { first += 1 }
                chain.append(first)
            }
            let a = chain[chain.count - 1], previous = chain.count >= 2 ? chain[chain.count - 2] : -1
            // The nearest group, the one before in the chain when tied (so the chain ends).
            var best = previous, bestCost = previous >= 0 ? cost(a, previous) : .infinity
            for j in 0 ..< n where active[j] && j != a {
                let c = cost(a, j)
                if c < bestCost { best = j; bestCost = c }
            }
            if best == previous {
                chain.removeLast(2)
                merges.append((a, previous, bestCost))
                merge(a, previous)
            } else {
                chain.append(best)
            }
        }
        // The cheapest n − k merges (Ward's costs only grow up the tree), on the points.
        var parent = Array(0 ..< n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var y = x
            while parent[y] != r { let up = parent[y]; parent[y] = r; y = up }
            return r
        }
        let order = merges.indices.sorted { (merges[$0].cost, $0) < (merges[$1].cost, $1) }
        for m in order.prefix(n - k) { parent[find(merges[m].a)] = find(merges[m].b) }
        var groups: [Int: [Int]] = [:]
        for i in 0 ..< n { groups[find(i), default: []].append(i) }
        // Too-small groups join the group whose centre is nearest (by Ward's cost).
        var sets = Array(groups.values)
        func centreOf(_ g: [Int]) -> [Double] {
            var c = [Double](repeating: 0, count: d)
            for i in g { for j in 0 ..< d { c[j] += Double(z[i * d + j]) } }
            return c.map { $0 / Double(g.count) }
        }
        while sets.count > 1, let small = sets.indices.filter({ sets[$0].count < minGroupSize }).min(by: { sets[$0].count < sets[$1].count }) {
            let c = centreOf(sets[small])
            let target = sets.indices.filter { $0 != small }.min { a, b in
                func wardCost(_ g: Int) -> Double {
                    let o = centreOf(sets[g]), s = Double(sets[g].count), t = Double(sets[small].count)
                    return s * t / (s + t) * zip(c, o).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
                }
                return wardCost(a) < wardCost(b)
            }!
            sets[target] += sets[small]
            sets.remove(at: small)
        }
        sets.sort { $0.count != $1.count ? $0.count > $1.count : $0.min()! < $1.min()! }
        var labels = [Int](repeating: 0, count: n)
        for (g, members) in sets.enumerated() { for i in members { labels[i] = g } }
        return labels
    }

    /// Phase 0's _block_normalize: centred on the set, scaled to an average length of 1.
    static func blockNormalise(_ x: UnsafeBufferPointer<Float>, n: Int, d: Int, into out: UnsafeMutableBufferPointer<Float>) {
        var mean = [Double](repeating: 0, count: d)
        for i in 0 ..< n { for c in 0 ..< d { mean[c] += Double(x[i * d + c]) } }
        mean = mean.map { $0 / Double(n) }
        var total = 0.0
        for i in 0 ..< n {
            for c in 0 ..< d {
                let v = Double(x[i * d + c]) - mean[c]
                out[i * d + c] = Float(v)
                total += v * v
            }
        }
        let scale = Float(1 / (total / Double(n) + 1e-12).squareRoot())
        for i in 0 ..< n * d { out[i] *= scale }
    }

    // MARK: names

    /// The words groups are named with (Phase 0's DESCRIPTORS).
    public static let words = ["airy", "breathy", "windy", "swishy", "whooshing", "swooshing", "fluttering", "whipping", "fast", "slow", "short", "long", "sustained", "rising", "falling", "pass-by", "doppler", "deep", "low rumble", "sub bass", "high-pitched", "bright", "dark", "muffled", "thin", "full", "metallic", "ringing", "resonant", "glassy", "wooden", "cloth", "fabric", "paper", "plastic", "rubber", "watery", "splashy", "liquid", "fiery", "crackling", "electric", "buzzing", "humming", "static", "digital", "glitchy", "synthetic", "sci-fi", "futuristic", "laser", "magical", "sparkly", "shimmering", "ethereal", "eerie", "dark ambient", "cinematic", "trailer", "aggressive", "heavy", "light", "soft", "harsh", "gritty", "distorted", "noisy", "tonal", "musical", "reversed", "granular", "organic", "mechanical", "motor", "engine", "wind gust", "animal", "creature", "vocal", "human", "impact", "hit", "boom", "thud", "punchy", "click", "snap", "crunchy", "squeaky", "creaky", "explosive", "distant", "close-up", "roomy", "reverberant", "dry", "beep", "alarm", "tick"]

    /// The words' text embeddings, combined like the sounds' (PE-AV, then CLAP): `words.count`
    /// rows of 1536. From Phase 0's text models (`models/export_groups.py`); nil without the file.
    public static let wordVectors: [Float]? = {
        guard let url = UCSCatalog.bundledResource("group_words", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = words.count, peav = 1024, clap = 512
        guard floats.count == n * (peav + clap) else { return nil }
        return (0 ..< n).flatMap { i in
            SoundMap.combine([Array(floats[i * peav ..< (i + 1) * peav]),
                              Array(floats[n * peav + i * clap ..< n * peav + (i + 1) * clap])])
        }
    }()

    /// What a group is called and the words behind it.
    public struct Name: Codable, Equatable, Sendable {
        public var name: String
        /// Closest to the sound, from the AI (most telling first).
        public var aiWords: [String]
        /// From the group's sounds' length, against the set's.
        public var shapeWords: [String]
        /// Words most of the group's files share (names, descriptions, keywords).
        public var keywords: [String]
    }

    /// One sound, for naming.
    public struct Member: Sendable {
        public var duration: Double?
        /// File name, FX name, description and keywords.
        public var text: String
        public init(duration: Double?, text: String) {
            self.duration = duration
            self.text = text
        }

        public init(_ s: SoundRecord) {
            self.init(duration: s.duration, text: [s.fileName.replacingOccurrences(of: "_", with: " "), s.fxName ?? "",
                                                   s.details ?? "", s.keywords ?? ""].joined(separator: " "))
        }
    }

    /// Words that never make keywords for these sounds: CatIDs, and who made them (library,
    /// manufacturer, designer, the pack's top folder), so pack names don't leak in (Phase 0's
    /// "ocular", "b00m").
    public static func excludedWords(for sounds: [SoundRecord]) -> Set<String> {
        var out = catIDWords
        for s in sounds {
            for field in [s.vendorLibrary, s.manufacturer, s.designer, s.folder.split(separator: "/").first.map(String.init)] {
                if let field { out.formUnion(tokens(field)) }
            }
        }
        return out
    }

    static let catIDWords = Set(UCSCatalog.shared.entries.map { $0.catID.lowercased() })

    /// Names for a set's groups (`groups`: each group's rows in `x`). `libraryMean`: the mean
    /// of every analysed sound's vector, so words that fit everything in the library count less.
    /// `exclude`: words never used as keywords (CatIDs, pack and vendor names).
    public static func names(groups: [[Int]], x: [Float], dimensions d: Int, members: [Member],
                             libraryMean: [Float], exclude: Set<String>) -> [Name] {
        x.withUnsafeBufferPointer {
            names(groups: groups, x: $0, dimensions: d, members: members, libraryMean: libraryMean, exclude: exclude)
        }
    }

    public static func names(groups: [[Int]], x: UnsafeBufferPointer<Float>, dimensions d: Int, members: [Member],
                             libraryMean: [Float], exclude: Set<String>) -> [Name] {
        guard !groups.isEmpty else { return [] }
        let ai = aiWords(groups: groups, x: x, d: d, libraryMean: libraryMean)
        let shape = shapeWords(groups: groups, members: members)
        let keys = keywords(groups: groups, texts: members.map(\.text), exclude: exclude)
        var used: [String: Int] = [:]
        return groups.indices.map { g in
            // One word per family of near-synonyms: "Whooshing · Swooshing" says one thing.
            func fits(_ w: String, _ chosen: [String]) -> Bool {
                !chosen.contains(w) && !chosen.contains { synonym[$0] != nil && synonym[$0] == synonym[w] }
            }
            var chosen: [String] = []
            var rest = Array(ai[g])
            for w in shape[g].prefix(2) + ai[g] where chosen.count < 3 && fits(w, chosen) {
                chosen.append(w)
                rest.removeAll { $0 == w }
            }
            var name = chosen.map(capitalised).joined(separator: " · ")
            if name.isEmpty { name = "Group \(g + 1)" }
            // Two groups with the same name: the next words the AI found, else a number.
            var extra = rest.makeIterator()
            while used[name] != nil, let w = extra.next() {
                guard fits(w, chosen) else { continue }
                chosen.append(w)
                name = chosen.map(capitalised).joined(separator: " · ")
            }
            if let n = used[name] { used[name] = n + 1; name += " \(n + 1)" } else { used[name] = 1 }
            return Name(name: name, aiWords: Array(ai[g].prefix(3)), shapeWords: shape[g], keywords: keys[g])
        }
    }

    /// Words that say nearly the same thing (by hand: the text embeddings don't tell synonyms
    /// apart, "short" and "long" are closer than "vocal" and "human"). Word → family.
    static let synonym: [String: Int] = {
        let families = [
            ["whooshing", "swooshing", "swishy"], ["windy", "wind gust", "airy"], ["sci-fi", "futuristic"],
            ["impact", "hit"], ["cloth", "fabric"], ["boom", "explosive"], ["watery", "liquid"], ["motor", "engine"],
            ["vocal", "human"], ["animal", "creature"], ["crunchy", "crackling"], ["low rumble", "sub bass", "deep"],
            ["dark", "dark ambient"], ["digital", "glitchy"], ["ethereal", "eerie"], ["ringing", "resonant"],
            ["sparkly", "shimmering"], ["long", "sustained", "slow"], ["static", "noisy"], ["humming", "buzzing"],
            ["squeaky", "creaky"], ["click", "tick", "snap"], ["muffled", "distant"], ["aggressive", "harsh"],
            ["cinematic", "trailer"], ["alarm", "beep"], ["light", "soft"], ["bright", "high-pitched"],
        ]
        var out: [String: Int] = [:]
        for (i, f) in families.enumerated() { for w in f { out[w] = i } }
        return out
    }()

    /// Phase 0's descriptor_names: the words nearest each group's centre, less the set's average
    /// (0.6) and the library's (0.3), so groups get the words that set them apart. Six per group.
    static func aiWords(groups: [[Int]], x: UnsafeBufferPointer<Float>, d: Int, libraryMean: [Float]) -> [[String]] {
        guard let vectors = wordVectors, d == vectors.count / words.count else { return groups.map { _ in [] } }
        let w = words.count
        func scores(_ v: [Float]) -> [Float] {
            (0 ..< w).map { j in var s: Float = 0; for c in 0 ..< d { s += v[c] * vectors[j * d + c] }; return s }
        }
        let rows: [[Float]] = groups.map { members in
            var centre = [Float](repeating: 0, count: d)
            for i in members { for c in 0 ..< d { centre[c] += x[i * d + c] } }
            let l = max(centre.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-12)
            return scores(centre.map { $0 / l })
        }
        let library = libraryMean.count == d ? scores(libraryMean) : [Float](repeating: 0, count: w)
        let setMean = (0 ..< w).map { j in rows.reduce(0) { $0 + $1[j] } / Float(rows.count) }
        return rows.map { s in
            let adjusted = (0 ..< w).map { s[$0] - 0.6 * setMean[$0] - 0.3 * library[$0] }
            return adjusted.indices.sorted { adjusted[$0] > adjusted[$1] }.prefix(6).map { words[$0] }
        }
    }

    /// Phase 0's describe_shape, for length: "short" or "long" against the set's 33rd and 67th
    /// percentiles, when the set's lengths really vary.
    static func shapeWords(groups: [[Int]], members: [Member]) -> [[String]] {
        let all = groups.flatMap { $0 }.compactMap { members[$0].duration }.sorted()
        guard all.count >= 3 else { return groups.map { _ in [] } }
        func percentile(_ p: Double) -> Double {
            let r = p / 100 * Double(all.count - 1), lo = Int(r), hi = min(lo + 1, all.count - 1)
            return all[lo] + (all[hi] - all[lo]) * (r - Double(lo))
        }
        let lo = percentile(33), hi = percentile(67)
        guard hi > 1.4 * lo else { return groups.map { _ in [] } }
        return groups.map { g in
            let lengths = g.compactMap { members[$0].duration }
            guard !lengths.isEmpty else { return [] }
            let mean = lengths.reduce(0, +) / Double(lengths.count)
            return mean <= lo ? ["short"] : mean >= hi ? ["long"] : []
        }
    }

    static let stopWords: Set<String> = Set("""
        a an and the of in on at to for with by from as or is are be into over under up down out off \
        this that these those it its very more most some any each all no not one two three sfx fx sound sounds effect \
        effects designed version var variation take wav mono stereo audio file pack library vol volume
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Phase 0's tokens: lowercase words of 3+ letters (hyphens allowed), no stop words.
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = [], word = ""
        func flush() {
            if word.count >= 3, !stopWords.contains(word) { out.append(word) }
            word = ""
        }
        for ch in text.lowercased() {
            if ch >= "a" && ch <= "z" || (ch == "-" && !word.isEmpty) { word.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// Phase 0's keyword_names: words at least 30% of a group's files have, by how much more
    /// often than in the set's other groups (TF-IDF style). Three per group. Unlike Phase 0, a
    /// word that most of the groups have is left out: it describes the set ("human" in human
    /// footsteps, a collection's name), not the group.
    static func keywords(groups: [[Int]], texts: [String], exclude: Set<String>) -> [[String]] {
        var df: [String: Int] = [:], common: [String: Int] = [:]
        let counts: [[String: Int]] = groups.map { g in
            var c: [String: Int] = [:]
            for i in g { for t in Set(tokens(texts[i])) where !exclude.contains(t) { c[t, default: 0] += 1 } }
            for (w, cnt) in c {
                df[w, default: 0] += 1
                if Double(cnt) >= 0.3 * Double(g.count) { common[w, default: 0] += 1 }
            }
            return c
        }
        let n = Double(max(1, groups.count))
        return groups.indices.map { g in
            let size = Double(max(1, groups[g].count))
            let scored = counts[g].compactMap { w, cnt -> (Double, String)? in
                guard Double(cnt) / size >= 0.3, groups.count < 3 || common[w, default: 0] * 2 <= groups.count else { return nil }
                return (Double(cnt) / size * log(1 + n / Double(df[w]!)), w)
            }
            return scored.sorted { $0 > $1 }.prefix(3).map(\.1)
        }
    }

    /// Python's str.capitalize: "Sci-fi", "Low rumble".
    static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst().lowercased() }
}
