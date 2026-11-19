//! HDBSCAN (Campello, Moulavi & Sander), ported (via the Swift app's `HDBSCAN.swift`) from
//! scikit-learn 1.9 with the settings Phase 0's `grouping.cluster` used: Euclidean distance,
//! "excess of mass" selection, no single cluster, no epsilon. Edges of equal weight are taken in
//! the order the tree found them.

use std::collections::{BTreeMap, HashMap};

/// A label per point: 0, 1, … for the groups, −1 for points that fit none. `x`: `n` rows of `d`
/// values. `min_samples` counts the point itself (sklearn's meaning).
pub fn labels(
    x: &[f32],
    n: usize,
    d: usize,
    min_cluster_size: usize,
    min_samples: usize,
) -> Vec<i64> {
    if n < 2 || d == 0 || x.len() < n * d {
        return vec![-1; n];
    }
    let points: Vec<f64> = x[..n * d].iter().map(|&v| v as f64).collect();
    let core = core_distances(&points, n, d, min_samples.max(1).min(n));
    let mut edges: Vec<(usize, Edge)> = spanning_tree(&points, n, d, &core)
        .into_iter()
        .enumerate()
        .collect();
    edges.sort_by(|a, b| a.1.distance.total_cmp(&b.1.distance).then(a.0.cmp(&b.0)));
    let tree = single_linkage(&edges.into_iter().map(|e| e.1).collect::<Vec<_>>(), n);
    let condensed = condense(&tree, n, min_cluster_size);
    if condensed.is_empty() {
        return vec![-1; n];
    }
    select(&condensed, n)
}

#[derive(Clone, Copy)]
struct Edge {
    from: usize,
    to: usize,
    distance: f64,
}

/// A merge in the single linkage tree: nodes below `n` are points, from `n` on merges.
#[derive(Clone, Copy)]
struct Merge {
    left: usize,
    right: usize,
    distance: f64,
    size: usize,
}

/// A row of the condensed tree: a child (point or cluster) leaving its parent at `lambda`.
#[derive(Clone, Copy)]
struct Condensed {
    parent: usize,
    child: usize,
    lambda: f64,
    size: usize,
}

fn distance(p: &[f64], i: usize, j: usize, d: usize) -> f64 {
    let mut s = 0.0;
    for c in 0..d {
        let t = p[i * d + c] - p[j * d + c];
        s += t * t;
    }
    s.sqrt()
}

/// Each point's distance to its k-th nearest, itself included (k = 1: 0).
fn core_distances(p: &[f64], n: usize, d: usize, k: usize) -> Vec<f64> {
    let mut core = vec![0.0; n];
    let threads = std::thread::available_parallelism().map_or(4, |t| t.get());
    let per = n.div_ceil(threads);
    std::thread::scope(|s| {
        for (t, out) in core.chunks_mut(per).enumerate() {
            s.spawn(move || {
                for (r, slot) in out.iter_mut().enumerate() {
                    let i = t * per + r;
                    // The k smallest, ascending.
                    let mut best = vec![f64::INFINITY; k];
                    for j in 0..n {
                        let v = if j == i { 0.0 } else { distance(p, i, j, d) };
                        if v >= best[k - 1] {
                            continue;
                        }
                        let mut at = k - 1;
                        while at > 0 && best[at - 1] > v {
                            best[at] = best[at - 1];
                            at -= 1;
                        }
                        best[at] = v;
                    }
                    *slot = best[k - 1];
                }
            });
        }
    });
    core
}

/// sklearn's mst_from_data_matrix: Prim's over mutual reachability max(core i, core j, distance).
fn spanning_tree(p: &[f64], n: usize, d: usize, core: &[f64]) -> Vec<Edge> {
    let mut in_tree = vec![false; n];
    let mut min_reach = vec![f64::INFINITY; n];
    let mut sources = vec![1usize; n];
    let mut edges = Vec::with_capacity(n - 1);
    let mut current = 0;
    for _ in 0..n - 1 {
        in_tree[current] = true;
        let current_core = core[current];
        let (mut new_reach, mut source, mut new_node) = (f64::MAX, 0, 0);
        for j in 0..n {
            if in_tree[j] {
                continue;
            }
            let (next_min, next_source) = (min_reach[j], sources[j]);
            let mutual = current_core.max(core[j]).max(distance(p, current, j, d));
            if mutual < next_min {
                min_reach[j] = mutual;
                sources[j] = current;
                if mutual < new_reach {
                    new_reach = mutual;
                    source = current;
                    new_node = j;
                }
            } else if next_min < new_reach {
                new_reach = next_min;
                source = next_source;
                new_node = j;
            }
        }
        edges.push(Edge {
            from: source,
            to: new_node,
            distance: new_reach,
        });
        current = new_node;
    }
    edges
}

