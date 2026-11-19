//! Categories for sounds without one of their own: the owner's rule for a folder, or Earmark's
//! guess for it, and the suggestions behind those guesses (from the folder's name, the words its
//! files share, and what its sounds sound like). Port of `FolderRules.swift`.
//!
//! Where Swift's choice depends on a set's order (options with exactly the same score), this goes
//! by CatID, so it's the same every time.

use super::similarity::SimilarityIndex;
use crate::records::SoundRecord;
use crate::text::{characters, is_letter, is_lowercase, is_uppercase};
use crate::ucs::{UcsCatalog, UcsEntry};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::OnceLock;

/// A UCS category the owner chose for the sounds of one folder that have none of their own.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderRule {
    pub library_id: i64,
    /// Relative to the library, as `SoundRecord.folder`.
    pub folder: String,
    #[serde(rename = "catID")]
    pub cat_id: String,
    pub created_at: String,
}

/// A category Earmark guessed for a folder whose sounds have none, applied without asking until
/// the owner picks one.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderGuess {
    pub library_id: i64,
    pub folder: String,
    #[serde(rename = "catID")]
    pub cat_id: String,
    /// The next options, best first, comma-separated ("FEETAnml,FEETCrea").
    pub alternatives: String,
    /// Why, as the app shows it.
    pub reason: String,
    /// Another category fits as well, or nothing but a few similar sounds agree.
    pub is_unsure: bool,
    /// How many of the folder's sounds had been analysed (CLAP) when guessing.
    pub analysed: i64,
    pub version: i64,
    pub created_at: String,
}

impl FolderGuess {
    pub fn alternative_ids(&self) -> Vec<String> {
        self.alternatives
            .split(',')
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect()
    }
}

pub const SOURCE: &str = "your folder rule";
pub const GUESS_SOURCE: &str = "Earmark's guess";

/// The nearest folder at or above `folder` that's in `folders`.
fn nearest_in<'a, T>(folder: &str, folders: &'a HashMap<String, T>) -> Option<&'a T> {
    let mut f = folder;
    loop {
        if let Some(e) = folders.get(f) {
            return Some(e);
        }
        f = &f[..f.rfind('/')?];
    }
}

/// Sounds without a category of their own take the owner's rule for their folder or the nearest
/// folder above it; failing that, Earmark's guess, found the same way.
pub fn apply(
    rules: &[FolderRule],
    guesses: &[FolderGuess],
    sounds: &[SoundRecord],
    catalog: &UcsCatalog,
) -> Vec<SoundRecord> {
    if rules.is_empty() && guesses.is_empty() {
        return sounds.to_vec();
    }
    let index = |pairs: Vec<(i64, &str, &str)>| {
        let mut out: HashMap<i64, HashMap<String, UcsEntry>> = HashMap::new();
        for (lib, folder, cat) in pairs {
            if let Some(e) = catalog.entry_by_cat_id(Some(cat)) {
                out.entry(lib)
                    .or_default()
                    .insert(folder.to_string(), e.clone());
            }
        }
        out
    };
    let chosen = index(
        rules
            .iter()
            .map(|r| (r.library_id, r.folder.as_str(), r.cat_id.as_str()))
            .collect(),
    );
    let guessed = index(
        guesses
            .iter()
            .map(|g| (g.library_id, g.folder.as_str(), g.cat_id.as_str()))
            .collect(),
    );
    sounds
        .iter()
        .map(|s| {
            if s.cat_id.is_some() {
                return s.clone();
            }
            let mut out = s.clone();
            let found = chosen
                .get(&s.library_id)
                .and_then(|f| nearest_in(&s.folder, f))
                .map(|e| (SOURCE, e))
                .or_else(|| {
                    guessed
                        .get(&s.library_id)
                        .and_then(|f| nearest_in(&s.folder, f))
                        .map(|e| (GUESS_SOURCE, e))
                });
            if let Some((source, e)) = found {
                out.category_source = Some(source.into());
                out.cat_id = Some(e.cat_id.clone());
                out.category = Some(e.category.clone());
                out.subcategory = Some(e.subcategory.clone());
            }
            out
        })
        .collect()
}

/// The folder whose rule (or guess) applies to a sound in `folder`, if any.
pub fn rule_folder(folder: &str, folders: &HashSet<String>) -> Option<String> {
    let mut f = folder;
    loop {
        if folders.contains(f) {
            return Some(f.to_string());
        }
        f = &f[..f.rfind('/')?];
    }
}

