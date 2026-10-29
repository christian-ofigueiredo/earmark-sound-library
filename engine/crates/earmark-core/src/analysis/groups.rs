//! Similarity groups inside a subcategory: the sounds' embeddings (PE-AV + CLAP combined),
//! centred on the set, laid out in 10 dimensions with UMAP (min_dist 0), cut into groups with
//! Ward's clustering, and named from the words the AI finds closest to each group, words for its
//! length and words its files share. Port of `SoundGroups.swift` (see there for why Ward and not
//! HDBSCAN) and of `SoundGroupPlan` from `SoundGroupStore.swift`.

use super::linalg::Floats;
use super::sound_map::{self, Settings, SplitMix};
use crate::ucs::UcsCatalog;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::OnceLock;

/// Bumped when grouping or naming changes: groups made by an older version are made again
/// (unless the owner changed them).
pub const VERSION: i64 = 1;
pub const MIN_GROUP_SIZE: usize = 5;

/// How many groups a set of `n` sounds is split into: about √(n/8), 2–12; under 20 sounds, one.
pub fn group_count(n: usize) -> usize {
    if n < 20 {
        1
    } else {
        12.min(2.max((n as f64 / 8.0).sqrt().round() as usize))
    }
}

/// A group per sound: 0 for the largest group, 1 for the next… `x`: `n` rows of `d` (unit
/// length, combined models). None if cancelled.
pub fn cluster(
    x: &[f32],
    n: usize,
    d: usize,
    is_cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Vec<usize>> {
    let k = group_count(n);
    if k <= 1 {
        return Some(vec![0; n]);
    }
    // Centred on this set: what sets these sounds apart, not what they share.
    let mut space = block_normalise(x, n, d);
    let reduced = if n < 30 {
        // Phase 0: PCA to up to 10 dimensions.
        let m = 2.max(10.min(n - 1));
        let mut rng = SplitMix::new(42);
        let p = sound_map::principal(&space, n, d, m, &mut rng);
        (0..n)
            .flat_map(|i| p.iter().map(move |c| c[i]))
            .collect::<Vec<f32>>()
    } else {
        // UMAP with the cosine distance: rows to unit length.
        for i in 0..n {
            let row = &mut space[i * d..(i + 1) * d];
            let l = row.iter().fold(0f32, |s, v| s + v * v).sqrt().max(1e-12);
            for v in row.iter_mut() {
                *v /= l;
            }
        }
        let settings = Settings {
            neighbours: 15.min(n - 1),
            ..Settings::clustering()
        };
        sound_map::reduce(&space, n, d, 10.min(n - 2), &settings, is_cancelled)?
    };
    let dims = reduced.len() / n;
    Some(ward(&reduced, n, dims, k))
}

/// Phase 0's _block_normalize: centred on the set, scaled to an average length of 1.
pub fn block_normalise(x: &[f32], n: usize, d: usize) -> Floats {
    let mut mean = vec![0f64; d];
    for i in 0..n {
        for c in 0..d {
            mean[c] += x[i * d + c] as f64;
        }
    }
    for m in &mut mean {
        *m /= n as f64;
    }
    // In a page-aligned buffer, as the Swift app's (Accelerate's sums depend on it).
    let mut out = Floats::page(n * d);
    let mut total = 0.0;
    for i in 0..n {
        for c in 0..d {
            let v = x[i * d + c] as f64 - mean[c];
            out[i * d + c] = v as f32;
            total += v * v;
        }
    }
    let scale = (1.0 / (total / n as f64 + 1e-12).sqrt()) as f32;
    for v in out.iter_mut() {
        *v *= scale;
    }
    out
}

/// Ward's clustering (each merge the one that adds least to the groups' spread) cut at `k`
/// groups, groups under `MIN_GROUP_SIZE` then joined to their nearest. Labels by size, largest
/// 0. The nearest-neighbour chain over group centres: O(n²·d) time, no distance matrix.
///
/// Where Swift chooses between equally small groups in its dictionary's order, this takes the
/// one with the lowest point, so it's the same every time.
pub fn ward(z: &[f32], n: usize, d: usize, k: usize) -> Vec<usize> {
    if n <= 1 || k <= 1 {
        return vec![0; n];
    }
    // Slot i starts as point i; a merged group stays in the lower slot.
    let mut centre: Vec<f64> = z[..n * d].iter().map(|&v| v as f64).collect();
    let mut size = vec![1f64; n];
    let mut active = vec![true; n];
    let cost = |centre: &[f64], size: &[f64], a: usize, b: usize| {
        let mut t = 0.0;
        for c in 0..d {
            let v = centre[a * d + c] - centre[b * d + c];
            t += v * v;
        }
        size[a] * size[b] / (size[a] + size[b]) * t
    };
    let mut merges: Vec<(usize, usize, f64)> = Vec::with_capacity(n - 1);
    let mut chain: Vec<usize> = Vec::new();
    let mut first = 0;
    while merges.len() < n - 1 {
        if chain.is_empty() {
            while !active[first] {
                first += 1;
            }
            chain.push(first);
        }
        let a = chain[chain.len() - 1];
        let previous = if chain.len() >= 2 {
            Some(chain[chain.len() - 2])
        } else {
            None
        };
        // The nearest group, the one before in the chain when tied (so the chain ends).
        let (mut best, mut best_cost) = match previous {
            Some(p) => (Some(p), cost(&centre, &size, a, p)),
            None => (None, f64::INFINITY),
        };
        for j in 0..n {
            if active[j] && j != a {
                let c = cost(&centre, &size, a, j);
                if c < best_cost {
                    best = Some(j);
                    best_cost = c;
                }
            }
        }
        if best == previous {
            let p = previous.unwrap();
            chain.truncate(chain.len() - 2);
            merges.push((a, p, best_cost));
            let (keep, drop, s) = (a.min(p), a.max(p), size[a] + size[p]);
            for c in 0..d {
                centre[keep * d + c] =
                    (centre[a * d + c] * size[a] + centre[p * d + c] * size[p]) / s;
            }
            size[keep] = s;
            active[drop] = false;
        } else {
            chain.push(best.unwrap());
        }
    }
    // The cheapest n − k merges (Ward's costs only grow up the tree), on the points.
    let mut parent: Vec<usize> = (0..n).collect();
    fn find(parent: &mut [usize], x: usize) -> usize {
        let mut r = x;
        while parent[r] != r {
            r = parent[r];
        }
        let mut y = x;
        while parent[y] != r {
            let up = parent[y];
            parent[y] = r;
            y = up;
        }
        r
    }
    let mut order: Vec<usize> = (0..merges.len()).collect();
    order.sort_by(|&i, &j| merges[i].2.total_cmp(&merges[j].2).then(i.cmp(&j)));
    for &m in order.iter().take(n - k) {
        let (ra, rb) = (
            find(&mut parent, merges[m].0),
            find(&mut parent, merges[m].1),
        );
        parent[ra] = rb;
    }
    let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for i in 0..n {
        let r = find(&mut parent, i);
        groups.entry(r).or_default().push(i);
    }
    // Too-small groups join the group whose centre is nearest (by Ward's cost).
    let mut sets: Vec<Vec<usize>> = groups.into_values().collect();
    sets.sort_by_key(|g| g[0]);
    let centre_of = |g: &[usize]| -> Vec<f64> {
        let mut c = vec![0f64; d];
        for &i in g {
            for j in 0..d {
                c[j] += z[i * d + j] as f64;
            }
        }
        c.iter().map(|v| v / g.len() as f64).collect()
    };
    while sets.len() > 1 {
        let Some(small) = (0..sets.len())
            .filter(|&i| sets[i].len() < MIN_GROUP_SIZE)
            .min_by_key(|&i| sets[i].len())
        else {
            break;
        };
        let c = centre_of(&sets[small]);
        let ward_cost = |g: usize| {
            let o = centre_of(&sets[g]);
            let (s, t) = (sets[g].len() as f64, sets[small].len() as f64);
            s * t / (s + t)
                * c.iter()
                    .zip(&o)
                    .fold(0.0, |acc, (a, b)| acc + (a - b) * (a - b))
        };
        let target = (0..sets.len())
            .filter(|&g| g != small)
            .min_by(|&a, &b| {
                ward_cost(a)
                    .partial_cmp(&ward_cost(b))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .unwrap();
        let moved = std::mem::take(&mut sets[small]);
        sets[target].extend(moved);
        sets.remove(small);
    }
    sets.sort_by(|a, b| {
        b.len()
            .cmp(&a.len())
            .then(a.iter().min().cmp(&b.iter().min()))
    });
    let mut labels = vec![0; n];
    for (g, members) in sets.iter().enumerate() {
        for &i in members {
            labels[i] = g;
        }
    }
    labels
}

// MARK: names

/// The words groups are named with (Phase 0's DESCRIPTORS).
pub const WORDS: &[&str] = &[
    "airy",
    "breathy",
    "windy",
    "swishy",
    "whooshing",
    "swooshing",
    "fluttering",
    "whipping",
    "fast",
    "slow",
    "short",
    "long",
    "sustained",
    "rising",
    "falling",
    "pass-by",
    "doppler",
    "deep",
    "low rumble",
    "sub bass",
    "high-pitched",
    "bright",
    "dark",
    "muffled",
    "thin",
    "full",
    "metallic",
    "ringing",
    "resonant",
    "glassy",
    "wooden",
    "cloth",
    "fabric",
    "paper",
    "plastic",
    "rubber",
    "watery",
    "splashy",
    "liquid",
    "fiery",
    "crackling",
    "electric",
    "buzzing",
    "humming",
    "static",
    "digital",
    "glitchy",
    "synthetic",
    "sci-fi",
    "futuristic",
    "laser",
    "magical",
    "sparkly",
    "shimmering",
    "ethereal",
    "eerie",
    "dark ambient",
    "cinematic",
    "trailer",
    "aggressive",
    "heavy",
    "light",
    "soft",
    "harsh",
    "gritty",
    "distorted",
    "noisy",
    "tonal",
    "musical",
    "reversed",
    "granular",
    "organic",
    "mechanical",
    "motor",
    "engine",
    "wind gust",
    "animal",
    "creature",
    "vocal",
    "human",
    "impact",
    "hit",
    "boom",
    "thud",
    "punchy",
    "click",
    "snap",
    "crunchy",
    "squeaky",
    "creaky",
    "explosive",
    "distant",
    "close-up",
    "roomy",
    "reverberant",
    "dry",
    "beep",
    "alarm",
    "tick",
];

/// The words' text embeddings, combined like the sounds' (PE-AV, then CLAP): `WORDS.len()` rows of
/// 1536, from Phase 0's text models (models/export_groups.py), shipped with the Swift app.
pub fn word_vectors() -> &'static [f32] {
    static VECTORS: OnceLock<Vec<f32>> = OnceLock::new();
    VECTORS.get_or_init(|| {
        let bytes =
            include_bytes!("../../../../../app/Sources/EarmarkCore/Resources/group_words.bin");
        let floats: Vec<f32> = bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        let (n, peav, clap) = (WORDS.len(), 1024, 512);
        assert_eq!(
            floats.len(),
            n * (peav + clap),
            "group_words.bin doesn't fit the words"
        );
        (0..n)
            .flat_map(|i| {
                sound_map::combine(&[
                    &floats[i * peav..(i + 1) * peav],
                    &floats[n * peav + i * clap..n * peav + (i + 1) * clap],
                ])
            })
            .collect()
    })
}

/// What a group is called and the words behind it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Name {
    pub name: String,
    /// Closest to the sound, from the AI (most telling first).
    pub ai_words: Vec<String>,
    /// From the group's sounds' length, against the set's.
    pub shape_words: Vec<String>,
    /// Words most of the group's files share (names, descriptions, keywords).
    pub keywords: Vec<String>,
}

/// One sound, for naming.
#[derive(Clone, Debug)]
pub struct Member {
    pub duration: Option<f64>,
    /// The file name, FX name, description and keywords.
    pub text: String,
}

impl Member {
    /// From a sound's fields, as `SoundGroups.Member(_ s: SoundRecord)`.
    pub fn new(
        duration: Option<f64>,
        file_name: &str,
        fx_name: Option<&str>,
        details: Option<&str>,
        keywords: Option<&str>,
    ) -> Member {
        let text = [
            file_name.replace('_', " ").as_str(),
            fx_name.unwrap_or(""),
            details.unwrap_or(""),
            keywords.unwrap_or(""),
        ]
        .join(" ");
        Member { duration, text }
    }
}

fn cat_id_words() -> &'static HashSet<String> {
    static WORDS: OnceLock<HashSet<String>> = OnceLock::new();
    WORDS.get_or_init(|| {
        UcsCatalog::shared()
            .entries
            .iter()
            .map(|e| e.cat_id.to_lowercase())
            .collect()
    })
}

