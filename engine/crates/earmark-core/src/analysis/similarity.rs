//! Nearest neighbours by cosine similarity over L2-normalised embeddings: one contiguous matrix,
//! a dot product against every row per query. Port of `SimilarityIndex.swift`.

use super::linalg::{Floats, mmul};
use std::collections::{HashMap, HashSet};

pub struct SimilarityIndex {
    pub ids: Vec<i64>,
    pub dimensions: usize,
    /// Where a Swift array keeps it, so Accelerate sums as in the app.
    matrix: Floats,
    row: HashMap<i64, usize>,
}

impl SimilarityIndex {
    /// `vectors`: (sound id, normalised vector); vectors of another length are skipped.
    pub fn new(vectors: &[(i64, Vec<f32>)]) -> SimilarityIndex {
        let dims = vectors.first().map_or(0, |v| v.1.len());
        let kept: Vec<&(i64, Vec<f32>)> = vectors
            .iter()
            .filter(|v| v.1.len() == dims && dims > 0)
            .collect();
        let mut row = HashMap::new();
        for (i, v) in kept.iter().enumerate() {
            row.entry(v.0).or_insert(i);
        }
        SimilarityIndex {
            ids: kept.iter().map(|v| v.0).collect(),
            dimensions: dims,
            matrix: {
                let mut m = Floats::array(kept.len() * dims);
                for (i, v) in kept.iter().enumerate() {
                    m[i * dims..(i + 1) * dims].copy_from_slice(&v.1);
                }
                m
            },
            row,
        }
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub fn contains(&self, id: i64) -> bool {
        self.row.contains_key(&id)
    }

    /// The `count` sounds most like `id` (best first, the sound itself left out), skipping
    /// `excluding`. Scores are cosine similarities, -1…1.
    pub fn nearest(&self, id: i64, count: usize, excluding: &HashSet<i64>) -> Vec<(i64, f32)> {
        let Some(&q) = self.row.get(&id) else {
            return Vec::new();
        };
        if count == 0 {
            return Vec::new();
        }
        let d = self.dimensions;
        // scores (rows × 1) = matrix (rows × d) · query (d × 1).
        let mut scores = vec![0f32; self.ids.len()];
        mmul(
            &self.matrix,
            &self.matrix[q * d..(q + 1) * d],
            &mut scores,
            self.ids.len(),
            1,
            d,
        );
        let mut best: Vec<(i64, f32)> = Vec::with_capacity(count + 1);
        for r in 0..self.ids.len() {
            if r == q {
                continue;
            }
            let s = scores[r];
            // Most rows can't make the list; check the exclusions only for those that can.
            if best.len() == count && s <= best[count - 1].1 {
                continue;
            }
            if excluding.contains(&self.ids[r]) {
                continue;
            }
            if best.len() < count {
                best.push((self.ids[r], s));
                if best.len() == count {
                    best.sort_by(|a, b| b.1.total_cmp(&a.1));
                }
            } else if s > best[count - 1].1 {
                // Insert in order, dropping the last.
                let mut i = count - 1;
                while i > 0 && best[i - 1].1 < s {
                    i -= 1;
                }
                best.insert(i, (self.ids[r], s));
                best.pop();
            }
        }
        if best.len() < count {
            best.sort_by(|a, b| b.1.total_cmp(&a.1));
        }
        best
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(v: &[f32]) -> Vec<f32> {
        let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        v.iter().map(|x| x / n).collect()
    }

    #[test]
    fn nearest_by_cosine_best_first() {
        let index = SimilarityIndex::new(&[
            (1, unit(&[1.0, 0.0, 0.0])),
            (2, unit(&[0.9, 0.1, 0.0])),
            (3, unit(&[0.0, 1.0, 0.0])),
            (4, unit(&[0.7, 0.7, 0.0])),
            (5, unit(&[-1.0, 0.0, 0.0])),
            (6, vec![1.0, 0.0]), // the wrong length: skipped
        ]);
        assert_eq!(index.len(), 5);
        let none = HashSet::new();
        let r = index.nearest(1, 3, &none);
        assert_eq!(r.iter().map(|x| x.0).collect::<Vec<_>>(), [2, 4, 3]);
        assert!(r[0].1 > r[1].1 && r[1].1 > r[2].1);
        assert_eq!(
            index
                .nearest(1, 3, &HashSet::from([2]))
                .iter()
                .map(|x| x.0)
                .collect::<Vec<_>>(),
            [4, 3, 5]
        );
        assert_eq!(index.nearest(1, 10, &none).len(), 4);
        assert!(index.nearest(99, 3, &none).is_empty());
    }
}