// MARK: FolderSuggester

/// Bumped when suggestions change, so Earmark's guesses are made again.
pub const SUGGESTER_VERSION: i64 = 2;

#[derive(Clone, Debug, PartialEq)]
pub struct Suggestion {
    pub entry: UcsEntry,
    pub score: f64,
    /// Folder words that matched this entry's name or synonyms.
    pub words: Vec<String>,
    /// Words most of the folder's files share that matched this entry.
    pub file_words: Vec<String>,
    /// The share of the folder's nearest categorised neighbours in this subcategory (0…1).
    pub sound_share: f64,
    /// The words fit other categories as well and the sound doesn't settle it.
    pub is_uncertain: bool,
}

impl Suggestion {
    /// Worth listening to before trusting: uncertain, or nothing but a few similar sounds agree.
    pub fn is_weak(&self) -> bool {
        self.is_uncertain
            || self.words.is_empty() && self.file_words.is_empty() && self.sound_share < 0.3
    }
}

/// Knobs for measuring the suggestions; the app uses `Tuning::default()` (see the Swift file).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tuning {
    pub pack_words: bool,
    pub file_weight: f64,
    pub file_weight_beside_strong_name: f64,
    pub leaf_overrides_parent: bool,
    pub shared_description_weight: f64,
    pub min_file_share: f64,
    pub other_category_last: bool,
    pub sound_coverage: f64,
}

impl Default for Tuning {
    fn default() -> Tuning {
        Tuning {
            pack_words: true,
            file_weight: 0.8,
            file_weight_beside_strong_name: 0.5,
            leaf_overrides_parent: true,
            shared_description_weight: 0.35,
            min_file_share: 0.3,
            other_category_last: true,
            sound_coverage: 0.25,
        }
    }
}

/// Words in folder and file names that say nothing about the content.
const STOP_WORDS: &[&str] = &[
    "the",
    "and",
    "of",
    "a",
    "an",
    "in",
    "on",
    "for",
    "with",
    "by",
    "to",
    "from",
    "up",
    "sfx",
    "fx",
    "sound",
    "sounds",
    "effect",
    "effects",
    "kit",
    "pack",
    "bundle",
    "library",
    "collection",
    "disk",
    "disc",
    "wav",
    "wave",
    "mp",
    "mp3",
    "aif",
    "aiff",
    "aac",
    "flac",
    "stereo",
    "mono",
    "hq",
    "hd",
    "version",
    "tsk",
    "vol",
    "volume",
    "part",
    "free",
    "pro",
    "complete",
    "ultimate",
    "series",
    "edition",
    "merry",
    "xmas",
    "christmas",
    "construction",
    "files",
    "file",
    "folder",
    "new",
    "other",
    "various",
    "loop",
];

/// Words in file names and descriptions that describe how, not what.
const FILE_STOP_WORDS: &[&str] = &[
    "low", "high", "large", "small", "big", "short", "long", "medium", "deep", "fast", "slow",
    "soft", "hard", "heavy", "light", "dark", "bright", "dry", "wet", "close", "far", "near",
    "distant", "single", "key", "reverb", "tail", "empty", "audio", "mastered", "master",
];

fn count(s: &str) -> usize {
    characters(s).len()
}

/// Lowercase, without plural "s" and with no letter three times running ("Braaams" → "braam").
pub fn stem(word: &str) -> String {
    let lower = word.to_lowercase();
    let mut w = String::new();
    let (mut run, mut last): (usize, Option<&str>) = (0, None);
    for c in characters(&lower) {
        run = if Some(c) == last { run + 1 } else { 1 };
        last = Some(c);
        if run <= 2 {
            w.push_str(c);
        }
    }
    let drop_last = |w: &str, k: usize| {
        let cs = characters(w);
        cs[..cs.len() - k].concat()
    };
    if count(&w) > 4 && w.ends_with("ies") {
        w = drop_last(&w, 3) + "y";
    } else if count(&w) > 4
        && ["shes", "ches", "xes", "sses", "zzes"]
            .iter()
            .any(|x| w.ends_with(x))
    {
        w = drop_last(&w, 2);
    } else if count(&w) > 3 && w.ends_with('s') && !w.ends_with("ss") {
        w = drop_last(&w, 1);
    }
    w
}