/// Words that never make keywords for these sounds: CatIDs, and who made them (library,
/// manufacturer, designer, the pack's top folder), so pack names don't leak in. Each sound's
/// fields: (vendor library, manufacturer, designer, folder).
pub fn excluded_words(
    sounds: &[(Option<&str>, Option<&str>, Option<&str>, &str)],
) -> HashSet<String> {
    let mut out = cat_id_words().clone();
    for (library, manufacturer, designer, folder) in sounds {
        let top = folder.split('/').find(|p| !p.is_empty());
        for field in [*library, *manufacturer, *designer, top]
            .into_iter()
            .flatten()
        {
            out.extend(tokens(field));
        }
    }
    out
}

/// Names for a set's groups (`groups`: each group's rows in `x`). `library_mean`: the mean of
/// every analysed sound's vector, so words that fit everything count less. `exclude`: words never
/// used as keywords.
pub fn names(
    groups: &[Vec<usize>],
    x: &[f32],
    d: usize,
    members: &[Member],
    library_mean: &[f32],
    exclude: &HashSet<String>,
) -> Vec<Name> {
    if groups.is_empty() {
        return vec![];
    }
    let ai = ai_words(groups, x, d, library_mean);
    let shape = shape_words(groups, members);
    let texts: Vec<&str> = members.iter().map(|m| m.text.as_str()).collect();
    let keys = keywords(groups, &texts, exclude);
    let synonym = synonyms();
    let mut used: HashMap<String, usize> = HashMap::new();
    (0..groups.len())
        .map(|g| {
            // One word per family of near-synonyms: "Whooshing · Swooshing" says one thing.
            let fits = |w: &str, chosen: &[String]| {
                !chosen.iter().any(|c| c == w)
                    && !chosen.iter().any(|c| {
                        synonym.get(c.as_str()).is_some()
                            && synonym.get(c.as_str()) == synonym.get(w)
                    })
            };
            let mut chosen: Vec<String> = Vec::new();
            let mut rest: Vec<String> = ai[g].clone();
            for w in shape[g].iter().take(2).chain(ai[g].iter()) {
                if chosen.len() < 3 && fits(w, &chosen) {
                    chosen.push(w.clone());
                    rest.retain(|r| r != w);
                }
            }
            let title = |c: &[String]| {
                c.iter()
                    .map(|w| capitalised(w))
                    .collect::<Vec<_>>()
                    .join(" · ")
            };
            let mut name = title(&chosen);
            if name.is_empty() {
                name = format!("Group {}", g + 1);
            }
            // Two groups with the same name: the next words the AI found, else a number.
            let mut extra = rest.into_iter();
            while used.contains_key(&name) {
                let Some(w) = extra.next() else { break };
                if !fits(&w, &chosen) {
                    continue;
                }
                chosen.push(w);
                name = title(&chosen);
            }
            if let Some(n) = used.get(&name).copied() {
                used.insert(name.clone(), n + 1);
                name = format!("{name} {}", n + 1);
            } else {
                used.insert(name.clone(), 1);
            }
            Name {
                name,
                ai_words: ai[g].iter().take(3).cloned().collect(),
                shape_words: shape[g].clone(),
                keywords: keys[g].clone(),
            }
        })
        .collect()
}

