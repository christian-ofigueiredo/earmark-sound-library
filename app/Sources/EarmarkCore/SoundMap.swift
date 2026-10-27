import Foundation
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(Glibc)
import Glibc   // mmap (PageBuffer)
#endif

/// A 2-D map of sounds where sounds that sound alike sit close: UMAP (McInnes et al.), ported
/// from umap-learn 0.5 with Phase 0's settings (cosine, 15 neighbours, min_dist 0.15; Phase 0's
/// `layout_2d`). Differences from umap-learn: it starts from PCA instead of a spectral layout
/// (that needs a sparse eigensolver), and has its own seeded random numbers, so the same sounds
/// always give the same map, though not the same one as Python.
public enum SoundMap {
    public struct Settings: Sendable {
        public var neighbours = 15
        /// umap-learn's find_ab_params(spread 1, min_dist 0.15).
        public var a: Float = 1.4139999224375945
        public var b: Float = 0.9488152489297249
        public var negativeSamples = 5
        public var seed: UInt64 = 42

        public init() {}

        /// For grouping (Phase 0's `reduce_for_clustering`): min_dist 0, so alike sounds pack
        /// tight. umap-learn's find_ab_params(spread 1, min_dist 0).
        public static var clustering: Settings {
            var s = Settings()
            s.a = 1.932808397545408
            s.b = 0.7904949735905139
            return s
        }

        /// umap-learn's default: 500 for small data, 200 from 10,000 points.
        func epochs(_ n: Int) -> Int { n <= 10_000 ? 500 : 200 }
    }

    /// Phase 0's combination of models: each embedding L2-normalised, concatenated, scaled to unit length.
    public static func combine(_ blocks: [[Float]]) -> [Float] {
        let scale = 1 / Float(blocks.count).squareRoot()
        return blocks.flatMap { v -> [Float] in
            let norm = max(1e-12, v.reduce(0) { $0 + $1 * $1 }.squareRoot())
            return v.map { $0 / norm * scale }
        }
    }