fn stemmed_stop_words() -> &'static HashSet<String> {
    static SET: OnceLock<HashSet<String>> = OnceLock::new();
    SET.get_or_init(|| STOP_WORDS.iter().map(|w| stem(w)).collect())
}

/// Words as UCS spells them: "StreetBall_HitPad2" → street, ball, hit, pad; "Sci-Fi" and "SCI FI"
/// also give "scifi", "Hi-Tech" "hitech".
pub fn words(text: &str) -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    // Hyphenated words written together ("Coin-Op" → "coinop").
    let mut joined: Vec<String> = Vec::new();
    let mut chunks: Vec<Vec<&str>> = Vec::new();
    let mut chunk: Vec<&str> = Vec::new();
    for c in characters(text) {
        if is_letter(c) || c == "-" {
            chunk.push(c);
        } else if !chunk.is_empty() {
            chunks.push(std::mem::take(&mut chunk));
        }
    }
    if !chunk.is_empty() {
        chunks.push(chunk);
    }
    for chunk in chunks {
        let text: String = chunk.concat();
        let parts: Vec<&str> = text.split('-').filter(|p| !p.is_empty()).collect();
        if parts.len() > 1 {
            joined.push(parts.concat().to_lowercase());
        }
        for part in parts {
            tokens.extend(split_case(part));
        }
    }
    let mut out = Vec::new();
    for (i, t) in tokens.iter().enumerate() {
        out.push(stem(t));
        // "-ies" is "-y" (Batteries) or "-ie" (Zombies, Movies): keep both.
        let lower = t.to_lowercase();
        if count(t) > 4 && lower.ends_with("ies") {
            let cs = characters(&lower);
            out.push(cs[..cs.len() - 1].concat());
        }
        if i > 0 {
            let pair = format!("{}{}", tokens[i - 1], t).to_lowercase();
            if pair == "scifi" || pair == "hitech" {
                out.push(pair);
            }
        }
    }
    out.extend(joined.iter().map(|j| stem(j)));
    out.into_iter()
        .filter(|w| count(w) > 1 && !stemmed_stop_words().contains(w))
        .collect()
}

/// "StreetBall" → Street, Ball; "SFXPack" → SFX, Pack; "BMX" stays.
pub fn split_case(word: &str) -> Vec<String> {
    let chars = characters(word);
    let (mut out, mut current) = (Vec::new(), String::new());
    for (i, c) in chars.iter().enumerate() {
        if i > 0
            && is_uppercase(c)
            && (is_lowercase(chars[i - 1])
                || (is_uppercase(chars[i - 1])
                    && i + 1 < chars.len()
                    && is_lowercase(chars[i + 1])))
        {
            out.push(std::mem::take(&mut current));
        }
        current.push_str(c);
    }
    out.push(current);
    out.into_iter().filter(|w| !w.is_empty()).collect()
}

/// Folder words, the deepest folder's first, without duplicates. The last two folders count
/// fully; above them, half.
pub fn folder_words(folder: &str) -> Vec<(String, f64)> {
    let parts: Vec<&str> = folder.split('/').filter(|p| !p.is_empty()).collect();
    let (mut seen, mut out) = (HashSet::new(), Vec::new());
    for (i, part) in parts.iter().enumerate().rev() {
        let weight = if i + 2 >= parts.len() { 1.0 } else { 0.5 };
        for w in words(part) {
            if seen.insert(w.clone()) {
                out.push((w, weight));
            }
        }
    }
    out
}

/// Words of the designer most of these sounds name: usually the vendor ("BOOM Library").
pub fn pack_words(sounds: &[SoundRecord]) -> HashSet<String> {
    let mut designers: HashMap<&str, usize> = HashMap::new();
    for d in sounds.iter().filter_map(|s| s.designer.as_deref()) {
        *designers.entry(d).or_default() += 1;
    }
    designers
        .into_iter()
        .filter(|(_, c)| 2 * c >= sounds.len())
        .flat_map(|(d, _)| words(d))
        .collect()
}