/// Words that say nearly the same thing (by hand). Word → family.
fn synonyms() -> &'static HashMap<&'static str, usize> {
    static MAP: OnceLock<HashMap<&'static str, usize>> = OnceLock::new();
    MAP.get_or_init(|| {
        let families: &[&[&str]] = &[
            &["whooshing", "swooshing", "swishy"],
            &["windy", "wind gust", "airy"],
            &["sci-fi", "futuristic"],
            &["impact", "hit"],
            &["cloth", "fabric"],
            &["boom", "explosive"],
            &["watery", "liquid"],
            &["motor", "engine"],
            &["vocal", "human"],
            &["animal", "creature"],
            &["crunchy", "crackling"],
            &["low rumble", "sub bass", "deep"],
            &["dark", "dark ambient"],
            &["digital", "glitchy"],
            &["ethereal", "eerie"],
            &["ringing", "resonant"],
            &["sparkly", "shimmering"],
            &["long", "sustained", "slow"],
            &["static", "noisy"],
            &["humming", "buzzing"],
            &["squeaky", "creaky"],
            &["click", "tick", "snap"],
            &["muffled", "distant"],
            &["aggressive", "harsh"],
            &["cinematic", "trailer"],
            &["alarm", "beep"],
            &["light", "soft"],
            &["bright", "high-pitched"],
        ];
        let mut out = HashMap::new();
        for (i, f) in families.iter().enumerate() {
            for w in f.iter() {
                out.insert(*w, i);
            }
        }
        out
    })
}

