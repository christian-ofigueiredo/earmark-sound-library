//! Sounds that are the same: byte-identical copies (the same fingerprint, anywhere), and the same
//! recording in another file, found by its audio. Format twins aren't counted. Earmark only shows
//! them; it never deletes or moves files. Port of `Duplicates.swift`.

use std::collections::{BTreeMap, HashMap, HashSet};

/// The cosine (PE-AV + CLAP) from which two sounds of the same length are one recording (see
/// the Swift file for how it was chosen on the owner's library).
pub const SIMILARITY: f32 = 0.998;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pair {
    pub a: i64,
    pub b: i64,
    /// Byte-identical files (the same fingerprint), else the same recording by its audio.
    pub identical: bool,
    pub similarity: f32,
}

impl Pair {
    pub fn new(a: i64, b: i64, identical: bool, similarity: f32) -> Pair {
        Pair {
            a: a.min(b),
            b: a.max(b),
            identical,
            similarity,
        }
    }
}

/// Lengths that count as the same: within 1%, or 0.02 s for short sounds.
pub fn same_length(x: Option<f64>, y: Option<f64>) -> bool {
    match (x, y) {
        (Some(x), Some(y)) => (x - y).abs() <= 0.02f64.max(0.01 * x.max(y)),
        _ => false,
    }
}

/// Byte-identical copies: sounds (id, fingerprint) sharing a fingerprint, hidden format twins
/// left out. Pairs come per fingerprint in the order the sounds were given.
pub fn identical_pairs(sounds: &[(i64, Option<String>)], hidden: &HashSet<i64>) -> Vec<Pair> {
    let mut order: Vec<&str> = Vec::new();
    let mut by_print: HashMap<&str, Vec<i64>> = HashMap::new();
    for (id, fp) in sounds {
        let Some(fp) = fp.as_deref() else { continue };
        if hidden.contains(id) {
            continue;
        }
        let ids = by_print.entry(fp).or_default();
        if ids.is_empty() {
            order.push(fp);
        }
        ids.push(*id);
    }
    let mut out = Vec::new();
    for fp in order {
        let ids = &by_print[fp];
        for i in 0..ids.len() {
            for j in i + 1..ids.len() {
                out.push(Pair::new(ids[i], ids[j], true, 1.0));
            }
        }
    }
    out
}

/// The same recording, from a neighbour search over `ids` (n × k indices and cosine distances,
/// each row's nearest first): pairs at `SIMILARITY` or more with the same length.
pub fn near_pairs(
    ids: &[i64],
    durations: &[Option<f64>],
    indices: &[usize],
    distances: &[f32],
    k: usize,
) -> Vec<Pair> {
    let n = ids.len();
    let (mut seen, mut out) = (HashSet::new(), Vec::new());
    for i in 0..n {
        for c in 0..k {
            let (j, s) = (indices[i * k + c], 1.0 - distances[i * k + c]);
            if s < SIMILARITY {
                break;
            }
            if j == i || !same_length(durations[i], durations[j]) {
                continue;
            }
            if seen.insert(i.min(j) as i64 * n as i64 + i.max(j) as i64) {
                out.push(Pair::new(ids[i], ids[j], false, s));
            }
        }
    }
    out
}

/// Sounds joined into sets (a copy of a copy is in the same set).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sets {
    /// Each sound in a set → its set's number.
    pub set_of: BTreeMap<i64, usize>,
    /// Each set's sounds in id order; sets by their first sound.
    pub members: Vec<Vec<i64>>,
    /// Each sound → the others it's the same as, and how: (id, identical, similarity).
    pub others: BTreeMap<i64, Vec<(i64, bool, f32)>>,
}