/// Descriptions shared by sounds in `min_folders` or more folders: a vendor's collection names.
pub fn shared_descriptions(sounds: &[SoundRecord], min_folders: usize) -> HashSet<String> {
    let mut folders: HashMap<&str, HashSet<String>> = HashMap::new();
    for s in sounds {
        if let Some(d) = s.details.as_deref().filter(|d| !d.is_empty()) {
            folders
                .entry(d)
                .or_default()
                .insert(format!("{}|{}", s.library_id, s.folder));
        }
    }
    folders
        .into_iter()
        .filter(|(_, f)| f.len() >= min_folders)
        .map(|(d, _)| d.to_string())
        .collect()
}

/// Words at least `min_file_share` of these sounds have in their file name, FXName, description
/// or keywords, with that share (up to 12, commonest first). Of a UCS file name only the FXName
/// counts: the rest names the vendor and the collection.
pub fn file_words(
    sounds: &[SoundRecord],
    shared_descriptions: &HashSet<String>,
    catalog: &UcsCatalog,
    tuning: &Tuning,
) -> BTreeMap<String, f64> {
    let sample: Vec<&SoundRecord> = if sounds.len() <= 400 {
        sounds.iter().collect()
    } else {
        sounds.iter().step_by(sounds.len() / 400 + 1).collect()
    };
    if sample.is_empty() {
        return BTreeMap::new();
    }
    let mut counts: HashMap<String, f64> = HashMap::new();
    let keep = |w: &String| count(w) > 2 && !FILE_STOP_WORDS.contains(&w.as_str());
    for s in &sample {
        let stem_name = s
            .file_name
            .rfind('.')
            .map_or(s.file_name.as_str(), |i| &s.file_name[..i]);
        let name = catalog
            .parse_filename(stem_name)
            .map_or_else(|| stem_name.to_string(), |p| p.fx_name.unwrap_or_default());
        let mut own: HashSet<String> = [
            name.as_str(),
            s.fx_name.as_deref().unwrap_or(""),
            s.keywords.as_deref().unwrap_or(""),
        ]
        .iter()
        .flat_map(|t| words(t))
        .collect();
        let mut shared: HashSet<String> = HashSet::new();
        if let Some(d) = &s.details {
            if shared_descriptions.contains(d) {
                shared = words(d).into_iter().collect();
            } else {
                own.extend(words(d));
            }
        }
        for w in own.iter().filter(|w| keep(w)) {
            *counts.entry(w.clone()).or_default() += 1.0;
        }
        for w in shared.difference(&own).filter(|w| keep(w)) {
            *counts.entry(w.clone()).or_default() += tuning.shared_description_weight;
        }
    }
    let n = sample.len() as f64;
    let mut common: Vec<(String, f64)> = counts
        .into_iter()
        .filter(|(_, v)| *v >= tuning.min_file_share * n)
        .collect();
    common.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(&b.0))
    });
    common
        .into_iter()
        .take(12)
        .map(|(w, v)| (w, v / n))
        .collect()
}

/// The UCS list indexed by word.
struct Lexicon {
    entries: Vec<LexEntry>,
    by_word: HashMap<String, Vec<usize>>,
    /// Word → category → how many of its subcategories have the word in their name or synonyms.
    subcategory_spread: HashMap<String, HashMap<String, usize>>,
    by_category: HashMap<String, Vec<usize>>,
    /// Words of category names.
    category_words: HashSet<String>,
}

struct LexEntry {
    entry: UcsEntry,
    category: HashSet<String>,
    subcategory: HashSet<String>,
    synonyms: HashSet<String>,
}

impl Lexicon {
    fn new(catalog: &UcsCatalog) -> Lexicon {
        let entries: Vec<LexEntry> = catalog
            .entries
            .iter()
            .map(|e| LexEntry {
                entry: e.clone(),
                category: words(&e.category).into_iter().collect(),
                subcategory: words(&e.subcategory).into_iter().collect(),
                synonyms: e.synonyms.iter().flat_map(|s| words(s)).collect(),
            })
            .collect();
        let mut by_word: HashMap<String, Vec<usize>> = HashMap::new();
        let mut spread: HashMap<String, HashMap<String, usize>> = HashMap::new();
        let mut by_category: HashMap<String, Vec<usize>> = HashMap::new();
        for (i, e) in entries.iter().enumerate() {
            by_category
                .entry(e.entry.category.clone())
                .or_default()
                .push(i);
            let all: HashSet<&String> = e
                .category
                .iter()
                .chain(&e.subcategory)
                .chain(&e.synonyms)
                .collect();
            for w in all {
                by_word.entry(w.clone()).or_default().push(i);
            }
            let sub: HashSet<&String> = e.subcategory.iter().chain(&e.synonyms).collect();
            for w in sub {
                *spread
                    .entry(w.clone())
                    .or_default()
                    .entry(e.entry.category.clone())
                    .or_default() += 1;
            }
        }
        let category_words = entries
            .iter()
            .flat_map(|e| e.category.iter().cloned())
            .collect();
        Lexicon {
            entries,
            by_word,
            subcategory_spread: spread,
            by_category,
            category_words,
        }
    }