/// Phase 0's descriptor_names: the words nearest each group's centre, less the set's average
/// (0.6) and the library's (0.3), so groups get the words that set them apart. Six per group.
fn ai_words(groups: &[Vec<usize>], x: &[f32], d: usize, library_mean: &[f32]) -> Vec<Vec<String>> {
    let vectors = word_vectors();
    let w = WORDS.len();
    if d != vectors.len() / w {
        return vec![vec![]; groups.len()];
    }
    let scores = |v: &[f32]| -> Vec<f32> {
        (0..w)
            .map(|j| {
                let mut s = 0f32;
                for c in 0..d {
                    s += v[c] * vectors[j * d + c];
                }
                s
            })
            .collect()
    };
    let rows: Vec<Vec<f32>> = groups
        .iter()
        .map(|members| {
            let mut centre = vec![0f32; d];
            for &i in members {
                for c in 0..d {
                    centre[c] += x[i * d + c];
                }
            }
            let l = centre.iter().fold(0f32, |s, v| s + v * v).sqrt().max(1e-12);
            scores(&centre.iter().map(|v| v / l).collect::<Vec<_>>())
        })
        .collect();
    let library = if library_mean.len() == d {
        scores(library_mean)
    } else {
        vec![0.0; w]
    };
    let set_mean: Vec<f32> = (0..w)
        .map(|j| rows.iter().fold(0f32, |s, r| s + r[j]) / rows.len() as f32)
        .collect();
    rows.iter()
        .map(|s| {
            let adjusted: Vec<f32> = (0..w)
                .map(|j| s[j] - 0.6 * set_mean[j] - 0.3 * library[j])
                .collect();
            let mut order: Vec<usize> = (0..w).collect();
            // Swift's sort is stable: ties keep the words' order.
            order.sort_by(|&a, &b| {
                adjusted[b]
                    .partial_cmp(&adjusted[a])
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            order
                .into_iter()
                .take(6)
                .map(|j| WORDS[j].to_string())
                .collect()
        })
        .collect()
}

/// Phase 0's describe_shape, for length: "short" or "long" against the set's 33rd and 67th
/// percentiles, when the set's lengths really vary.
fn shape_words(groups: &[Vec<usize>], members: &[Member]) -> Vec<Vec<String>> {
    let mut all: Vec<f64> = groups
        .iter()
        .flatten()
        .filter_map(|&i| members[i].duration)
        .collect();
    all.sort_by(f64::total_cmp);
    if all.len() < 3 {
        return vec![vec![]; groups.len()];
    }
    let percentile = |p: f64| {
        let r = p / 100.0 * (all.len() - 1) as f64;
        let lo = r as usize;
        let hi = (lo + 1).min(all.len() - 1);
        all[lo] + (all[hi] - all[lo]) * (r - lo as f64)
    };
    let (lo, hi) = (percentile(33.0), percentile(67.0));
    if hi <= 1.4 * lo {
        return vec![vec![]; groups.len()];
    }
    groups
        .iter()
        .map(|g| {
            let lengths: Vec<f64> = g.iter().filter_map(|&i| members[i].duration).collect();
            if lengths.is_empty() {
                return vec![];
            }
            let mean = lengths.iter().fold(0.0, |s, v| s + v) / lengths.len() as f64;
            if mean <= lo {
                vec!["short".to_string()]
            } else if mean >= hi {
                vec!["long".to_string()]
            } else {
                vec![]
            }
        })
        .collect()
}

const STOP_WORDS: &[&str] = &[
    "a",
    "an",
    "and",
    "the",
    "of",
    "in",
    "on",
    "at",
    "to",
    "for",
    "with",
    "by",
    "from",
    "as",
    "or",
    "is",
    "are",
    "be",
    "into",
    "over",
    "under",
    "up",
    "down",
    "out",
    "off",
    "this",
    "that",
    "these",
    "those",
    "it",
    "its",
    "very",
    "more",
    "most",
    "some",
    "any",
    "each",
    "all",
    "no",
    "not",
    "one",
    "two",
    "three",
    "sfx",
    "fx",
    "sound",
    "sounds",
    "effect",
    "effects",
    "designed",
    "version",
    "var",
    "variation",
    "take",
    "wav",
    "mono",
    "stereo",
    "audio",
    "file",
    "pack",
    "library",
    "vol",
    "volume",
];

/// Phase 0's tokens: lowercase words of 3+ letters (hyphens allowed), no stop words. Letters are
/// whole characters, as in Swift: an "e" followed by a combining accent is one character, "é",
/// which isn't a-z.
pub fn tokens(text: &str) -> Vec<String> {
    let lower = text.to_lowercase();
    let chars: Vec<char> = lower.chars().collect();
    let (mut out, mut word) = (Vec::new(), String::new());
    let flush = |word: &mut String, out: &mut Vec<String>| {
        if word.chars().count() >= 3 && !STOP_WORDS.contains(&word.as_str()) {
            out.push(word.clone());
        }
        word.clear();
    };
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        // The rest of this character: combining marks after it.
        let mut end = i + 1;
        while end < chars.len() && is_combining(chars[end]) {
            end += 1;
        }
        let single = end == i + 1;
        if single && (c.is_ascii_lowercase() || (c == '-' && !word.is_empty())) {
            word.push(c);
        } else {
            flush(&mut word, &mut out);
        }
        i = end;
    }
    flush(&mut word, &mut out);
    out
}

/// Marks that join the character before them (the combining blocks; enough for the decomposed
/// names Foundation gives).
fn is_combining(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F | 0x3099..=0x309A)
}