/// sklearn's make_single_linkage: the sorted edges merged with a union-find, new nodes from n.
fn single_linkage(edges: &[Edge], n: usize) -> Vec<Merge> {
    let mut parent = vec![usize::MAX; 2 * n - 1];
    let mut size = vec![1usize; n];
    size.resize(2 * n - 1, 0);
    let find = |parent: &mut Vec<usize>, x: usize| {
        let mut root = x;
        while parent[root] != usize::MAX {
            root = parent[root];
        }
        let mut y = x;
        while y != root {
            let up = parent[y];
            parent[y] = root;
            y = up;
        }
        root
    };
    let mut next = n;
    let mut merges = Vec::with_capacity(n - 1);
    for e in edges {
        let (a, b) = (find(&mut parent, e.from), find(&mut parent, e.to));
        merges.push(Merge {
            left: a,
            right: b,
            distance: e.distance,
            size: size[a] + size[b],
        });
        parent[a] = next;
        parent[b] = next;
        size[next] = size[a] + size[b];
        next += 1;
    }
    merges
}

/// Nodes under `root` (itself first), breadth first, as sklearn's bfs_from_hierarchy.
fn below(tree: &[Merge], root: usize, n: usize) -> Vec<usize> {
    let (mut result, mut queue) = (Vec::new(), vec![root]);
    while !queue.is_empty() {
        result.extend_from_slice(&queue);
        let mut next = Vec::new();
        for &node in &queue {
            if node >= n {
                next.push(tree[node - n].left);
                next.push(tree[node - n].right);
            }
        }
        queue = next;
    }
    result
}

/// sklearn's _condense_tree: walking down, a split counts only when both sides have at least
/// `min_cluster_size` points; otherwise the small side's points fall out of the cluster.
fn condense(tree: &[Merge], n: usize, min_cluster_size: usize) -> Vec<Condensed> {
    let root = 2 * (n - 1);
    let mut next_label = n + 1;
    let mut relabel = vec![0usize; root + 1];
    relabel[root] = n;
    let mut ignore = vec![false; root + 1];
    let mut result = Vec::new();
    let count = |node: usize| if node >= n { tree[node - n].size } else { 1 };
    let fall_out = |from: usize,
                    parent: usize,
                    lambda: f64,
                    ignore: &mut Vec<bool>,
                    result: &mut Vec<Condensed>| {
        for sub in below(tree, from, n) {
            if sub < n {
                result.push(Condensed {
                    parent,
                    child: sub,
                    lambda,
                    size: 1,
                });
            }
            ignore[sub] = true;
        }
    };
    for node in below(tree, root, n) {
        if ignore[node] || node < n {
            continue;
        }
        let merge = tree[node - n];
        let lambda = if merge.distance > 0.0 {
            1.0 / merge.distance
        } else {
            f64::INFINITY
        };
        let (left, right) = (merge.left, merge.right);
        let (lc, rc) = (count(left), count(right));
        if lc >= min_cluster_size && rc >= min_cluster_size {
            relabel[left] = next_label;
            next_label += 1;
            result.push(Condensed {
                parent: relabel[node],
                child: relabel[left],
                lambda,
                size: lc,
            });
            relabel[right] = next_label;
            next_label += 1;
            result.push(Condensed {
                parent: relabel[node],
                child: relabel[right],
                lambda,
                size: rc,
            });
        } else if lc < min_cluster_size && rc < min_cluster_size {
            fall_out(left, relabel[node], lambda, &mut ignore, &mut result);
            fall_out(right, relabel[node], lambda, &mut ignore, &mut result);
        } else if lc < min_cluster_size {
            relabel[right] = relabel[node];
            fall_out(left, relabel[node], lambda, &mut ignore, &mut result);
        } else {
            relabel[left] = relabel[node];
            fall_out(right, relabel[node], lambda, &mut ignore, &mut result);
        }
    }
    result
}