    fn shared() -> &'static Lexicon {
        static LEX: OnceLock<Lexicon> = OnceLock::new();
        LEX.get_or_init(|| Lexicon::new(UcsCatalog::shared()))
    }
}

/// A word for or against the folder's category, from its name or its files.
#[derive(Clone)]
struct Evidence {
    word: String,
    weight: f64,
    from_name: bool,
    /// A parent folder's word under its lock: it names a group, not a subcategory.
    group_name: bool,
}

#[derive(Clone, Default)]
struct NameScore {
    score: f64,
    /// The part that comes from the category's name alone.
    category_part: f64,
    words: Vec<String>,
    file_words: Vec<String>,
}

/// Match per CatID, added up per word: category 3, subcategory 2, synonym 1, times the word's
/// weight.
fn scores(evidence: &[Evidence], lexicon: &Lexicon) -> HashMap<String, NameScore> {
    let mut out: HashMap<String, NameScore> = HashMap::new();
    let add = |out: &mut HashMap<String, NameScore>,
               i: usize,
               points: f64,
               category_part: f64,
               ev: &Evidence| {
        let s = out
            .entry(lexicon.entries[i].entry.cat_id.clone())
            .or_default();
        s.score += points * ev.weight;
        s.category_part += category_part * ev.weight;
        let list = if ev.from_name {
            &mut s.words
        } else {
            &mut s.file_words
        };
        if !list.contains(&ev.word) {
            list.push(ev.word.clone());
        }
    };
    for ev in evidence {
        let Some(hits) = lexicon.by_word.get(&ev.word) else {
            continue;
        };
        // Categories where the word is only a synonym-level hint.
        let mut general: BTreeSet<String> = BTreeSet::new();
        for &i in hits {
            let e = &lexicon.entries[i];
            let c = if e.category.contains(&ev.word) {
                3.0
            } else {
                0.0
            };
            let named = if e.subcategory.contains(&ev.word) && !ev.group_name {
                2.0
            } else {
                0.0
            };
            let sub = named
                + if e.synonyms.contains(&ev.word) {
                    1.0
                } else {
                    0.0
                };
            let spread = lexicon
                .subcategory_spread
                .get(&ev.word)
                .and_then(|m| m.get(&e.entry.category))
                .copied()
                .unwrap_or(0);
            // A word in 3+ subcategories of one category says only "this category".
            if spread >= 3 {
                general.insert(e.entry.category.clone());
                if c + named > 0.0 {
                    add(&mut out, i, c + named, c, ev);
                }
            } else {
                add(&mut out, i, c + sub, c, ev);
            }
        }
        for category in &general {
            for &i in lexicon
                .by_category
                .get(category)
                .map(Vec::as_slice)
                .unwrap_or(&[])
            {
                add(&mut out, i, 1.0, 1.0, ev);
            }
        }
    }
    out
}

/// The folder's name alone, per CatID.
pub fn name_scores(folder: &str) -> HashMap<String, (f64, Vec<String>)> {
    let evidence: Vec<Evidence> = folder_words(folder)
        .into_iter()
        .map(|(word, weight)| Evidence {
            word,
            weight,
            from_name: true,
            group_name: false,
        })
        .collect();
    scores(&evidence, Lexicon::shared())
        .into_iter()
        .map(|(k, v)| (k, (v.score, v.words)))
        .collect()
}

/// The categories that came with the files (not the owner's rules or Earmark's guesses).
pub fn labels(sounds: &[SoundRecord]) -> HashMap<i64, String> {
    sounds
        .iter()
        .filter(|s| {
            !matches!(
                s.category_source.as_deref(),
                Some(SOURCE) | Some(GUESS_SOURCE)
            )
        })
        .filter_map(|s| Some((s.id?, s.cat_id.clone()?)))
        .collect()
}