/// Phase 0's keyword_names: words at least 30% of a group's files have, by how much more often
/// than in the set's other groups (TF-IDF style). Three per group. A word most of the groups have
/// is left out: it describes the set, not the group.
fn keywords(groups: &[Vec<usize>], texts: &[&str], exclude: &HashSet<String>) -> Vec<Vec<String>> {
    let (mut df, mut common): (HashMap<String, usize>, HashMap<String, usize>) =
        (HashMap::new(), HashMap::new());
    let counts: Vec<HashMap<String, usize>> = groups
        .iter()
        .map(|g| {
            let mut c: HashMap<String, usize> = HashMap::new();
            for &i in g {
                let set: BTreeSet<String> = tokens(texts[i]).into_iter().collect();
                for t in set {
                    if !exclude.contains(&t) {
                        *c.entry(t).or_default() += 1;
                    }
                }
            }
            for (w, &cnt) in &c {
                *df.entry(w.clone()).or_default() += 1;
                if cnt as f64 >= 0.3 * g.len() as f64 {
                    *common.entry(w.clone()).or_default() += 1;
                }
            }
            c
        })
        .collect();
    let n = groups.len().max(1) as f64;
    (0..groups.len())
        .map(|g| {
            let size = groups[g].len().max(1) as f64;
            let mut scored: Vec<(f64, &String)> = counts[g]
                .iter()
                .filter(|&(w, &cnt)| {
                    cnt as f64 / size >= 0.3
                        && (groups.len() < 3
                            || common.get(w).copied().unwrap_or(0) * 2 <= groups.len())
                })
                .map(|(w, &cnt)| (cnt as f64 / size * (1.0 + n / df[w] as f64).ln(), w))
                .collect();
            scored.sort_by(|a, b| {
                b.0.partial_cmp(&a.0)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then(b.1.cmp(a.1))
            });
            scored.into_iter().take(3).map(|s| s.1.clone()).collect()
        })
        .collect()
}