pub fn sets(pairs: &[Pair]) -> Sets {
    let mut parent: HashMap<i64, i64> = HashMap::new();
    fn find(parent: &mut HashMap<i64, i64>, x: i64) -> i64 {
        let mut r = x;
        while let Some(&p) = parent.get(&r) {
            if p == r {
                break;
            }
            r = p;
        }
        let mut y = x;
        while let Some(&p) = parent.get(&y) {
            if p == r {
                break;
            }
            parent.insert(y, r);
            y = p;
        }
        r
    }
    // An identical pair also found by its audio: keep "identical".
    let mut best: BTreeMap<(i64, i64), Pair> = BTreeMap::new();
    for p in pairs {
        if let Some(old) = best.get(&(p.a, p.b))
            && (old.identical || !p.identical)
        {
            continue;
        }
        best.insert((p.a, p.b), *p);
    }
    let mut out = Sets::default();
    for p in best.values() {
        parent.entry(p.a).or_insert(p.a);
        parent.entry(p.b).or_insert(p.b);
        let (ra, rb) = (find(&mut parent, p.a), find(&mut parent, p.b));
        parent.insert(ra, rb);
        out.others
            .entry(p.a)
            .or_default()
            .push((p.b, p.identical, p.similarity));
        out.others
            .entry(p.b)
            .or_default()
            .push((p.a, p.identical, p.similarity));
    }
    for list in out.others.values_mut() {
        list.sort_by_key(|o| (if o.1 { 0 } else { 1 }, o.0));
    }
    let keys: Vec<i64> = parent.keys().copied().collect();
    let mut groups: BTreeMap<i64, Vec<i64>> = BTreeMap::new();
    for id in keys {
        let root = find(&mut parent, id);
        groups.entry(root).or_default().push(id);
    }
    let mut members: Vec<Vec<i64>> = groups
        .into_values()
        .map(|mut g| {
            g.sort_unstable();
            g
        })
        .collect();
    members.sort_by_key(|g| g[0]);
    for (n, g) in members.iter().enumerate() {
        for &id in g {
            out.set_of.insert(id, n);
        }
    }
    out.members = members;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_copies_share_a_fingerprint() {
        let s = |id, fp: &str| (id, Some(fp.to_string()));
        let pairs = identical_pairs(
            &[s(1, "a"), s(2, "a"), s(3, "b"), s(4, "a")],
            &HashSet::from([4]),
        );
        assert_eq!(pairs, [Pair::new(1, 2, true, 1.0)]);
    }

    #[test]
    fn the_same_recording_needs_the_same_length() {
        // Rows 0–2: 0 and 1 alike at 0.999 (the same length), 0 and 2 at 0.9995 (another length).
        let pairs = near_pairs(
            &[10, 11, 12],
            &[Some(1.0), Some(1.005), Some(3.0)],
            &[0, 2, 1, 1, 0, 2, 2, 0, 1],
            &[0.0, 0.0005, 0.001, 0.0, 0.001, 0.2, 0.0, 0.0005, 0.2],
            3,
        );
        assert!(pairs.len() == 1 && pairs[0].a == 10 && pairs[0].b == 11 && !pairs[0].identical);
        assert!(same_length(Some(0.30), Some(0.315)) && !same_length(Some(10.0), Some(10.5)));
    }

    #[test]
    fn pairs_join_into_sets() {
        let s = sets(&[
            Pair::new(1, 2, true, 1.0),
            Pair::new(2, 3, false, 0.999),
            Pair::new(2, 1, false, 1.0),
            Pair::new(7, 8, false, 0.9985),
        ]);
        assert_eq!(s.members, [vec![1, 2, 3], vec![7, 8]]);
        assert_eq!((s.set_of[&3], s.set_of[&8]), (0, 1));
        // 1 and 2 are identical (kept over the audio's finding); 2 lists both.
        assert_eq!(s.others[&1].iter().map(|o| o.0).collect::<Vec<_>>(), [2]);
        assert!(s.others[&1][0].1);
        assert_eq!(s.others[&2].iter().map(|o| o.0).collect::<Vec<_>>(), [1, 3]);
    }
}
