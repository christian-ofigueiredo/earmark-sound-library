import Foundation

/// HDBSCAN (Campello, Moulavi & Sander), ported from scikit-learn 1.9 with the settings Phase 0's
/// `grouping.cluster` used: Euclidean distance, "excess of mass" selection, no single cluster,
/// no epsilon. Steps as sklearn's: core distances, the minimum spanning tree of the mutual
/// reachability graph (Prim's), single linkage, the condensed tree, stability, selection.
/// One difference: edges of equal weight are taken in the order the tree found them (sklearn's
/// sort leaves their order to NumPy), which can only matter where several merges tie.
public enum HDBSCAN {
    /// A label per point: 0, 1, … for the groups, −1 for points that fit none. `x`: `count` rows
    /// of `dimensions` values. `minSamples` counts the point itself (sklearn's meaning).
    public static func labels(_ x: [Float], count n: Int, dimensions d: Int, minClusterSize: Int, minSamples: Int) -> [Int] {
        guard n >= 2, d > 0, x.count >= n * d else { return Array(repeating: -1, count: n) }
        let points = x.prefix(n * d).map(Double.init)
        let core = coreDistances(points, n: n, d: d, k: min(max(1, minSamples), n))
        var edges = spanningTree(points, n: n, d: d, core: core)
        edges = edges.enumerated().sorted { ($0.element.distance, $0.offset) < ($1.element.distance, $1.offset) }.map(\.element)
        let tree = singleLinkage(edges, n: n)
        let condensed = condense(tree, n: n, minClusterSize: minClusterSize)
        guard !condensed.isEmpty else { return Array(repeating: -1, count: n) }
        return select(condensed, n: n)
    }

    struct Edge { var from: Int; var to: Int; var distance: Double }
    /// A merge in the single linkage tree: nodes below `n` are points, from `n` on merges.
    struct Merge { var left: Int; var right: Int; var distance: Double; var size: Int }
    /// A row of the condensed tree: a child (point or cluster) leaving its parent cluster at `lambda`.
    struct Condensed { var parent: Int; var child: Int; var lambda: Double; var size: Int }

    @inline(__always) static func distance(_ p: [Double], _ i: Int, _ j: Int, _ d: Int) -> Double {
        var s = 0.0
        for c in 0  ..< d { let t = p[i * d + c] - p[j * d + c]; s += t * t }
        return s.squareRoot()
    }