/// The share of categorised neighbours per CatID: for up to `sample` of the folder's sounds, the
/// `k` nearest sounds that have a category (among the 4k nearest), weighted by similarity; shrunk
/// when fewer than `full_at` of those places are found.
pub fn sound_shares(
    sound_ids: &[i64],
    index: &SimilarityIndex,
    labels: &HashMap<i64, String>,
    k: usize,
    sample: usize,
    full_at: f64,
) -> BTreeMap<String, f64> {
    let picked: Vec<i64> = if sound_ids.len() <= sample {
        sound_ids.to_vec()
    } else {
        sound_ids
            .iter()
            .copied()
            .step_by((sound_ids.len() / sample).max(1))
            .collect()
    };
    let own: HashSet<i64> = sound_ids.iter().copied().collect();
    let mut votes: BTreeMap<String, f64> = BTreeMap::new();
    let (mut found, mut places) = (0usize, 0usize);
    for id in picked.into_iter().filter(|id| index.contains(*id)) {
        let near: Vec<(i64, f32)> = index
            .nearest(id, k * 4, &own)
            .into_iter()
            .filter(|n| labels.contains_key(&n.0))
            .take(k)
            .collect();
        for n in &near {
            *votes.entry(labels[&n.0].clone()).or_default() += n.1.max(0.0) as f64;
        }
        found += near.len();
        places += k;
    }
    let total: f64 = votes.values().sum();
    if total <= 0.0 {
        return BTreeMap::new();
    }
    let coverage = if full_at > 0.0 {
        (found as f64 / (full_at * places as f64)).min(1.0)
    } else {
        1.0
    };
    votes
        .into_iter()
        .map(|(c, v)| (c, coverage * v / total))
        .collect()
}

/// `suggest_from` for a folder's sounds as the library has them: with their files' words and
/// designer.
#[allow(clippy::too_many_arguments)]
pub fn suggest(
    folder: &str,
    sounds: &[SoundRecord],
    index: Option<&SimilarityIndex>,
    labels: &HashMap<i64, String>,
    shared_descriptions: &HashSet<String>,
    count: usize,
    tuning: &Tuning,
) -> Vec<Suggestion> {
    let catalog = UcsCatalog::shared();
    suggest_from(
        folder,
        &sounds.iter().filter_map(|s| s.id).collect::<Vec<_>>(),
        index,
        labels,
        &file_words(sounds, shared_descriptions, catalog, tuning),
        &pack_words(sounds),
        count,
        tuning,
    )
}