    /// Positions in 0…1 (the longer side spans 0…1; aspect kept), one per vector. `vectors`:
    /// unit length, all the same size. `progress` gets 0…1; `isCancelled` stops early (nil result).
    public static func layout(_ vectors: [[Float]], settings: Settings = .init(),
                              progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> [SIMD2<Float>]? {
        vectors.flatMap { $0 }.withUnsafeBufferPointer {
            layout(flat: $0, count: vectors.count, dimensions: vectors.first?.count ?? 0,
                   settings: settings, progress: progress, isCancelled: isCancelled)
        }
    }

    /// The same from `count` × `dimensions` floats, row after row (for the whole library 177 MB,
    /// so the caller keeps them how it likes, usually in a `PageBuffer`).
    public static func layout(flat x: UnsafeBufferPointer<Float>, count n: Int, dimensions d: Int, settings: Settings = .init(),
                              progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> [SIMD2<Float>]? {
        map(flat: x, count: n, dimensions: d, settings: settings, progress: progress, isCancelled: isCancelled)?.points
    }

    /// A layout and the lines to draw on it between sounds that are alike.
    public struct Map: Sendable {
        public var points: [SIMD2<Float>]
        /// Each sound with its `linksPerSound` nearest in the embedding space, every pair once
        /// (lower index first), in order.
        public var links: [SIMD2<Int32>]
    }

    /// `layout(flat:…)` with the links between neighbours (none under 20 sounds: no neighbour search).
    public static func map(flat x: UnsafeBufferPointer<Float>, count n: Int, dimensions d: Int, settings: Settings = .init(),
                           linksPerSound: Int = 3, progress: (Double) -> Void = { _ in },
                           isCancelled: () -> Bool = { false }) -> Map? {
        guard n > 2 else { return Map(points: n == 0 ? [] : n == 1 ? [SIMD2(0.5, 0.5)] : [SIMD2(0, 0.5), SIMD2(1, 0.5)], links: []) }
        var rng = SplitMix(seed: settings.seed)
        var start = pca(x, n: n, d: d, rng: &rng)
        // Too few points for a neighbourhood graph: PCA alone, as Phase 0.
        guard n >= 20 else { return Map(points: fit(start), links: []) }
        let k = min(settings.neighbours, n - 1)
        guard let (indices, distances) = neighbours(x, n: n, d: d, k: k, progress: { progress($0 * 0.4) }, isCancelled: isCancelled)
        else { return nil }
        let links = Self.links(indices: indices, n: n, k: k, each: linksPerSound)
        let graph = fuzzyGraph(indices: indices, distances: distances, n: n, k: k)
        // umap-learn: PCA scaled so its largest coordinate is 10, a little noise, then into a 0…10 box.
        let extent = max(1e-12, start.map { max(abs($0.x), abs($0.y)) }.max() ?? 1)
        start = start.map { $0 * (10 / extent) + SIMD2(rng.normal(0.0001), rng.normal(0.0001)) }
        let lo = start.reduce(start[0], pointwiseMin(_:_:)), hi = start.reduce(start[0], pointwiseMax(_:_:))
        let span = pointwiseMax(hi - lo, SIMD2(repeating: 1e-12))
        var y = start.map { 10 * ($0 - lo) / span }
        guard optimise(&y, graph: graph, n: n, settings: settings, rng: &rng,
                       progress: { progress(0.4 + $0 * 0.6) }, isCancelled: isCancelled) else { return nil }
        return Map(points: fit(y), links: links)
    }

    /// The same layout in `components` dimensions instead of 2, flat (n × components), for
    /// grouping: Phase 0 clustered in 10. `x`: unit-length rows. Nil if cancelled.
    public static func reduce(flat x: UnsafeBufferPointer<Float>, count n: Int, dimensions d: Int, components m: Int,
                              settings: Settings = .clustering, isCancelled: () -> Bool = { false }) -> [Float]? {
        guard n > 2, m > 0 else { return [Float](repeating: 0, count: n * m) }
        var rng = SplitMix(seed: settings.seed)
        let start = principal(x, n: n, d: d, count: m, rng: &rng)
        guard n >= 20 else { return (0 ..< n).flatMap { i in start.map { $0[i] } } }
        let k = min(settings.neighbours, n - 1)
        guard let (indices, distances) = neighbours(x, n: n, d: d, k: k, progress: { _ in }, isCancelled: isCancelled)
        else { return nil }
        let graph = fuzzyGraph(indices: indices, distances: distances, n: n, k: k)
        // As `map`: largest coordinate 10, a little noise, then each dimension into 0…10.
        let extent = max(1e-12, start.map { $0.map(abs).max() ?? 0 }.max() ?? 1)
        var y = [Float](repeating: 0, count: n * m)
        for i in 0 ..< n { for c in 0 ..< m { y[i * m + c] = start[c][i] * (10 / extent) + rng.normal(0.0001) } }
        for c in 0 ..< m {
            var lo = Float.infinity, hi = -Float.infinity
            for i in 0 ..< n { lo = min(lo, y[i * m + c]); hi = max(hi, y[i * m + c]) }
            let span = max(hi - lo, 1e-12)
            for i in 0 ..< n { y[i * m + c] = 10 * (y[i * m + c] - lo) / span }
        }
        guard optimise(&y, dimensions: m, graph: graph, n: n, settings: settings, rng: &rng, isCancelled: isCancelled)
        else { return nil }
        return y
    }

    /// Each point with its `each` nearest (from the neighbour search, itself left out), every
    /// pair once, sorted.
    static func links(indices: [Int], n: Int, k: Int, each: Int) -> [SIMD2<Int32>] {
        var pairs = Set<Int64>()
        for i in 0 ..< n {
            for c in 0 ..< k where c <= each {
                let j = indices[i * k + c]
                guard j != i else { continue }
                pairs.insert(Int64(min(i, j)) * Int64(n) + Int64(max(i, j)))
            }
        }
        return pairs.sorted().map { SIMD2(Int32($0 / Int64(n)), Int32($0 % Int64(n))) }
    }

    /// How well a layout keeps neighbours: for each point, the share of its `k` nearest in the
    /// original space that are among its `k` nearest on the map (0…1, averaged).
    public static func neighboursKept(_ vectors: [[Float]], layout: [SIMD2<Float>], k: Int = 15) -> Double {
        let n = vectors.count, d = vectors.first?.count ?? 0
        guard n > k, layout.count == n else { return 0 }
        guard let (original, _) = vectors.flatMap({ $0 }).withUnsafeBufferPointer({
            neighbours($0, n: n, d: d, k: k, progress: { _ in }, isCancelled: { false })
        }) else { return 0 }
        var total = 0.0
        for i in 0 ..< n {
            // The k nearest on the map (plain, it's 2-D).
            var best: [(Int, Float)] = []
            for j in 0 ..< n where j != i {
                let dist = distance2(layout[i], layout[j])
                if best.count < k { best.append((j, dist)); if best.count == k { best.sort { $0.1 < $1.1 } } }
                else if dist < best[k - 1].1 {
                    var p = k - 1
                    while p > 0, best[p - 1].1 > dist { p -= 1 }
                    best.insert((j, dist), at: p)
                    best.removeLast()
                }
            }
            let mine = Set(best.map(\.0))
            let theirs = original[i * k ..< (i + 1) * k].filter { $0 != i }
            total += Double(theirs.filter { mine.contains($0) }.count) / Double(max(1, theirs.count))
        }
        return total / Double(n)
    }

    // MARK: steps

    /// Each point's `k` nearest by cosine distance (1 − dot), itself first: flat n × k indices and distances.
    static func neighbours(_ x: UnsafeBufferPointer<Float>, n: Int, d: Int, k: Int, progress: (Double) -> Void,
                           isCancelled: () -> Bool) -> (indices: [Int], distances: [Float])? {
        var indices = [Int](repeating: 0, count: n * k), distances = [Float](repeating: 0, count: n * k)
        // Blocks of 64 rows, a few at a time: each needs n × 64 scores (7 MB for 29k sounds, in
        // a PageBuffer so it goes back to the system after).
        let block = 64
        let blocks = (n + block - 1) / block
        let batch = 32   // blocks between checks for cancellation
        for batchStart in stride(from: 0, to: blocks, by: batch) {
            if isCancelled() { return nil }
            progress(Double(batchStart) / Double(blocks))
            indices.withUnsafeMutableBufferPointer { idxBuffer in
                distances.withUnsafeMutableBufferPointer { dstBuffer in
                    // Blocks of rows in parallel; each writes only its own rows.
                    nonisolated(unsafe) let xs = x
                    nonisolated(unsafe) let idx = idxBuffer
                    nonisolated(unsafe) let dst = dstBuffer
                    DispatchQueue.concurrentPerform(iterations: min(batch, blocks - batchStart)) { offset in
                        let first = (batchStart + offset) * block, m = min(block, n - first)
                        PageBuffer(count: n * m).withFloats { scores in
                            dots(xs, rows: first ..< first + m, n: n, d: d, into: scores)
                            // Each row's best so far, best first; equal scores keep the earlier point first.
                            var bestIndex = [Int](repeating: 0, count: m * k), bestScore = [Float](repeating: 0, count: m * k)
                            var found = [Int](repeating: 0, count: m)
                            for j in 0 ..< n {
                                for r in 0 ..< m {
                                    // Itself first, at distance 0, as umap-learn's search returns it.
                                    let s = j == first + r ? Float.infinity : scores[j * m + r]
                                    let base = r * k, count = found[r]
                                    if count == k, s <= bestScore[base + k - 1] { continue }
                                    var p = min(count, k - 1)
                                    while p > 0, bestScore[base + p - 1] < s {
                                        bestScore[base + p] = bestScore[base + p - 1]
                                        bestIndex[base + p] = bestIndex[base + p - 1]
                                        p -= 1
                                    }
                                    bestScore[base + p] = s
                                    bestIndex[base + p] = j
                                    if count < k { found[r] = count + 1 }
                                }
                            }
                            for r in 0 ..< m {
                                let i = first + r
                                for c in 0 ..< k {
                                    let j = bestIndex[r * k + c]
                                    idx[i * k + c] = j
                                    dst[i * k + c] = j == i ? 0 : max(0, 1 - bestScore[r * k + c])
                                }
                            }
                        }
                    }
                }
            }
        }
        progress(1)
        return (indices, distances)
    }

    /// scores[j * m + r] = x[j] · x[rows.lowerBound + r], where m = rows.count.
    private static func dots(_ x: UnsafeBufferPointer<Float>, rows: Range<Int>, n: Int, d: Int, into scores: UnsafeMutableBufferPointer<Float>) {
        let m = rows.count
        #if canImport(Accelerate)
        // All (n × d) · the block's rows transposed (d × m).
        var blockT = [Float](repeating: 0, count: d * m)
        vDSP_mtrans(x.baseAddress! + rows.lowerBound * d, 1, &blockT, 1, vDSP_Length(d), vDSP_Length(m))
        vDSP_mmul(x.baseAddress!, 1, blockT, 1, scores.baseAddress!, 1, vDSP_Length(n), vDSP_Length(m), vDSP_Length(d))
        #else
        for j in 0 ..< n {
            for (r, i) in rows.enumerated() {
                var s: Float = 0
                for c in 0 ..< d { s += x[i * d + c] * x[j * d + c] }
                scores[j * m + r] = s
            }
        }
        #endif
    }

    struct Edge { var head: Int32; var tail: Int32; var weight: Float }

    /// umap-learn's fuzzy_simplicial_set (local connectivity 1, set_op_mix_ratio 1): each
    /// point's neighbour memberships, then their fuzzy union A + Aᵀ − A∘Aᵀ, as directed edges.
    static func fuzzyGraph(indices: [Int], distances: [Float], n: Int, k: Int) -> [Edge] {
        let target = log2(Float(k))
        let meanAll = distances.reduce(0, +) / Float(distances.count)
        // weights[i * k + c]: how much indices[i * k + c] belongs to i's neighbourhood (0 for i itself).
        var weights = [Float](repeating: 0, count: n * k)
        for i in 0 ..< n {
            let row = distances[i * k ..< (i + 1) * k]
            let rho = row.first { $0 > 0 } ?? 0
            // sigma: Σ exp(−max(0, d − rho)/sigma) over the neighbours (not itself) = log2(k).
            var lo: Float = 0, hi = Float.infinity, mid: Float = 1
            for _ in 0 ..< 64 {
                var sum: Float = 0
                for c in 1 ..< k {
                    let x = row[i * k + c] - rho
                    sum += x > 0 ? exp(-x / mid) : 1
                }
                if abs(sum - target) < 1e-5 { break }
                if sum > target {
                    hi = mid; mid = (lo + hi) / 2
                } else {
                    lo = mid; mid = hi == .infinity ? mid * 2 : (lo + hi) / 2
                }
            }
            let meanRow = row.reduce(0, +) / Float(k)
            var sigma = mid
            if rho > 0 { sigma = max(sigma, 1e-3 * meanRow) } else { sigma = max(sigma, 1e-3 * meanAll) }
            for c in 0 ..< k where indices[i * k + c] != i {
                let x = row[i * k + c] - rho
                weights[i * k + c] = x <= 0 || sigma == 0 ? 1 : exp(-x / sigma)
            }
        }
        /// How much j belongs to i's neighbourhood; nil if it isn't among i's neighbours.
        func weight(_ i: Int, _ j: Int) -> Float? {
            for c in 0 ..< k where indices[i * k + c] == j && j != i { return weights[i * k + c] }
            return nil
        }
        // In the neighbours' order (the map depends on the edges' order).
        var edges: [Edge] = []
        edges.reserveCapacity(n * k * 3 / 2)
        for i in 0 ..< n {
            for c in 0 ..< k where indices[i * k + c] != i {
                let j = indices[i * k + c], w = weights[i * k + c], back = weight(j, i) ?? 0
                edges.append(Edge(head: Int32(i), tail: Int32(j), weight: w + back - w * back))
            }
        }
        // The other direction of one-way neighbourhoods (i has j, j doesn't have i).
        for i in 0 ..< n {
            for c in 0 ..< k where indices[i * k + c] != i {
                let j = indices[i * k + c]
                if weight(j, i) == nil { edges.append(Edge(head: Int32(j), tail: Int32(i), weight: weights[i * k + c])) }
            }
        }
        return edges
    }

    /// umap-learn's optimize_layout_euclidean: attraction along the graph's edges, repulsion
    /// from random points, learning rate falling to 0. False if cancelled.
    static func optimise(_ y: inout [SIMD2<Float>], graph: [Edge], n: Int, settings: Settings, rng: inout SplitMix,
                         progress: (Double) -> Void, isCancelled: () -> Bool) -> Bool {
        let epochs = settings.epochs(n)
        let maxWeight = graph.map(\.weight).max() ?? 1
        // Edges too weak to be sampled even once are dropped, as umap-learn does.
        let edges = graph.filter { $0.weight >= maxWeight / Float(epochs) }
        let perSample = edges.map { Float(epochs) / (Float(epochs) * $0.weight / maxWeight) }
        let negRate = Float(settings.negativeSamples)
        let perNegative = perSample.map { $0 / negRate }
        var nextSample = perSample, nextNegative = perNegative
        let a = settings.a, b = settings.b
        func clip(_ v: Float) -> Float { min(4, max(-4, v)) }
        for epoch in 0 ..< epochs {
            let alpha = 1 - Float(epoch) / Float(epochs)
            let e = Float(epoch)
            for i in edges.indices where nextSample[i] <= e {
                let j = Int(edges[i].head), t = Int(edges[i].tail)
                var current = y[j], other = y[t]
                let dist2 = distance2(current, other)
                if dist2 > 0 {
                    let coeff = -2 * a * b * pow(dist2, b - 1) / (a * pow(dist2, b) + 1)
                    let grad = SIMD2(clip(coeff * (current.x - other.x)), clip(coeff * (current.y - other.y)))
                    current += grad * alpha
                    other -= grad * alpha
                    y[t] = other
                }
                nextSample[i] += perSample[i]
                let negatives = Int((e - nextNegative[i]) / perNegative[i])
                for _ in 0 ..< max(0, negatives) {
                    let r = Int(rng.next() % UInt64(n))
                    if r == j { continue }
                    let o = y[r]
                    let d2 = distance2(current, o)
                    var grad = SIMD2<Float>(repeating: 4)
                    if d2 > 0 {
                        let coeff = 2 * b / ((0.001 + d2) * (a * pow(d2, b) + 1))
                        grad = SIMD2(clip(coeff * (current.x - o.x)), clip(coeff * (current.y - o.y)))
                    }
                    current += grad * alpha
                }
                y[j] = current
                nextNegative[i] += Float(max(0, negatives)) * perNegative[i]
            }
            if epoch % 10 == 0 {
                progress(Double(epoch) / Double(epochs))
                if isCancelled() { return false }
            }
        }
        progress(1)
        return true
    }

    /// `optimise` in any number of dimensions (`y`: n × `m`, flat), for `reduce`.
    static func optimise(_ y: inout [Float], dimensions m: Int, graph: [Edge], n: Int, settings: Settings,
                         rng: inout SplitMix, isCancelled: () -> Bool) -> Bool {
        let epochs = settings.epochs(n)
        let maxWeight = graph.map(\.weight).max() ?? 1
        let edges = graph.filter { $0.weight >= maxWeight / Float(epochs) }
        let perSample = edges.map { Float(epochs) / (Float(epochs) * $0.weight / maxWeight) }
        let perNegative = perSample.map { $0 / Float(settings.negativeSamples) }
        var nextSample = perSample, nextNegative = perNegative
        let a = settings.a, b = settings.b
        func clip(_ v: Float) -> Float { min(4, max(-4, v)) }
        var current = [Float](repeating: 0, count: m)
        return y.withUnsafeMutableBufferPointer { y in
            func distance2(_ p: [Float], _ o: Int) -> Float {
                var s: Float = 0
                for c in 0 ..< m { let t = p[c] - y[o * m + c]; s += t * t }
                return s
            }
            for epoch in 0 ..< epochs {
                let alpha = 1 - Float(epoch) / Float(epochs), e = Float(epoch)
                for i in edges.indices where nextSample[i] <= e {
                    let j = Int(edges[i].head), t = Int(edges[i].tail)
                    for c in 0 ..< m { current[c] = y[j * m + c] }
                    let dist2 = distance2(current, t)
                    if dist2 > 0 {
                        let coeff = -2 * a * b * pow(dist2, b - 1) / (a * pow(dist2, b) + 1)
                        for c in 0 ..< m {
                            let grad = clip(coeff * (current[c] - y[t * m + c])) * alpha
                            current[c] += grad
                            y[t * m + c] -= grad
                        }
                    }
                    nextSample[i] += perSample[i]
                    let negatives = max(0, Int((e - nextNegative[i]) / perNegative[i]))
                    for _ in 0 ..< negatives {
                        let r = Int(rng.next() % UInt64(n))
                        if r == j { continue }
                        let d2 = distance2(current, r)
                        let coeff = d2 > 0 ? 2 * b / ((0.001 + d2) * (a * pow(d2, b) + 1)) : 0
                        for c in 0 ..< m { current[c] += (d2 > 0 ? clip(coeff * (current[c] - y[r * m + c])) : 4) * alpha }
                    }
                    for c in 0 ..< m { y[j * m + c] = current[c] }
                    nextNegative[i] += Float(negatives) * perNegative[i]
                }
                if epoch % 10 == 0, isCancelled() { return false }
            }
            return true
        }
    }

    /// The first two principal components (power iteration on the centred XᵀX), as starting
    /// positions. Centred arithmetically: Xc v = X v − (m·v), Xcᵀ u = Xᵀ u − m Σu (no centred copy).
    static func pca(_ x: UnsafeBufferPointer<Float>, n: Int, d: Int, rng: inout SplitMix) -> [SIMD2<Float>] {
        let p = principal(x, n: n, d: d, count: 2, rng: &rng)
        return (0 ..< n).map { SIMD2(p[0][$0], p[1][$0]) }
    }

    /// The first `count` principal components' coordinates, one array per component.
    static func principal(_ x: UnsafeBufferPointer<Float>, n: Int, d: Int, count: Int, rng: inout SplitMix) -> [[Float]] {
        var mean = [Float](repeating: 0, count: d)
        for i in 0 ..< n { for c in 0 ..< d { mean[c] += x[i * d + c] } }
        mean = mean.map { $0 / Float(n) }
        func project(_ v: [Float]) -> [Float] {   // Xc v
            var xv = [Float](repeating: 0, count: n)
            #if canImport(Accelerate)
            vDSP_mmul(x.baseAddress!, 1, v, 1, &xv, 1, vDSP_Length(n), 1, vDSP_Length(d))
            #else
            for i in 0 ..< n { var s: Float = 0; for c in 0 ..< d { s += x[i * d + c] * v[c] }; xv[i] = s }
            #endif
            let mv = zip(mean, v).reduce(0) { $0 + $1.0 * $1.1 }
            return xv.map { $0 - mv }
        }
        func times(_ v: [Float]) -> [Float] {   // Xcᵀ(Xc v)
            let u = project(v)
            var out = [Float](repeating: 0, count: d)
            #if canImport(Accelerate)
            vDSP_mmul(u, 1, x.baseAddress!, 1, &out, 1, 1, vDSP_Length(d), vDSP_Length(n))
            #else
            for i in 0 ..< n { let s = u[i]; for c in 0 ..< d { out[c] += x[i * d + c] * s } }
            #endif
            let sum = u.reduce(0, +)
            return zip(out, mean).map { $0 - $1 * sum }
        }
        func normalised(_ v: [Float]) -> [Float] { let l = max(1e-20, v.reduce(0) { $0 + $1 * $1 }.squareRoot()); return v.map { $0 / l } }
        var components: [[Float]] = []
        for _ in 0 ..< count {
            var v = normalised((0 ..< d).map { _ in rng.normal(1) })
            for _ in 0 ..< 40 {
                var w = times(v)
                for p in components { let dot = zip(w, p).reduce(0) { $0 + $1.0 * $1.1 }; w = zip(w, p).map { $0 - dot * $1 } }
                v = normalised(w)
            }
            components.append(v)
        }
        return components.map(project)
    }

    /// Into 0…1 on the longer side, centred on the shorter.
    static func fit(_ y: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard let first = y.first else { return [] }
        let lo = y.reduce(first, pointwiseMin(_:_:)), hi = y.reduce(first, pointwiseMax(_:_:))
        let span = max(1e-12, max(hi.x - lo.x, hi.y - lo.y))
        let offset = (SIMD2<Float>(repeating: span) - (hi - lo)) / 2
        return y.map { ($0 - lo + offset) / span }
    }

    // MARK: helpers

    @inline(__always) static func distance2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let d = a - b
        return (d * d).sum()
    }

    /// Seeded random numbers (SplitMix64), so a map is the same every time.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// A normal deviate with this standard deviation (Box–Muller).
        mutating func normal(_ sd: Float) -> Float {
            let u1 = max(Float(next() >> 40) / Float(1 << 24), 1e-7), u2 = Float(next() >> 40) / Float(1 << 24)
            return sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }
}

/// Floats straight from the system's pages (mmap), handed back the moment the buffer goes. For
/// the sound map's buffers of tens to hundreds of MB: the allocator keeps freed large blocks to
/// use again, and on macOS 27 they stay counted as the app's memory (pressure relief doesn't
/// return them), so a map of the whole library left Earmark 1 GB bigger (2026-10-26).
/// Starts as zeros; pages never written cost nothing.
public final class PageBuffer: @unchecked Sendable {
    private let floats: UnsafeMutableBufferPointer<Float>
    private let mapped: Bool

    public var count: Int { floats.count }

    /// The floats, for as long as `body` runs (the buffer stays alive meanwhile).
    public func withFloats<R>(_ body: (UnsafeMutableBufferPointer<Float>) throws -> R) rethrows -> R {
        try body(floats)
    }

    public init(count: Int) {
        let bytes = count * MemoryLayout<Float>.stride
        if bytes > 0, let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
           p != UnsafeMutableRawPointer(bitPattern: -1) {
            floats = UnsafeMutableBufferPointer(start: p.bindMemory(to: Float.self, capacity: count), count: count)
            mapped = true
        } else {
            floats = .allocate(capacity: count)
            floats.initialize(repeating: 0)
            mapped = false
        }
    }

    deinit {
        if mapped { munmap(floats.baseAddress, floats.count * MemoryLayout<Float>.stride) } else { floats.deallocate() }
    }
}