    /// Each point's distance to its k-th nearest, itself included (k = 1: 0).
    static func coreDistances(_ p: [Double], n: Int, d: Int, k: Int) -> [Double] {
        var core = [Double](repeating: 0, count: n)
        core.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { i in
                // The k smallest, ascending.
                var best = [Double](repeating: .infinity, count: k)
                for j in 0 ..< n {
                    let v = j == i ? 0 : distance(p, i, j, d)
                    guard v < best[k - 1] else { continue }
                    var at = k - 1
                    while at > 0, best[at - 1] > v { best[at] = best[at - 1]; at -= 1 }
                    best[at] = v
                }
                base[i] = best[k - 1]
            }
        }
        return core
    }

    /// sklearn's mst_from_data_matrix: Prim's over mutual reachability max(core i, core j, distance).
    static func spanningTree(_ p: [Double], n: Int, d: Int, core: [Double]) -> [Edge] {
        var inTree = [Bool](repeating: false, count: n)
        var minReach = [Double](repeating: .infinity, count: n)
        var sources = [Int](repeating: 1, count: n)
        var edges: [Edge] = []
        edges.reserveCapacity(n - 1)
        var current = 0
        for _ in 0 ..< n - 1 {
            inTree[current] = true
            let currentCore = core[current]
            var newReach = Double.greatestFiniteMagnitude, source = 0, newNode = 0
            for j in 0 ..< n where !inTree[j] {
                let nextMin = minReach[j], nextSource = sources[j]
                let mutual = max(currentCore, core[j], distance(p, current, j, d))
                if mutual < nextMin {
                    minReach[j] = mutual
                    sources[j] = current
                    if mutual < newReach { newReach = mutual; source = current; newNode = j }
                } else if nextMin < newReach {
                    newReach = nextMin; source = nextSource; newNode = j
                }
            }
            edges.append(Edge(from: source, to: newNode, distance: newReach))
            current = newNode
        }
        return edges
    }

    /// sklearn's make_single_linkage: the sorted edges merged with a union-find, new nodes from n.
    static func singleLinkage(_ edges: [Edge], n: Int) -> [Merge] {
        var parent = [Int](repeating: -1, count: 2 * n - 1)
        var size = [Int](repeating: 1, count: n) + [Int](repeating: 0, count: n - 1)
        var next = n
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != -1 { root = parent[root] }
            var y = x
            while y != root { let up = parent[y]; parent[y] = root; y = up }
            return root
        }
        var merges: [Merge] = []
        merges.reserveCapacity(n - 1)
        for e in edges {
            let a = find(e.from), b = find(e.to)
            merges.append(Merge(left: a, right: b, distance: e.distance, size: size[a] + size[b]))
            parent[a] = next; parent[b] = next
            size[next] = size[a] + size[b]
            next += 1
        }
        return merges
    }

    /// Nodes under `root` (itself first), breadth first, as sklearn's bfs_from_hierarchy.
    static func below(_ tree: [Merge], _ root: Int, n: Int) -> [Int] {
        var result: [Int] = [], queue = [root]
        while !queue.isEmpty {
            result += queue
            var next: [Int] = []
            for node in queue where node >= n { next += [tree[node - n].left, tree[node - n].right] }
            queue = next
        }
        return result
    }

    /// sklearn's _condense_tree: walking down, a split counts only when both sides have at least
    /// `minClusterSize` points; otherwise the small side's points fall out of the cluster.
    static func condense(_ tree: [Merge], n: Int, minClusterSize: Int) -> [Condensed] {
        let root = 2 * (n - 1)
        var nextLabel = n + 1
        var relabel = [Int](repeating: 0, count: root + 1)
        relabel[root] = n
        var ignore = [Bool](repeating: false, count: root + 1)
        var result: [Condensed] = []
        func count(_ node: Int) -> Int { node >= n ? tree[node - n].size : 1 }
        func fallOut(_ from: Int, into parent: Int, at lambda: Double) {
            for sub in below(tree, from, n: n) {
                if sub < n { result.append(Condensed(parent: parent, child: sub, lambda: lambda, size: 1)) }
                ignore[sub] = true
            }
        }
        for node in below(tree, root, n: n) where !ignore[node] && node >= n {
            let merge = tree[node - n]
            let lambda = merge.distance > 0 ? 1 / merge.distance : .infinity
            let left = merge.left, right = merge.right
            let leftCount = count(left), rightCount = count(right)
            if leftCount >= minClusterSize && rightCount >= minClusterSize {
                relabel[left] = nextLabel; nextLabel += 1
                result.append(Condensed(parent: relabel[node], child: relabel[left], lambda: lambda, size: leftCount))
                relabel[right] = nextLabel; nextLabel += 1
                result.append(Condensed(parent: relabel[node], child: relabel[right], lambda: lambda, size: rightCount))
            } else if leftCount < minClusterSize && rightCount < minClusterSize {
                fallOut(left, into: relabel[node], at: lambda)
                fallOut(right, into: relabel[node], at: lambda)
            } else if leftCount < minClusterSize {
                relabel[right] = relabel[node]
                fallOut(left, into: relabel[node], at: lambda)
            } else {
                relabel[left] = relabel[node]
                fallOut(right, into: relabel[node], at: lambda)
            }
        }
        return result
    }

    /// sklearn's _compute_stability then _get_clusters ("eom") and _do_labelling.
    static func select(_ condensed: [Condensed], n: Int) -> [Int] {
        let smallest = condensed.map(\.parent).min()!, largestParent = condensed.map(\.parent).max()!
        let largest = max(condensed.map(\.child).max()!, smallest)
        var births = [Double](repeating: .nan, count: largest + 1)
        for row in condensed { births[row.child] = row.lambda }
        births[smallest] = 0
        var stability = [Double](repeating: 0, count: largestParent - smallest + 1)
        for row in condensed { stability[row.parent - smallest] += (row.lambda - births[row.parent]) * Double(row.size) }

        // Clusters (rows whose child is a cluster) by parent.
        let clusterRows = condensed.filter { $0.size > 1 }
        var children: [Int: [Int]] = [:]
        for row in clusterRows { children[row.parent, default: []].append(row.child) }
        func stab(_ c: Int) -> Double { c - smallest < stability.count ? stability[c - smallest] : 0 }
        func setStab(_ c: Int, _ v: Double) { if c - smallest < stability.count { stability[c - smallest] = v } }
        // Every cluster but the root, children (higher labels) before their parents.
        let nodes = (smallest ... largestParent).reversed().dropLast()
        var isCluster = Dictionary(uniqueKeysWithValues: nodes.map { ($0, true) })
        for node in nodes {
            let sub = (children[node] ?? []).reduce(0) { $0 + stab($1) }
            if sub > stab(node) {
                isCluster[node] = false
                setStab(node, sub)
            } else {
                var queue = children[node] ?? []
                while !queue.isEmpty {
                    let c = queue.removeFirst()
                    isCluster[c] = false
                    queue += children[c] ?? []
                }
            }
        }
        let clusters = isCluster.filter(\.value).keys.sorted()
        let label = Dictionary(uniqueKeysWithValues: clusters.enumerated().map { ($0.element, $0.offset) })
        // A point's label: its nearest selected ancestor; none before the root is noise.
        var parentOf: [Int: Int] = [:]
        for row in condensed { parentOf[row.child] = row.parent }
        var result = [Int](repeating: -1, count: n)
        for point in 0 ..< n {
            var node = parentOf[point]
            while let c = node, c != smallest {
                if let l = label[c] { result[point] = l; break }
                node = parentOf[c]
            }
        }
        return result
    }
}