/// Up to `count` options, best first. Name, files and sound are combined; a name that only gives
/// the category lets the sound pick the subcategory.
#[allow(clippy::too_many_arguments)]
pub fn suggest_from(
    folder: &str,
    sound_ids: &[i64],
    index: Option<&SimilarityIndex>,
    labels: &HashMap<i64, String>,
    file_words: &BTreeMap<String, f64>,
    pack_words: &HashSet<String>,
    count: usize,
    tuning: &Tuning,
) -> Vec<Suggestion> {
    let catalog = UcsCatalog::shared();
    let lexicon = Lexicon::shared();
    let entry = |id: &str| catalog.entry_by_cat_id(Some(id));
    let all_shares = index
        .map(|i| sound_shares(sound_ids, i, labels, 10, 40, tuning.sound_coverage))
        .unwrap_or_default();
    let mut category_share: HashMap<String, f64> = HashMap::new();
    for (cat_id, s) in &all_shares {
        if let Some(e) = entry(cat_id) {
            *category_share.entry(e.category.clone()).or_default() += s;
        }
    }
    // Vendor and pack names: the designer's, and the top folder's when the folder is deeper.
    let parts: Vec<&str> = folder.split('/').filter(|p| !p.is_empty()).collect();
    let mut pack: HashSet<String> = if tuning.pack_words {
        pack_words.clone()
    } else {
        HashSet::new()
    };
    if tuning.pack_words && parts.len() >= 3 {
        pack.extend(words(parts[0]));
    }
    let sound_agrees = |word: &str| {
        lexicon.by_word.get(word).is_some_and(|hits| {
            hits.iter().any(|&i| {
                let e = &lexicon.entries[i];
                all_shares.get(&e.entry.cat_id).copied().unwrap_or(0.0) >= 0.1
                    || e.category.contains(word)
                        && category_share
                            .get(&e.entry.category)
                            .copied()
                            .unwrap_or(0.0)
                            >= 0.25
            })
        })
    };
    // A parent folder that names one UCS category decides the category.
    let mut locked: Option<String> = None;
    if parts.len() >= 2 {
        let named = |ws: &HashSet<String>| -> BTreeSet<String> {
            let ws: HashSet<&String> = ws.iter().filter(|w| !pack.contains(*w)).collect();
            lexicon
                .entries
                .iter()
                .filter(|e| e.category.iter().any(|c| ws.contains(c)))
                .map(|e| e.entry.category.clone())
                .collect()
        };
        let parent_words: HashSet<String> = words(parts[parts.len() - 2])
            .into_iter()
            .filter(|w| !pack.contains(w))
            .collect();
        let parent = named(&parent_words);
        if parent.len() == 1 {
            let category = parent.iter().next().unwrap().clone();
            let own_name: HashSet<String> = catalog
                .subcategories(&category)
                .first()
                .map(|e| words(&e.category).into_iter().collect())
                .unwrap_or_default();
            let loose = parent_words
                .difference(&own_name)
                .any(|w| lexicon.by_word.contains_key(w));
            let leaf = named(&words(parts[parts.len() - 1]).into_iter().collect());
            let files: HashSet<&String> = file_words
                .iter()
                .filter(|(_, v)| **v >= 0.5)
                .map(|(k, _)| k)
                .filter(|w| !lexicon.category_words.contains(*w))
                .collect();
            let files_elsewhere: Vec<&String> = lexicon
                .entries
                .iter()
                .filter(|e| e.subcategory.iter().any(|s| files.contains(s)))
                .map(|e| &e.entry.category)
                .collect();
            let released = tuning.leaf_overrides_parent
                && (leaf.contains(&category) && leaf.len() >= 2
                    || loose
                        && !files_elsewhere.is_empty()
                        && !files_elsewhere.contains(&&category));
            if !released {
                locked = Some(category);
            }
        }
    }
    // Under a lock the parent's words name a group.
    let parent_only: HashSet<String> = if parts.len() >= 2 && locked.is_some() {
        let leaf: HashSet<String> = words(parts[parts.len() - 1]).into_iter().collect();
        words(parts[parts.len() - 2])
            .into_iter()
            .filter(|w| !leaf.contains(w))
            .collect()
    } else {
        HashSet::new()
    };
    let mut evidence: Vec<Evidence> = folder_words(folder)
        .into_iter()
        .map(|(word, weight)| {
            let group_name = parent_only.contains(&word);
            Evidence {
                word,
                weight,
                from_name: true,
                group_name,
            }
        })
        .collect();
    evidence.retain(|e| !(pack.contains(&e.word) && !sound_agrees(&e.word)));
    // The files' words decide when the name is vague; beside a strong name they count less.
    let strong_name = scores(&evidence, lexicon).values().any(|s| s.score >= 2.0);
    let file_weight = tuning.file_weight
        * if strong_name {
            tuning.file_weight_beside_strong_name
        } else {
            1.0
        };
    let mut sorted_files: Vec<(&String, &f64)> = file_words.iter().collect();
    sorted_files.sort_by(|a, b| {
        b.1.partial_cmp(a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(b.0))
    });
    evidence.extend(
        sorted_files
            .into_iter()
            .filter(|(w, _)| !pack.contains(*w) || sound_agrees(w))
            .map(|(w, v)| Evidence {
                word: w.clone(),
                weight: file_weight * v,
                from_name: false,
                group_name: false,
            }),
    );
    let detailed = scores(&evidence, lexicon);
    // Under 10% of neighbours in one subcategory is noise, not evidence for it.
    let shares: BTreeMap<&String, f64> = all_shares
        .iter()
        .filter(|(_, v)| **v >= 0.1)
        .map(|(k, v)| (k, *v))
        .collect();
    let max_name = detailed.values().map(|s| s.score).fold(0.0, f64::max);
    let mut candidates: BTreeSet<String> = detailed
        .keys()
        .cloned()
        .chain(shares.keys().map(|k| (*k).clone()))
        .collect();
    if candidates.is_empty() {
        return vec![];
    }
    // Every subcategory of a category the name points to can be chosen by sound.
    for cat_id in detailed.keys() {
        if let Some(e) = entry(cat_id) {
            for sub in catalog.subcategories(&e.category) {
                candidates.insert(sub.cat_id.clone());
            }
        }
    }
    if let Some(l) = &locked {
        candidates = catalog
            .subcategories(l)
            .iter()
            .map(|e| e.cat_id.clone())
            .collect();
    }
    // UCS's category for production material, not for libraries.
    candidates.retain(|c| entry(c).is_some_and(|e| e.category != "ARCHIVED"));
    let mut best_in_category: HashMap<String, f64> = HashMap::new();
    for (cat_id, s) in &detailed {
        if let Some(e) = entry(cat_id) {
            let b = best_in_category.entry(e.category.clone()).or_insert(0.0);
            *b = b.max(s.score);
        }
    }
    // Sound counts more when it clearly points one way.
    let sound_weight = 1.0 + 2.5 * (shares.values().copied().fold(0.0, f64::max) - 0.4).max(0.0);
    let empty = NameScore::default();
    let mut options: Vec<Suggestion> = Vec::new();
    for cat_id in &candidates {
        let Some(e) = entry(cat_id) else { continue };
        let d = detailed.get(cat_id).unwrap_or(&empty);
        let name = if max_name > 0.0 {
            d.score / max_name
        } else {
            0.0
        };
        let category_name = if max_name > 0.0 {
            best_in_category.get(&e.category).copied().unwrap_or(0.0) / max_name
        } else {
            0.0
        };
        let share = shares.get(cat_id).copied().unwrap_or(0.0);
        let mut score = 0.35 * name
            + 0.25 * category_name
            + sound_weight
                * (0.25 * share + 0.15 * category_share.get(&e.category).copied().unwrap_or(0.0));
        if locked.is_some() {
            score += 0.5 * (d.score - d.category_part) / max_name.max(1.0);
        }
        options.push(Suggestion {
            entry: e.clone(),
            score,
            words: d.words.clone(),
            file_words: d.file_words.clone(),
            sound_share: share,
            is_uncertain: false,
        });
    }
    // With nothing pointing to one subcategory over the others, MISC (or GENERAL) is the honest
    // choice; otherwise a specific subcategory beats it.
    let top = options
        .iter()
        .fold(None::<&Suggestion>, |best, o| match best {
            Some(b) if b.score.partial_cmp(&o.score) != Some(std::cmp::Ordering::Less) => Some(b),
            _ => Some(o),
        });
    if let Some(top) = top.cloned() {
        let specific = options
            .iter()
            .filter(|o| o.entry.category == top.entry.category && o.score >= top.score - 1e-9)
            .any(|o| {
                o.sound_share >= 0.1
                    || detailed
                        .get(&o.entry.cat_id)
                        .map_or(0.0, |d| d.score - d.category_part)
                        > 0.0
            });
        for o in options.iter_mut() {
            if o.entry.category == top.entry.category
                && ["MISC", "GENERAL"].contains(&o.entry.subcategory.as_str())
            {
                o.score += if specific { -0.001 } else { 0.001 };
            }
        }
    }
    let mut ranked = options;
    ranked.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(
                b.sound_share
                    .partial_cmp(&a.sound_share)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
            .then(a.entry.cat_id.cmp(&b.entry.cat_id))
    });
    // Uncertain: an option in another category is named just as well, and the sound doesn't settle it.
    if let Some(top) = ranked.first().cloned()
        && let Some(top_name) = detailed
            .get(&top.entry.cat_id)
            .map(|d| d.score)
            .filter(|s| *s > 0.0)
        && top.sound_share < 0.3
    {
        ranked[0].is_uncertain = ranked[1..].iter().any(|o| {
            o.entry.category != top.entry.category
                && detailed.get(&o.entry.cat_id).map_or(0.0, |d| d.score) >= top_name - 1e-9
        });
    }
    // When the first options all share a category, the last place offers the best of another.
    if tuning.other_category_last && count >= 3 && ranked.len() > count {
        let first = ranked[0].entry.category.clone();
        if ranked[..count].iter().all(|o| o.entry.category == first)
            && let Some(other) = ranked.iter().position(|o| o.entry.category != first)
        {
            let alternative = ranked.remove(other);
            ranked.insert(count - 1, alternative);
        }
    }
    ranked.truncate(count);
    ranked
}