/// Python's str.capitalize: "Sci-fi", "Low rumble".
fn capitalised(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(f) => f.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase(),
        None => String::new(),
    }
}

// MARK: what to do (SoundGroupPlan)

/// A subcategory's stored groups as a whole.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupSet {
    #[serde(rename = "catID")]
    pub cat_id: String,
    /// `VERSION` when grouped.
    pub version: i64,
    /// How many sounds were grouped.
    pub grouped: i64,
    /// Sounds added to or removed from the groups since (regrouped once that's a quarter).
    pub changed: i64,
    /// The owner renamed, merged, moved or made a group here.
    pub edited: bool,
    pub grouped_at: String,
}

/// What's stored about groups, as `SoundGroupSnapshot`.
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub sets: BTreeMap<String, GroupSet>,
    /// Group ids by catID, in sidebar order.
    pub groups: BTreeMap<String, Vec<i64>>,
    /// Sound id → its group's id.
    pub membership: HashMap<i64, i64>,
    /// Sound id → the fingerprint it was grouped with.
    pub member_fingerprints: HashMap<i64, Option<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Work {
    /// Group all of these sounds afresh (replacing any groups).
    Regroup { cat_id: String, sounds: Vec<i64> },
    /// Keep the groups: put `add` in the nearest group, take `remove` out.
    Update {
        cat_id: String,
        add: Vec<i64>,
        remove: Vec<i64>,
    },
    /// No sounds left: forget the groups.
    Drop { cat_id: String },
}

