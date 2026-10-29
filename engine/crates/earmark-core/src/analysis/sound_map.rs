//! A 2-D map of sounds where sounds that sound alike sit close: UMAP (McInnes et al.) as the Swift
//! app runs it (ported from umap-learn 0.5 with Phase 0's settings: cosine, 15 neighbours,
//! min_dist 0.15), starting from PCA, with seeded random numbers so the same sounds always give
//! the same map. Port of `SoundMap.swift`; on macOS the products go through Accelerate as there,
//! so the maps are the same to the bit.

use super::linalg::{mmul, transpose};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Settings {
    pub neighbours: usize,
    /// umap-learn's find_ab_params(spread 1, min_dist 0.15).
    pub a: f32,
    pub b: f32,
    pub negative_samples: usize,
    pub seed: u64,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            neighbours: 15,
            a: 1.413_999_9,
            b: 0.948_815_2,
            negative_samples: 5,
            seed: 42,
        }
    }
}

impl Settings {
    /// For grouping (Phase 0's `reduce_for_clustering`): min_dist 0, so alike sounds pack tight.
    pub fn clustering() -> Settings {
        Settings {
            a: 1.932_808_4,
            b: 0.790_495,
            ..Settings::default()
        }
    }

    /// umap-learn's default: 500 for small data, 200 from 10,000 points.
    fn epochs(&self, n: usize) -> usize {
        if n <= 10_000 { 500 } else { 200 }
    }
}

/// Phase 0's combination of models: each embedding L2-normalised, concatenated, scaled to unit
/// length.
pub fn combine(blocks: &[&[f32]]) -> Vec<f32> {
    let scale = 1.0 / (blocks.len() as f32).sqrt();
    blocks
        .iter()
        .flat_map(|v| {
            let norm = v.iter().fold(0f32, |s, x| s + x * x).sqrt().max(1e-12);
            v.iter().map(move |x| x / norm * scale)
        })
        .collect()
}

/// A layout and the lines to draw on it between sounds that are alike.
#[derive(Clone, Debug, PartialEq)]
pub struct Map {
    /// Positions in 0…1 (the longer side spans 0…1).
    pub points: Vec<[f32; 2]>,
    /// Each sound with its `links_per_sound` nearest in the embedding space, every pair once
    /// (lower index first), in order.
    pub links: Vec<[i32; 2]>,
}