/// sklearn's _compute_stability then _get_clusters ("eom") and _do_labelling.
fn select(condensed: &[Condensed], n: usize) -> Vec<i64> {
    let smallest = condensed.iter().map(|r| r.parent).min().unwrap();
    let largest_parent = condensed.iter().map(|r| r.parent).max().unwrap();
    let largest = condensed
        .iter()
        .map(|r| r.child)
        .max()
        .unwrap()
        .max(smallest);
    let mut births = vec![f64::NAN; largest + 1];
    for r in condensed {
        births[r.child] = r.lambda;
    }
    births[smallest] = 0.0;
    let mut stability = vec![0.0; largest_parent - smallest + 1];
    for r in condensed {
        stability[r.parent - smallest] += (r.lambda - births[r.parent]) * r.size as f64;
    }
    // Clusters (rows whose child is a cluster) by parent.
    let mut children: HashMap<usize, Vec<usize>> = HashMap::new();
    for r in condensed.iter().filter(|r| r.size > 1) {
        children.entry(r.parent).or_default().push(r.child);
    }
    let stab = |s: &Vec<f64>, c: usize| {
        if c - smallest < s.len() {
            s[c - smallest]
        } else {
            0.0
        }
    };
    // Every cluster but the root, children (higher labels) before their parents.
    let nodes: Vec<usize> = (smallest + 1..=largest_parent).rev().collect();
    let mut is_cluster: BTreeMap<usize, bool> = nodes.iter().map(|&c| (c, true)).collect();
    for &node in &nodes {
        let sub: f64 = children
            .get(&node)
            .map_or(0.0, |c| c.iter().fold(0.0, |s, &x| s + stab(&stability, x)));
        if sub > stab(&stability, node) {
            is_cluster.insert(node, false);
            if node - smallest < stability.len() {
                stability[node - smallest] = sub;
            }
        } else {
            let mut queue: std::collections::VecDeque<usize> =
                children.get(&node).cloned().unwrap_or_default().into();
            while let Some(c) = queue.pop_front() {
                is_cluster.insert(c, false);
                queue.extend(children.get(&c).cloned().unwrap_or_default());
            }
        }
    }
    let label: HashMap<usize, i64> = is_cluster
        .iter()
        .filter(|(_, v)| **v)
        .map(|(&c, _)| c)
        .enumerate()
        .map(|(i, c)| (c, i as i64))
        .collect();
    // A point's label: its nearest selected ancestor; none before the root is noise.
    let mut parent_of: HashMap<usize, usize> = HashMap::new();
    for r in condensed {
        parent_of.insert(r.child, r.parent);
    }
    let mut result = vec![-1; n];
    for (point, slot) in result.iter_mut().enumerate() {
        let mut node = parent_of.get(&point).copied();
        while let Some(c) = node {
            if c == smallest {
                break;
            }
            if let Some(&l) = label.get(&c) {
                *slot = l;
                break;
            }
            node = parent_of.get(&c).copied();
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::labels;
    use serde::Deserialize;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Case {
        dimensions: usize,
        min_cluster_size: usize,
        min_samples: usize,
        points: Vec<f64>,
        labels: Vec<i64>,
    }
    #[derive(Deserialize)]
    struct Fixture {
        cases: Vec<Case>,
    }

    /// Synthetic blobs and noise, labelled by sklearn 1.9 (models/export_groups.py).
    #[test]
    fn matches_scikit_learn() {
        let f: Fixture = serde_json::from_str(include_str!(
            "../../../../../app/Tests/EarmarkCoreTests/Fixtures/hdbscan.json"
        ))
        .unwrap();
        for c in f.cases {
            let x: Vec<f32> = c.points.iter().map(|&v| v as f32).collect();
            let got = labels(
                &x,
                c.labels.len(),
                c.dimensions,
                c.min_cluster_size,
                c.min_samples,
            );
            assert_eq!(got, c.labels);
        }
    }

    #[test]
    fn too_few_points() {
        assert_eq!(labels(&[0.0, 0.0, 1.0, 1.0], 2, 2, 5, 2), [-1, -1]);
        assert_eq!(labels(&[], 0, 2, 5, 2), Vec::<i64>::new());
    }
}