/// What needs doing, given each subcategory's sounds that can be grouped now and what's stored
/// (`SoundGroupPlan.work`).
pub fn work(sounds: &BTreeMap<String, Vec<(i64, Option<String>)>>, stored: &Snapshot) -> Vec<Work> {
    let mut out = Vec::new();
    let mut order: Vec<(&String, &Vec<(i64, Option<String>)>)> = sounds.iter().collect();
    order.sort_by(|a, b| b.1.len().cmp(&a.1.len()).then(a.0.cmp(b.0)));
    for (cat_id, list) in order {
        let mut ids: Vec<i64> = list.iter().map(|s| s.0).collect();
        ids.sort_unstable();
        let Some(set) = stored.sets.get(cat_id) else {
            if !ids.is_empty() {
                out.push(Work::Regroup {
                    cat_id: cat_id.clone(),
                    sounds: ids,
                });
            }
            continue;
        };
        let in_groups: HashSet<i64> = stored
            .groups
            .get(cat_id)
            .map(|g| g.iter().copied().collect())
            .unwrap_or_default();
        // Members of this subcategory's groups, with the file they were grouped as.
        let current: HashSet<i64> = list
            .iter()
            .filter(|(id, fp)| {
                stored
                    .membership
                    .get(id)
                    .is_some_and(|g| in_groups.contains(g))
                    && stored.member_fingerprints.get(id) == Some(fp)
            })
            .map(|s| s.0)
            .collect();
        let members: HashSet<i64> = stored
            .membership
            .iter()
            .filter(|(_, g)| in_groups.contains(g))
            .map(|(&s, _)| s)
            .collect();
        let add: Vec<i64> = ids
            .iter()
            .copied()
            .filter(|i| !current.contains(i))
            .collect();
        let mut remove: Vec<i64> = members.difference(&current).copied().collect();
        remove.sort_unstable();
        if ids.is_empty() {
            out.push(Work::Drop {
                cat_id: cat_id.clone(),
            });
        } else if !set.edited
            && (set.version < VERSION
                || (set.changed + add.len() as i64 + remove.len() as i64) * 4 > set.grouped.max(1))
        {
            out.push(Work::Regroup {
                cat_id: cat_id.clone(),
                sounds: ids,
            });
        } else if !add.is_empty() || !remove.is_empty() {
            out.push(Work::Update {
                cat_id: cat_id.clone(),
                add,
                remove,
            });
        }
    }
    for cat_id in stored.sets.keys() {
        if !sounds.contains_key(cat_id) {
            out.push(Work::Drop {
                cat_id: cat_id.clone(),
            });
        }
    }
    out
}