/// The map of `n` unit-length rows of `d` floats, with links between neighbours (none under 20
/// sounds: no neighbour search). None if cancelled.
pub fn map(
    x: &[f32],
    n: usize,
    d: usize,
    settings: &Settings,
    links_per_sound: usize,
    progress: &dyn Fn(f64),
    is_cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Map> {
    if n <= 2 {
        let points = match n {
            0 => vec![],
            1 => vec![[0.5, 0.5]],
            _ => vec![[0.0, 0.5], [1.0, 0.5]],
        };
        return Some(Map {
            points,
            links: vec![],
        });
    }
    let mut rng = SplitMix::new(settings.seed);
    let p = principal(x, n, d, 2, &mut rng);
    let mut start: Vec<[f32; 2]> = (0..n).map(|i| [p[0][i], p[1][i]]).collect();
    // Too few points for a neighbourhood graph: PCA alone, as Phase 0.
    if n < 20 {
        return Some(Map {
            points: fit(&start),
            links: vec![],
        });
    }
    let k = settings.neighbours.min(n - 1);
    let (indices, distances) = neighbours(x, n, d, k, &|f| progress(f * 0.4), is_cancelled)?;
    let links = links(&indices, n, k, links_per_sound);
    let graph = fuzzy_graph(&indices, &distances, n, k);
    // umap-learn: PCA scaled so its largest coordinate is 10, a little noise, then into a 0…10 box.
    let extent = start
        .iter()
        .map(|q| q[0].abs().max(q[1].abs()))
        .reduce(f32::max)
        .unwrap_or(1.0)
        .max(1e-12);
    for q in &mut start {
        let (nx, ny) = (rng.normal(0.0001), rng.normal(0.0001));
        *q = [q[0] * (10.0 / extent) + nx, q[1] * (10.0 / extent) + ny];
    }
    let (mut lo, mut hi) = (start[0], start[0]);
    for q in &start {
        lo = [lo[0].min(q[0]), lo[1].min(q[1])];
        hi = [hi[0].max(q[0]), hi[1].max(q[1])];
    }
    let span = [(hi[0] - lo[0]).max(1e-12), (hi[1] - lo[1]).max(1e-12)];
    let mut y: Vec<f32> = start
        .iter()
        .flat_map(|q| {
            [
                10.0 * (q[0] - lo[0]) / span[0],
                10.0 * (q[1] - lo[1]) / span[1],
            ]
        })
        .collect();
    if !optimise(
        &mut y,
        2,
        &graph,
        n,
        settings,
        &mut rng,
        &|f| progress(0.4 + f * 0.6),
        is_cancelled,
    ) {
        return None;
    }
    let points: Vec<[f32; 2]> = y.as_chunks::<2>().0.iter().map(|c| [c[0], c[1]]).collect();
    Some(Map {
        points: fit(&points),
        links,
    })
}

/// The same layout in `m` dimensions instead of 2, flat (n × m), for grouping: Phase 0
/// clustered in 10. `x`: unit-length rows. None if cancelled.
pub fn reduce(
    x: &[f32],
    n: usize,
    d: usize,
    m: usize,
    settings: &Settings,
    is_cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Vec<f32>> {
    if n <= 2 || m == 0 {
        return Some(vec![0.0; n * m]);
    }
    let mut rng = SplitMix::new(settings.seed);
    let start = principal(x, n, d, m, &mut rng);
    if n < 20 {
        return Some(
            (0..n)
                .flat_map(|i| start.iter().map(move |c| c[i]))
                .collect(),
        );
    }
    let k = settings.neighbours.min(n - 1);
    let (indices, distances) = neighbours(x, n, d, k, &|_| {}, is_cancelled)?;
    let graph = fuzzy_graph(&indices, &distances, n, k);
    // As `map`: largest coordinate 10, a little noise, then each dimension into 0…10.
    let extent = start
        .iter()
        .map(|c| c.iter().map(|v| v.abs()).reduce(f32::max).unwrap_or(0.0))
        .reduce(f32::max)
        .unwrap_or(1.0)
        .max(1e-12);
    let mut y = vec![0f32; n * m];
    for i in 0..n {
        for c in 0..m {
            y[i * m + c] = start[c][i] * (10.0 / extent) + rng.normal(0.0001);
        }
    }
    for c in 0..m {
        let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
        for i in 0..n {
            lo = lo.min(y[i * m + c]);
            hi = hi.max(y[i * m + c]);
        }
        let span = (hi - lo).max(1e-12);
        for i in 0..n {
            y[i * m + c] = 10.0 * (y[i * m + c] - lo) / span;
        }
    }
    if !optimise(
        &mut y,
        m,
        &graph,
        n,
        settings,
        &mut rng,
        &|_| {},
        is_cancelled,
    ) {
        return None;
    }
    Some(y)
}

/// Each point with its `each` nearest (from the neighbour search, itself left out), every pair
/// once, sorted.
fn links(indices: &[usize], n: usize, k: usize, each: usize) -> Vec<[i32; 2]> {
    let mut pairs = std::collections::BTreeSet::new();
    for i in 0..n {
        for c in 0..k.min(each + 1) {
            let j = indices[i * k + c];
            if j != i {
                pairs.insert(i.min(j) as i64 * n as i64 + i.max(j) as i64);
            }
        }
    }
    pairs
        .into_iter()
        .map(|p| [(p / n as i64) as i32, (p % n as i64) as i32])
        .collect()
}

/// Each point's `k` nearest by cosine distance (1 − dot), itself first: flat n × k indices and
/// distances. Blocks of 64 rows in parallel; each row is worked out on its own, so the result
/// doesn't depend on the threads.
pub fn neighbours(
    x: &[f32],
    n: usize,
    d: usize,
    k: usize,
    progress: &dyn Fn(f64),
    is_cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<(Vec<usize>, Vec<f32>)> {
    const BLOCK: usize = 64;
    const BATCH: usize = 32; // blocks between checks for cancellation
    let blocks = n.div_ceil(BLOCK);
    let mut indices = vec![0usize; n * k];
    let mut distances = vec![0f32; n * k];
    let threads = std::thread::available_parallelism().map_or(4, |t| t.get());
    for batch_start in (0..blocks).step_by(BATCH) {
        if is_cancelled() {
            return None;
        }
        progress(batch_start as f64 / blocks as f64);
        let batch_end = blocks.min(batch_start + BATCH);
        let rows_from = batch_start * BLOCK;
        let rows_to = n.min(batch_end * BLOCK);
        let idx = &mut indices[rows_from * k..rows_to * k];
        let dst = &mut distances[rows_from * k..rows_to * k];
        // Hand each thread whole blocks.
        let mut work: Vec<(usize, &mut [usize], &mut [f32])> = idx
            .chunks_mut(BLOCK * k)
            .zip(dst.chunks_mut(BLOCK * k))
            .enumerate()
            .map(|(b, (i, d))| (batch_start + b, i, d))
            .collect();
        let per = work.len().div_ceil(threads);
        std::thread::scope(|s| {
            while !work.is_empty() {
                let take = per.min(work.len());
                let chunk: Vec<_> = work.drain(..take).collect();
                s.spawn(move || {
                    for (block, idx, dst) in chunk {
                        nearest_in_block(x, n, d, k, block * BLOCK, idx, dst);
                    }
                });
            }
        });
    }
    progress(1.0);
    Some((indices, distances))
}

fn nearest_in_block(
    x: &[f32],
    n: usize,
    d: usize,
    k: usize,
    first: usize,
    idx: &mut [usize],
    dst: &mut [f32],
) {
    let m = BLOCK_ROWS.min(n - first);
    // scores[j * m + r] = x[j] · x[first + r]: all rows (n × d) · the block transposed (d × m).
    let mut block_t = vec![0f32; d * m];
    transpose(&x[first * d..(first + m) * d], &mut block_t, m, d);
    let mut scores = vec![0f32; n * m];
    mmul(x, &block_t, &mut scores, n, m, d);
    // Each row's best so far, best first; equal scores keep the earlier point first.
    let mut best_index = vec![0usize; m * k];
    let mut best_score = vec![0f32; m * k];
    let mut found = vec![0usize; m];
    for j in 0..n {
        for r in 0..m {
            // Itself first, at distance 0, as umap-learn's search returns it.
            let s = if j == first + r {
                f32::INFINITY
            } else {
                scores[j * m + r]
            };
            let (base, count) = (r * k, found[r]);
            if count == k && s <= best_score[base + k - 1] {
                continue;
            }
            let mut p = count.min(k - 1);
            while p > 0 && best_score[base + p - 1] < s {
                best_score[base + p] = best_score[base + p - 1];
                best_index[base + p] = best_index[base + p - 1];
                p -= 1;
            }
            best_score[base + p] = s;
            best_index[base + p] = j;
            if count < k {
                found[r] = count + 1;
            }
        }
    }
    for r in 0..m {
        let i = first + r;
        for c in 0..k {
            let j = best_index[r * k + c];
            idx[r * k + c] = j;
            dst[r * k + c] = if j == i {
                0.0
            } else {
                (1.0 - best_score[r * k + c]).max(0.0)
            };
        }
    }
}

const BLOCK_ROWS: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Edge {
    pub head: i32,
    pub tail: i32,
    pub weight: f32,
}

/// umap-learn's fuzzy_simplicial_set (local connectivity 1, set_op_mix_ratio 1): each point's
/// neighbour memberships, then their fuzzy union A + Aᵀ − A∘Aᵀ, as directed edges.
pub fn fuzzy_graph(indices: &[usize], distances: &[f32], n: usize, k: usize) -> Vec<Edge> {
    let target = (k as f32).log2();
    let mean_all = distances.iter().fold(0f32, |s, v| s + v) / distances.len() as f32;
    // weights[i * k + c]: how much indices[i * k + c] belongs to i's neighbourhood (0 for i).
    let mut weights = vec![0f32; n * k];
    for i in 0..n {
        let row = &distances[i * k..(i + 1) * k];
        let rho = row.iter().copied().find(|&v| v > 0.0).unwrap_or(0.0);
        // sigma: Σ exp(−max(0, d − rho)/sigma) over the neighbours (not itself) = log2(k).
        let (mut lo, mut hi, mut mid) = (0f32, f32::INFINITY, 1f32);
        for _ in 0..64 {
            let mut sum = 0f32;
            for &v in &row[1..k] {
                let x = v - rho;
                sum += if x > 0.0 { (-x / mid).exp() } else { 1.0 };
            }
            if (sum - target).abs() < 1e-5 {
                break;
            }
            if sum > target {
                hi = mid;
                mid = (lo + hi) / 2.0;
            } else {
                lo = mid;
                mid = if hi == f32::INFINITY {
                    mid * 2.0
                } else {
                    (lo + hi) / 2.0
                };
            }
        }
        let mean_row = row.iter().fold(0f32, |s, v| s + v) / k as f32;
        let sigma = if rho > 0.0 {
            mid.max(1e-3 * mean_row)
        } else {
            mid.max(1e-3 * mean_all)
        };
        for c in 0..k {
            if indices[i * k + c] != i {
                let x = row[c] - rho;
                weights[i * k + c] = if x <= 0.0 || sigma == 0.0 {
                    1.0
                } else {
                    (-x / sigma).exp()
                };
            }
        }
    }
    // How much j belongs to i's neighbourhood; None if it isn't among i's neighbours.
    let weight = |i: usize, j: usize| -> Option<f32> {
        (0..k)
            .find(|&c| indices[i * k + c] == j && j != i)
            .map(|c| weights[i * k + c])
    };
    // In the neighbours' order (the map depends on the edges' order).
    let mut edges = Vec::with_capacity(n * k * 3 / 2);
    for i in 0..n {
        for c in 0..k {
            let j = indices[i * k + c];
            if j != i {
                let (w, back) = (weights[i * k + c], weight(j, i).unwrap_or(0.0));
                edges.push(Edge {
                    head: i as i32,
                    tail: j as i32,
                    weight: w + back - w * back,
                });
            }
        }
    }
    // The other direction of one-way neighbourhoods (i has j, j doesn't have i).
    for i in 0..n {
        for c in 0..k {
            let j = indices[i * k + c];
            if j != i && weight(j, i).is_none() {
                edges.push(Edge {
                    head: j as i32,
                    tail: i as i32,
                    weight: weights[i * k + c],
                });
            }
        }
    }
    edges
}

fn clip(v: f32) -> f32 {
    v.clamp(-4.0, 4.0)
}

/// umap-learn's optimize_layout_euclidean, in `m` dimensions (`y`: n × m, flat): attraction
/// along the graph's edges, repulsion from random points, the learning rate falling to 0.
/// False if cancelled. In 2-D the arithmetic is the Swift app's 2-D version's, step for step.
#[allow(clippy::too_many_arguments)]
fn optimise(
    y: &mut [f32],
    m: usize,
    graph: &[Edge],
    n: usize,
    settings: &Settings,
    rng: &mut SplitMix,
    progress: &dyn Fn(f64),
    is_cancelled: &dyn Fn() -> bool,
) -> bool {
    let epochs = settings.epochs(n);
    let max_weight = graph
        .iter()
        .map(|e| e.weight)
        .reduce(f32::max)
        .unwrap_or(1.0);
    // Edges too weak to be sampled even once are dropped, as umap-learn does.
    let edges: Vec<Edge> = graph
        .iter()
        .copied()
        .filter(|e| e.weight >= max_weight / epochs as f32)
        .collect();
    let per_sample: Vec<f32> = edges
        .iter()
        .map(|e| epochs as f32 / (epochs as f32 * e.weight / max_weight))
        .collect();
    let neg_rate = settings.negative_samples as f32;
    let per_negative: Vec<f32> = per_sample.iter().map(|p| p / neg_rate).collect();
    let (mut next_sample, mut next_negative) = (per_sample.clone(), per_negative.clone());
    let (a, b) = (settings.a, settings.b);
    let mut current = vec![0f32; m];
    let distance2 = |p: &[f32], y: &[f32], o: usize| -> f32 {
        if m == 2 {
            // SIMD2's ((p − o) * (p − o)).sum().
            let (dx, dy) = (p[0] - y[o * 2], p[1] - y[o * 2 + 1]);
            dx * dx + dy * dy
        } else {
            let mut s = 0f32;
            for c in 0..m {
                let t = p[c] - y[o * m + c];
                s += t * t;
            }
            s
        }
    };
    for epoch in 0..epochs {
        let alpha = 1.0 - epoch as f32 / epochs as f32;
        let e = epoch as f32;
        for i in 0..edges.len() {
            if next_sample[i] > e {
                continue;
            }
            let (j, t) = (edges[i].head as usize, edges[i].tail as usize);
            current.copy_from_slice(&y[j * m..(j + 1) * m]);
            let dist2 = distance2(&current, y, t);
            if dist2 > 0.0 {
                let coeff = -2.0 * a * b * dist2.powf(b - 1.0) / (a * dist2.powf(b) + 1.0);
                for c in 0..m {
                    let grad = clip(coeff * (current[c] - y[t * m + c]));
                    if m == 2 {
                        // The 2-D version moves both by grad × alpha.
                        current[c] += grad * alpha;
                        y[t * m + c] -= grad * alpha;
                    } else {
                        let g = grad * alpha;
                        current[c] += g;
                        y[t * m + c] -= g;
                    }
                }
            }
            next_sample[i] += per_sample[i];
            let negatives = (((e - next_negative[i]) / per_negative[i]) as i64).max(0);
            for _ in 0..negatives {
                let r = (rng.next() % n as u64) as usize;
                if r == j {
                    continue;
                }
                let d2 = distance2(&current, y, r);
                if m == 2 {
                    let mut grad = [4f32, 4f32];
                    if d2 > 0.0 {
                        let coeff = 2.0 * b / ((0.001 + d2) * (a * d2.powf(b) + 1.0));
                        grad = [
                            clip(coeff * (current[0] - y[r * 2])),
                            clip(coeff * (current[1] - y[r * 2 + 1])),
                        ];
                    }
                    current[0] += grad[0] * alpha;
                    current[1] += grad[1] * alpha;
                } else {
                    let coeff = if d2 > 0.0 {
                        2.0 * b / ((0.001 + d2) * (a * d2.powf(b) + 1.0))
                    } else {
                        0.0
                    };
                    for c in 0..m {
                        current[c] += (if d2 > 0.0 {
                            clip(coeff * (current[c] - y[r * m + c]))
                        } else {
                            4.0
                        }) * alpha;
                    }
                }
            }
            y[j * m..(j + 1) * m].copy_from_slice(&current);
            next_negative[i] += negatives as f32 * per_negative[i];
        }
        if epoch % 10 == 0 {
            progress(epoch as f64 / epochs as f64);
            if is_cancelled() {
                return false;
            }
        }
    }
    progress(1.0);
    true
}

/// The first `count` principal components' coordinates, one array per component (power
/// iteration on the centred XᵀX, centred arithmetically: Xc v = X v − (m·v),
/// Xcᵀ u = Xᵀ u − m Σu).
pub fn principal(x: &[f32], n: usize, d: usize, count: usize, rng: &mut SplitMix) -> Vec<Vec<f32>> {
    let mut mean = vec![0f32; d];
    for i in 0..n {
        for c in 0..d {
            mean[c] += x[i * d + c];
        }
    }
    for v in &mut mean {
        *v /= n as f32;
    }
    let project = |v: &[f32]| -> Vec<f32> {
        let mut xv = vec![0f32; n];
        mmul(x, v, &mut xv, n, 1, d);
        let mv = mean.iter().zip(v).fold(0f32, |s, (a, b)| s + a * b);
        xv.iter().map(|x| x - mv).collect()
    };
    let times = |v: &[f32]| -> Vec<f32> {
        let u = project(v);
        let mut out = vec![0f32; d];
        mmul(&u, x, &mut out, 1, d, n);
        let sum = u.iter().fold(0f32, |s, v| s + v);
        out.iter().zip(&mean).map(|(o, m)| o - m * sum).collect()
    };
    let normalised = |v: &[f32]| -> Vec<f32> {
        let l = v.iter().fold(0f32, |s, x| s + x * x).sqrt().max(1e-20);
        v.iter().map(|x| x / l).collect()
    };
    let mut components: Vec<Vec<f32>> = Vec::new();
    for _ in 0..count {
        let start: Vec<f32> = (0..d).map(|_| rng.normal(1.0)).collect();
        let mut v = normalised(&start);
        for _ in 0..40 {
            let mut w = times(&v);
            for p in &components {
                let dot = w.iter().zip(p).fold(0f32, |s, (a, b)| s + a * b);
                w = w.iter().zip(p).map(|(a, b)| a - dot * b).collect();
            }
            v = normalised(&w);
        }
        components.push(v);
    }
    components.iter().map(|c| project(c)).collect()
}

/// Into 0…1 on the longer side, centred on the shorter.
pub fn fit(y: &[[f32; 2]]) -> Vec<[f32; 2]> {
    let Some(&first) = y.first() else {
        return vec![];
    };
    let (mut lo, mut hi) = (first, first);
    for q in y {
        lo = [lo[0].min(q[0]), lo[1].min(q[1])];
        hi = [hi[0].max(q[0]), hi[1].max(q[1])];
    }
    let span = (hi[0] - lo[0]).max(hi[1] - lo[1]).max(1e-12);
    let offset = [
        (span - (hi[0] - lo[0])) / 2.0,
        (span - (hi[1] - lo[1])) / 2.0,
    ];
    y.iter()
        .map(|q| {
            [
                (q[0] - lo[0] + offset[0]) / span,
                (q[1] - lo[1] + offset[1]) / span,
            ]
        })
        .collect()
}

/// Swift's `Float.pi`: π rounded toward zero (3.1415925), not to the nearest float like
/// `std::f32::consts::PI` (3.1415927). With the nearest, 2 of 3 normals came out a bit apart from
/// Swift's, and the maps with them.
const SWIFT_FLOAT_PI: f32 = f32::from_bits(0x4049_0FDA);

/// Seeded random numbers (SplitMix64), so a map is the same every time.
pub struct SplitMix {
    state: u64,
}

impl SplitMix {
    pub fn new(seed: u64) -> SplitMix {
        SplitMix { state: seed }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A normal deviate with this standard deviation (Box–Muller).
    pub fn normal(&mut self, sd: f32) -> f32 {
        let u1 = ((self.next() >> 40) as f32 / (1u32 << 24) as f32).max(1e-7);
        let u2 = (self.next() >> 40) as f32 / (1u32 << 24) as f32;
        sd * (-2.0 * u1.ln()).sqrt() * (2.0 * SWIFT_FLOAT_PI * u2).cos()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitmix_is_the_reference_sequence() {
        // SplitMix64's published first outputs for seed 0.
        let mut r = SplitMix::new(0);
        assert_eq!(r.next(), 0xE220_A839_7B1D_CDAF);
        assert_eq!(r.next(), 0x6E78_9E6A_A1B9_65F4);
    }

    // Swift's values as it prints them, more digits than an f32 keeps.
    #[test]
    #[allow(clippy::excessive_precision)]
    fn normals_as_swift_makes_them() {
        // Swift's first normals for seed 42 (SoundMap.SplitMix.normal(1)).
        let mut r = SplitMix::new(42);
        let got: Vec<f32> = (0..8).map(|_| r.normal(1.0)).collect();
        assert_eq!(
            got,
            [
                0.41471979,
                -0.89188564,
                1.7295922,
                0.54561979,
                -1.0804135,
                -1.7788482,
                -1.1456186,
                0.26045081
            ]
        );
    }

    #[test]
    fn small_maps_and_a_real_layout() {
        let none = || false;
        assert_eq!(
            map(&[], 0, 3, &Settings::default(), 3, &|_| {}, &none)
                .unwrap()
                .points,
            Vec::<[f32; 2]>::new()
        );
        // Two clusters of 30 points in 8 dimensions end up apart on the map.
        let mut rng = SplitMix::new(7);
        let mut x = Vec::new();
        for i in 0..60 {
            let mut v: Vec<f32> = (0..8).map(|_| rng.normal(0.05)).collect();
            v[if i < 30 { 0 } else { 1 }] += 1.0;
            let l = v.iter().map(|a| a * a).sum::<f32>().sqrt();
            x.extend(v.iter().map(|a| a / l));
        }
        let m = map(&x, 60, 8, &Settings::default(), 3, &|_| {}, &none).unwrap();
        assert_eq!(m.points.len(), 60);
        assert!(
            m.points
                .iter()
                .all(|p| (0.0..=1.0).contains(&p[0]) && (0.0..=1.0).contains(&p[1]))
        );
        let centre = |r: std::ops::Range<usize>| {
            let s = r.clone().fold([0f32, 0f32], |a, i| {
                [a[0] + m.points[i][0], a[1] + m.points[i][1]]
            });
            [s[0] / r.len() as f32, s[1] / r.len() as f32]
        };
        let (a, b) = (centre(0..30), centre(30..60));
        assert!(((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2)).sqrt() > 0.3);
        assert!(m.links.iter().all(|l| l[0] < l[1]));
        // The same input gives the same map.
        assert_eq!(
            map(&x, 60, 8, &Settings::default(), 3, &|_| {}, &none).unwrap(),
            m
        );
    }
}