/// The group whose centre (the mean of its members, unit vectors) is nearest by cosine. `x`: rows
/// of `d`; `members`: group id → rows. None when there are no groups; ties go to the lower id.
pub fn nearest(v: &[f32], x: &[f32], d: usize, members: &BTreeMap<i64, Vec<usize>>) -> Option<i64> {
    let mut best: Option<(i64, f32)> = None;
    for (&g, rows) in members {
        if rows.is_empty() {
            continue;
        }
        let mut centre = vec![0f32; d];
        for &r in rows {
            for c in 0..d {
                centre[c] += x[r * d + c];
            }
        }
        let norm = centre.iter().fold(0f32, |s, v| s + v * v).sqrt().max(1e-12);
        let dot = v.iter().zip(&centre).fold(0f32, |s, (a, b)| s + a * b);
        let score = dot / norm;
        if best.is_none_or(|(bg, bs)| score > bs || (score == bs && g < bg)) {
            best = Some((g, score));
        }
    }
    best.map(|b| b.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct WardCase {
        dimensions: usize,
        groups: usize,
        points: Vec<f64>,
        labels: Vec<i64>,
    }
    #[derive(Deserialize)]
    struct WardFixture {
        cases: Vec<WardCase>,
    }

    fn partition<T: Copy + Eq + std::hash::Hash>(labels: &[T]) -> BTreeSet<BTreeSet<usize>> {
        let mut by: HashMap<T, BTreeSet<usize>> = HashMap::new();
        for (i, &l) in labels.iter().enumerate() {
            by.entry(l).or_default().insert(i);
        }
        by.into_values().collect()
    }

    /// The same groups as sklearn's AgglomerativeClustering(linkage="ward") (numbered by size here).
    #[test]
    fn ward_matches_scikit_learn() {
        let f: WardFixture = serde_json::from_str(include_str!(
            "../../../../../app/Tests/EarmarkCoreTests/Fixtures/ward.json"
        ))
        .unwrap();
        for c in f.cases {
            let z: Vec<f32> = c.points.iter().map(|&v| v as f32).collect();
            let labels = ward(&z, c.labels.len(), c.dimensions, c.groups);
            assert_eq!(partition(&labels), partition(&c.labels));
            let sizes: Vec<usize> = (0..c.groups)
                .map(|g| labels.iter().filter(|&&l| l == g).count())
                .collect();
            let mut sorted = sizes.clone();
            sorted.sort_by(|a, b| b.cmp(a));
            assert_eq!(sizes, sorted);
        }
    }

    #[test]
    fn ward_joins_tiny_groups() {
        // Two clumps of 10 and one far point: asked for 3 groups, the lone point joins a clump.
        let mut points = Vec::new();
        for i in 0..10 {
            points.extend([i as f32 * 0.01, 0.0]);
        }
        for i in 0..10 {
            points.extend([5.0 + i as f32 * 0.01, 0.0]);
        }
        points.extend([20.0, 0.0]);
        let labels = ward(&points, 21, 2, 3);
        assert_eq!(labels.iter().collect::<BTreeSet<_>>().len(), 2);
        assert_eq!(labels[20], labels[10]);
    }

    #[test]
    fn group_count_grows_with_the_set() {
        assert_eq!([10, 30, 440, 6586].map(group_count), [1, 2, 7, 12]);
    }

    fn clustered(clusters: usize, each: usize, dims: usize, spread: f32) -> (Vec<f32>, Vec<usize>) {
        let mut rng = SplitMix::new(7);
        let unit = |v: Vec<f32>| {
            let l = v.iter().map(|a| a * a).sum::<f32>().sqrt();
            v.into_iter().map(|a| a / l).collect::<Vec<_>>()
        };
        let centres: Vec<Vec<f32>> = (0..clusters)
            .map(|_| unit((0..dims).map(|_| rng.normal(1.0)).collect()))
            .collect();
        let (mut x, mut labels) = (Vec::new(), Vec::new());
        for (c, centre) in centres.iter().enumerate() {
            for _ in 0..each {
                let v: Vec<f32> = centre
                    .iter()
                    .map(|a| a + rng.normal(spread / (dims as f32).sqrt()))
                    .collect();
                x.extend(unit(v));
                labels.push(c);
            }
        }
        (x, labels)
    }

    #[test]
    fn groups_find_the_clusters() {
        // 4 × 32 sounds: 4 groups (√(128/8)).
        let (x, truth) = clustered(4, 32, 48, 0.3);
        let labels = cluster(&x, 128, 48, &|| false).unwrap();
        for g in labels.iter().collect::<BTreeSet<_>>() {
            let mixed: BTreeSet<usize> = labels
                .iter()
                .zip(&truth)
                .filter(|(l, _)| *l == g)
                .map(|(_, t)| *t)
                .collect();
            assert_eq!(mixed.len(), 1, "group {g} mixes clusters");
        }
        assert_eq!(labels.iter().collect::<BTreeSet<_>>().len(), 4);
        assert_eq!(cluster(&x, 128, 48, &|| false).unwrap(), labels);
    }

    #[test]
    fn small_sets_are_one_group_or_split_by_pca() {
        let (few, _) = clustered(2, 4, 16, 0.25);
        assert_eq!(cluster(&few, 8, 16, &|| false).unwrap(), vec![0; 8]);
        let (some, truth) = clustered(2, 12, 16, 0.2);
        let labels = cluster(&some, 24, 16, &|| false).unwrap();
        assert_eq!(labels.iter().collect::<BTreeSet<_>>().len(), 2);
        assert_eq!(partition(&labels), partition(&truth));
    }

    #[test]
    fn word_vectors_load() {
        let v = word_vectors();
        assert_eq!(v.len(), WORDS.len() * 1536);
        let first: f32 = v[..1536].iter().map(|a| a * a).sum();
        assert!((first - 1.0).abs() < 1e-4);
    }

    #[test]
    fn names_use_length_ai_words_and_stay_unique() {
        let words = word_vectors();
        let d = 1536;
        let row = |w: &str| {
            let j = WORDS.iter().position(|x| *x == w).unwrap();
            words[j * d..(j + 1) * d].to_vec()
        };
        let mut x = Vec::new();
        for _ in 0..6 {
            x.extend(row("metallic"));
        }
        for _ in 0..6 {
            x.extend(row("watery"));
        }
        let members: Vec<Member> = (0..12)
            .map(|i| Member {
                duration: Some(if i < 6 { 0.4 } else { 9.0 }),
                text: if i < 6 {
                    format!("Clang_Pipe_Hit {i}")
                } else {
                    format!("Stream water flow {i}")
                },
            })
            .collect();
        let none = HashSet::new();
        let g: Vec<Vec<usize>> = vec![(0..6).collect(), (6..12).collect()];
        let names = names(&g, &x, d, &members, &[], &none);
        assert_eq!(names[0].shape_words, ["short"]);
        assert_eq!(names[1].shape_words, ["long"]);
        assert_eq!(names[0].ai_words[0], "metallic");
        assert_eq!(names[1].ai_words[0], "watery");
        assert!(
            names[0].name.starts_with("Short · Metallic"),
            "{}",
            names[0].name
        );
        assert!(
            names[0].keywords.contains(&"clang".to_string())
                && names[1].keywords.contains(&"stream".to_string())
        );
        let twice = super::names(
            &[(0..6).collect(), (0..6).collect()],
            &x,
            d,
            &members,
            &[],
            &none,
        );
        assert_ne!(twice[0].name, twice[1].name);
    }

    #[test]
    fn tokens_as_phase0() {
        assert_eq!(
            tokens("Whoosh_Fast-Pass 03 the SFX a1bc"),
            ["whoosh", "fast-pass"]
        );
        // Swift's characters: "e" + combining acute is one character, not a letter.
        assert_eq!(tokens("cafe\u{301} bar"), ["caf", "bar"]);
    }
}
