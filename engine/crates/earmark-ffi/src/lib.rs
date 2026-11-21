//! The engine as the Mac app calls it (docs/rust-engine-plan.md, step 8). UniFFI writes the
//! Swift side from these declarations (scripts/build-engine.sh), so the two can't drift apart.
//!
//! Records with many fields cross as JSON in the shape Swift's `Codable` types already read
//! (the parity checks compare exactly that JSON), so the app keeps its own types.

use earmark_core::analysis::{
    categories, duplicates, folder_rules, groups, loudness, similarity, sound_map,
};
use earmark_core::metadata::AudioTechnical;
use earmark_core::records::SoundRecord;
use earmark_core::scan;
use earmark_core::timeline_file;
use earmark_core::ucs::UcsCatalog;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

mod database;
pub use database::*;

uniffi::setup_scaffolding!();

/// A file's length and format, for the files the engine's reader can't parse (MP3, AAC…).
#[derive(uniffi::Record)]
pub struct Technical {
    pub sample_rate: Option<f64>,
    pub channels: Option<i64>,
    pub bits_per_sample: Option<i64>,
    pub duration: Option<f64>,
}

impl From<Technical> for AudioTechnical {
    fn from(t: Technical) -> AudioTechnical {
        AudioTechnical {
            sample_rate: t.sample_rate,
            channels: t.channels,
            bits_per_sample: t.bits_per_sample,
            duration: t.duration,
        }
    }
}

/// What the app gives a scan: progress as files complete, and its own reader (AVFoundation)
/// for the files the engine can't read the length of.
#[uniffi::export(with_foreign)]
pub trait ScanListener: Send + Sync {
    fn progress(&self, done: u64, total: u64);
    fn technical(&self, path: String) -> Option<Technical>;
}

/// Reads every sound file under `root`, on `parallelism` threads, and never writes. The
/// answer is a JSON array of Swift's `ScannedSound`, sorted by path, with `modified` in seconds
/// since 1970 and, when known, the same time as `modifiedSeconds` and `modifiedNanos`.
#[uniffi::export]
pub fn scan_sounds(root: String, parallelism: u32, listener: Arc<dyn ScanListener>) -> String {
    // The engine's reader type wants a closure that owns what it uses.
    let reader = listener.clone();
    let fallback = move |path: &Path| {
        reader
            .technical(path.to_string_lossy().into_owned())
            .map(AudioTechnical::from)
    };
    let progress = |done: usize, total: usize| listener.progress(done as u64, total as u64);
    let found = scan::scan(
        Path::new(&root),
        UcsCatalog::shared(),
        parallelism as usize,
        Some(&fallback),
        &progress,
    );
    let rows: Vec<serde_json::Value> = found
        .iter()
        .map(|sound| {
            let mut row = serde_json::to_value(sound).unwrap_or_default();
            if let (Some((seconds, nanos)), Some(fields)) =
                (sound.modified_parts, row.as_object_mut())
            {
                fields.insert("modifiedSeconds".into(), seconds.into());
                fields.insert("modifiedNanos".into(), nanos.into());
            }
            row
        })
        .collect();
    serde_json::to_string(&rows).unwrap_or_else(|_| "[]".into())
}

/// A song's tags and length, as the app's reader (AVFoundation) finds them.
#[derive(uniffi::Record, Default)]
pub struct SongTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration: Option<f64>,
}

/// A song file as found on disk (never changed), with its tags. `modified_seconds` and
/// `modified_nanos` are the file system's time since 1970, absent when unknown.
#[derive(uniffi::Record)]
pub struct FoundSong {
    pub path: String,
    pub file_size: i64,
    pub modified_seconds: Option<i64>,
    pub modified_nanos: Option<u32>,
    pub tags: SongTags,
}

/// What the app gives a music scan: progress as files complete, and its reader for tags.
#[uniffi::export(with_foreign)]
pub trait SongListener: Send + Sync {
    fn progress(&self, done: u64, total: u64);
    fn tags(&self, path: String) -> SongTags;
}

/// Reads every song under `root` on `parallelism` threads, as the app's music reader does:
/// the same files in the same order (by path), with size and date from the file system and
/// tags from `listener`. Never writes.
#[uniffi::export]
pub fn read_songs(
    root: String,
    parallelism: u32,
    listener: Arc<dyn SongListener>,
) -> Vec<FoundSong> {
    let files = scan::list_audio_files(Path::new(&root));
    let next = AtomicUsize::new(0);
    let found = Mutex::new(Vec::with_capacity(files.len()));
    std::thread::scope(|s| {
        for _ in 0..(parallelism.max(1) as usize).min(files.len().max(1)) {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(path) = files.get(i) else { break };
                    let song = song_file(path, listener.as_ref());
                    let done = {
                        let mut found = found.lock().unwrap();
                        found.push(song);
                        found.len()
                    };
                    listener.progress(done as u64, files.len() as u64);
                }
            });
        }
    });
    let mut out = found.into_inner().unwrap();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

fn song_file(path: &Path, listener: &dyn SongListener) -> FoundSong {
    let meta = std::fs::metadata(path).ok();
    let since_1970 = meta
        .as_ref()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok());
    let path = path.to_string_lossy().into_owned();
    FoundSong {
        file_size: meta.map_or(0, |m| m.len() as i64),
        modified_seconds: since_1970.map(|d| d.as_secs() as i64),
        modified_nanos: since_1970.map(|d| d.subsec_nanos()),
        tags: listener.tags(path.clone()),
        path,
    }
}

/// What the app gives a long piece of maths: progress (0…1) and whether to stop. Called from the
/// engine's threads.
#[uniffi::export(with_foreign)]
pub trait WorkListener: Send + Sync {
    fn progress(&self, fraction: f64);
    fn is_cancelled(&self) -> bool;
}

/// A sound map: `points` as x, y pairs (0…1), `links` as pairs of row numbers.
#[derive(uniffi::Record)]
pub struct SoundMapLayout {
    pub points: Vec<f32>,
    pub links: Vec<i32>,
}

/// The app's rows of floats where they are in its memory: `address` of `count` rows of
/// `dimensions` floats, which the app keeps alive and unchanged until the call returns.
///
/// The engine reads them in place rather than copied, for two reasons: a library's map is about
/// 29,000 × 1,536 floats (177 MB), and the Mac's sums (vDSP) depend on where the matrix sits in
/// memory, so the same page-aligned buffer the app made gives the same results to the bit.
///
/// # Safety
/// `address` must point to `count × dimensions` readable floats for the whole call.
unsafe fn rows<'a>(address: u64, count: u32, dimensions: u32) -> &'a [f32] {
    let len = count as usize * dimensions as usize;
    if len == 0 || address == 0 {
        return &[];
    }
    unsafe { std::slice::from_raw_parts(address as usize as *const f32, len) }
}

/// The sound map of `count` unit-length rows (as Swift's `SoundMap.map` with its defaults, three
/// links per sound). None if cancelled. The rows are read in place (see `rows`).
#[uniffi::export]
pub fn sound_map(
    address: u64,
    count: u32,
    dimensions: u32,
    listener: Arc<dyn WorkListener>,
) -> Option<SoundMapLayout> {
    let x = unsafe { rows(address, count, dimensions) };
    let map = sound_map::map(
        x,
        count as usize,
        dimensions as usize,
        &sound_map::Settings::default(),
        3,
        &|f| listener.progress(f),
        &|| listener.is_cancelled(),
    )?;
    Some(SoundMapLayout {
        points: map.points.iter().flat_map(|p| *p).collect(),
        links: map.links.iter().flat_map(|l| *l).collect(),
    })
}

/// A group per row (0 for the largest), as Swift's `SoundGroups.cluster`. None if cancelled.
/// The rows are read in place (see `rows`).
#[uniffi::export]
pub fn cluster_sounds(
    address: u64,
    count: u32,
    dimensions: u32,
    listener: Arc<dyn WorkListener>,
) -> Option<Vec<u32>> {
    let x = unsafe { rows(address, count, dimensions) };
    let labels = groups::cluster(x, count as usize, dimensions as usize, &|| {
        listener.is_cancelled()
    })?;
    Some(labels.into_iter().map(|g| g as u32).collect())
}

/// One sound, for naming groups: its length and its words (file name, FX name, description,
/// keywords), as Swift's `SoundGroups.Member`.
#[derive(uniffi::Record)]
pub struct GroupMember {
    pub duration: Option<f64>,
    pub text: String,
}

/// What a group is called and the words behind it, as Swift's `SoundGroups.Name`.
#[derive(uniffi::Record)]
pub struct GroupName {
    pub name: String,
    pub ai_words: Vec<String>,
    pub shape_words: Vec<String>,
    pub keywords: Vec<String>,
}

/// Names for a set's groups, as Swift's `SoundGroups.names`: `groups` are each group's rows of
/// the `count` rows read in place (see `rows`).
#[uniffi::export]
pub fn group_names(
    groups: Vec<Vec<u32>>,
    address: u64,
    count: u32,
    dimensions: u32,
    members: Vec<GroupMember>,
    library_mean: Vec<f32>,
    exclude: Vec<String>,
) -> Vec<GroupName> {
    let x = unsafe { rows(address, count, dimensions) };
    let groups: Vec<Vec<usize>> = groups
        .into_iter()
        .map(|g| g.into_iter().map(|r| r as usize).collect())
        .collect();
    let members: Vec<groups::Member> = members
        .into_iter()
        .map(|m| groups::Member {
            duration: m.duration,
            text: m.text,
        })
        .collect();
    let exclude: HashSet<String> = exclude.into_iter().collect();
    groups::names(
        &groups,
        x,
        dimensions as usize,
        &members,
        &library_mean,
        &exclude,
    )
    .into_iter()
    .map(|n| GroupName {
        name: n.name,
        ai_words: n.ai_words,
        shape_words: n.shape_words,
        keywords: n.keywords,
    })
    .collect()
}

/// A sound near another and how near (cosine similarity, -1…1).
#[derive(uniffi::Record)]
pub struct Neighbour {
    pub id: i64,
    pub score: f32,
}

/// Find Similar's index, as Swift's `SimilarityIndex`: one vector per sound (unit length), a
/// dot product against every row per question.
#[derive(uniffi::Object)]
pub struct SoundIndex {
    index: similarity::SimilarityIndex,
}

#[uniffi::export]
impl SoundIndex {
    /// `flat`: the sounds' vectors one after another, `dimensions` floats each, in `ids` order.
    #[uniffi::constructor]
    pub fn new(ids: Vec<i64>, flat: Vec<f32>, dimensions: u32) -> Arc<SoundIndex> {
        let d = dimensions as usize;
        let vectors: Vec<(i64, Vec<f32>)> = if d == 0 {
            vec![]
        } else {
            ids.into_iter()
                .zip(flat.chunks_exact(d))
                .map(|(id, v)| (id, v.to_vec()))
                .collect()
        };
        Arc::new(SoundIndex {
            index: similarity::SimilarityIndex::new(&vectors),
        })
    }

    pub fn count(&self) -> u64 {
        self.index.len() as u64
    }

    pub fn contains(&self, id: i64) -> bool {
        self.index.contains(id)
    }

    /// The `count` most similar sounds to `id`, best first, without it and `excluding`.
    pub fn nearest(&self, id: i64, count: u32, excluding: Vec<i64>) -> Vec<Neighbour> {
        let excluding: HashSet<i64> = excluding.into_iter().collect();
        self.index
            .nearest(id, count as usize, &excluding)
            .into_iter()
            .map(|(id, score)| Neighbour { id, score })
            .collect()
    }
}

/// Each row's `k` nearest rows (itself included, nearest first) and their cosine distances,
/// flat (count × k), as Swift's `SoundMap.nearestNeighbours`.
#[derive(uniffi::Record)]
pub struct NearestRows {
    pub indices: Vec<u32>,
    pub distances: Vec<f32>,
}

/// The neighbour search behind Earmark's guesses and near duplicates. The rows are read in
/// place (see `rows`).
#[uniffi::export]
pub fn nearest_rows(address: u64, count: u32, dimensions: u32, k: u32) -> NearestRows {
    let x = unsafe { rows(address, count, dimensions) };
    let (indices, distances) = sound_map::neighbours(
        x,
        count as usize,
        dimensions as usize,
        k as usize,
        &|_| {},
        &|| false,
    )
    .unwrap_or_default();
    NearestRows {
        indices: indices.into_iter().map(|i| i as u32).collect(),
        distances,
    }
}

/// Two sounds that are one recording, as Swift's `Duplicates.Pair` (`a` the lower id).
#[derive(uniffi::Record)]
pub struct DuplicatePair {
    pub a: i64,
    pub b: i64,
    pub identical: bool,
    pub similarity: f32,
}

impl From<duplicates::Pair> for DuplicatePair {
    fn from(p: duplicates::Pair) -> DuplicatePair {
        DuplicatePair {
            a: p.a,
            b: p.b,
            identical: p.identical,
            similarity: p.similarity,
        }
    }
}

/// A sound's id and file fingerprint, for byte-identical copies.
#[derive(uniffi::Record)]
pub struct SoundPrint {
    pub id: i64,
    pub fingerprint: Option<String>,
}

/// Byte-identical copies (the same fingerprint), hidden format twins left out, as Swift's
/// `Duplicates.identicalPairs` (the pairs in the order the fingerprints first appear).
#[uniffi::export]
pub fn identical_pairs(sounds: Vec<SoundPrint>, hidden: Vec<i64>) -> Vec<DuplicatePair> {
    let sounds: Vec<(i64, Option<String>)> =
        sounds.into_iter().map(|s| (s.id, s.fingerprint)).collect();
    let hidden: HashSet<i64> = hidden.into_iter().collect();
    duplicates::identical_pairs(&sounds, &hidden)
        .into_iter()
        .map(DuplicatePair::from)
        .collect()
}

/// The same recording from a neighbour search (`nearest_rows`, k per row), as Swift's
/// `Duplicates.nearPairs`.
#[uniffi::export]
pub fn near_duplicate_pairs(
    ids: Vec<i64>,
    durations: Vec<Option<f64>>,
    indices: Vec<u32>,
    distances: Vec<f32>,
    k: u32,
) -> Vec<DuplicatePair> {
    let indices: Vec<usize> = indices.into_iter().map(|i| i as usize).collect();
    duplicates::near_pairs(&ids, &durations, &indices, &distances, k as usize)
        .into_iter()
        .map(DuplicatePair::from)
        .collect()
}

/// One sound another is the same as, and how.
#[derive(uniffi::Record)]
pub struct DuplicateOther {
    pub id: i64,
    pub identical: bool,
    pub similarity: f32,
}

/// Sounds joined into sets, as Swift's `Duplicates.Sets`.
#[derive(uniffi::Record)]
pub struct DuplicateSets {
    pub set_of: HashMap<i64, u32>,
    pub members: Vec<Vec<i64>>,
    pub others: HashMap<i64, Vec<DuplicateOther>>,
}

#[uniffi::export]
pub fn duplicate_sets(pairs: Vec<DuplicatePair>) -> DuplicateSets {
    let pairs: Vec<duplicates::Pair> = pairs
        .into_iter()
        .map(|p| duplicates::Pair::new(p.a, p.b, p.identical, p.similarity))
        .collect();
    let sets = duplicates::sets(&pairs);
    DuplicateSets {
        set_of: sets
            .set_of
            .into_iter()
            .map(|(id, s)| (id, s as u32))
            .collect(),
        members: sets.members,
        others: sets
            .others
            .into_iter()
            .map(|(id, list)| {
                let list = list
                    .into_iter()
                    .map(|(id, identical, similarity)| DuplicateOther {
                        id,
                        identical,
                        similarity,
                    })
                    .collect();
                (id, list)
            })
            .collect(),
    }
}

/// A sound's fields that categories and folder guesses read, as in Swift's `SoundRecord`.
#[derive(uniffi::Record)]
pub struct SoundFields {
    pub id: Option<i64>,
    pub library_id: i64,
    pub path: String,
    pub file_name: String,
    pub folder: String,
    pub fingerprint: Option<String>,
    pub duration: Option<f64>,
    pub fx_name: Option<String>,
    pub details: Option<String>,
    pub keywords: Option<String>,
    pub vendor_library: Option<String>,
    pub manufacturer: Option<String>,
    pub designer: Option<String>,
    pub cat_id: Option<String>,
    pub category: Option<String>,
    pub subcategory: Option<String>,
    pub category_source: Option<String>,
}

impl From<SoundFields> for SoundRecord {
    fn from(s: SoundFields) -> SoundRecord {
        SoundRecord {
            id: s.id,
            library_id: s.library_id,
            path: s.path,
            file_name: s.file_name,
            folder: s.folder,
            file_size: 0,
            modified_at: String::new(),
            fingerprint: s.fingerprint,
            duration: s.duration,
            sample_rate: None,
            channels: None,
            bits_per_sample: None,
            fx_name: s.fx_name,
            details: s.details,
            keywords: s.keywords,
            vendor_library: s.vendor_library,
            manufacturer: s.manufacturer,
            designer: s.designer,
            cat_id: s.cat_id,
            category: s.category,
            subcategory: s.subcategory,
            category_source: s.category_source,
        }
    }
}

fn records(sounds: Vec<SoundFields>) -> Vec<SoundRecord> {
    sounds.into_iter().map(SoundRecord::from).collect()
}

/// A category's share of a sound's neighbours' vote, as Swift's `CategoryVotes.Vote`.
#[derive(uniffi::Record)]
pub struct CategoryVote {
    pub cat_id: String,
    pub share: f64,
}

/// Each row's top 3 categories by its neighbours' vote, from a neighbour search (`nearest_rows`,
/// k per row), as Swift's `CategoryVotes.votes(indices:…)`.
#[uniffi::export]
pub fn category_votes(
    indices: Vec<u32>,
    distances: Vec<f32>,
    k: u32,
    labels: Vec<Option<String>>,
    folders: Vec<String>,
    voters: u32,
) -> Vec<Vec<CategoryVote>> {
    let indices: Vec<usize> = indices.into_iter().map(|i| i as usize).collect();
    categories::votes_from(
        &indices,
        &distances,
        k as usize,
        &labels,
        &folders,
        voters as usize,
    )
    .into_iter()
    .map(|row| {
        row.into_iter()
            .map(|v| CategoryVote {
                cat_id: v.cat_id,
                share: v.share,
            })
            .collect()
    })
    .collect()
}

/// Earmark's guess for one sound, from its neighbours' vote.
#[derive(uniffi::Record)]
pub struct SoundGuess {
    pub sound_id: i64,
    pub fingerprint: Option<String>,
    pub cat_id: String,
    pub share: Option<f64>,
    pub replaced: Option<String>,
}

/// Earmark's guesses from the votes, as Swift's `SoundCategories.guesses`: `alternatives` are
/// each sound's folder guess's runners-up.
#[uniffi::export]
pub fn sound_guesses(
    sounds: Vec<SoundFields>,
    votes: Vec<Vec<CategoryVote>>,
    alternatives: Vec<Vec<String>>,
    strong: f64,
    weak: f64,
) -> Vec<SoundGuess> {
    let sounds = records(sounds);
    let votes: Vec<Vec<categories::Vote>> = votes
        .into_iter()
        .map(|row| {
            row.into_iter()
                .map(|v| categories::Vote {
                    cat_id: v.cat_id,
                    share: v.share,
                })
                .collect()
        })
        .collect();
    let by_id: HashMap<i64, HashSet<String>> = sounds
        .iter()
        .zip(alternatives)
        .filter_map(|(s, a)| s.id.map(|id| (id, a.into_iter().collect())))
        .collect();
    let empty = HashSet::new();
    let alternatives =
        |s: &SoundRecord| s.id.and_then(|id| by_id.get(&id)).unwrap_or(&empty).clone();
    categories::guesses(&sounds, &votes, &alternatives, strong, weak, "")
        .into_iter()
        .map(|c| SoundGuess {
            sound_id: c.sound_id,
            fingerprint: c.fingerprint,
            cat_id: c.cat_id,
            share: c.share,
            replaced: c.replaced,
        })
        .collect()
}

/// One category Earmark suggests for a folder, as Swift's `FolderSuggester.Option`.
#[derive(uniffi::Record)]
pub struct FolderOption {
    pub cat_id: String,
    pub score: f64,
    pub words: Vec<String>,
    pub file_words: Vec<String>,
    pub sound_share: f64,
    pub is_uncertain: bool,
}

/// Up to `count` categories for a folder, best first, as Swift's `FolderSuggester.suggest`:
/// from its name, its files' words and, with `index`, its sounds' categorised neighbours.
#[uniffi::export]
pub fn folder_suggestions(
    folder: String,
    sounds: Vec<SoundFields>,
    index: Option<Arc<SoundIndex>>,
    labels: HashMap<i64, String>,
    shared_descriptions: Vec<String>,
    count: u32,
) -> Vec<FolderOption> {
    let sounds = records(sounds);
    let shared: HashSet<String> = shared_descriptions.into_iter().collect();
    folder_rules::suggest(
        &folder,
        &sounds,
        index.as_ref().map(|i| &i.index),
        &labels,
        &shared,
        count as usize,
        &folder_rules::Tuning::default(),
    )
    .into_iter()
    .map(|o| FolderOption {
        cat_id: o.entry.cat_id,
        score: o.score,
        words: o.words,
        file_words: o.file_words,
        sound_share: o.sound_share,
        is_uncertain: o.is_uncertain,
    })
    .collect()
}

/// The categories that came with the files, as Swift's `FolderSuggester.labels`.
#[uniffi::export]
pub fn folder_labels(sounds: Vec<SoundFields>) -> HashMap<i64, String> {
    folder_rules::labels(&records(sounds))
}

/// Descriptions shared by files in at least `min_folders` folders, as Swift's
/// `FolderSuggester.sharedDescriptions`.
#[uniffi::export]
pub fn shared_descriptions(sounds: Vec<SoundFields>, min_folders: u32) -> Vec<String> {
    folder_rules::shared_descriptions(&records(sounds), min_folders as usize)
        .into_iter()
        .collect()
}

/// A sound's integrated loudness (LUFS) and sample peak (dBFS); None for digital silence.
#[derive(uniffi::Record)]
pub struct Loudness {
    pub integrated: Option<f64>,
    pub peak: Option<f64>,
}

/// Swift's `LoudnessMeter` through the engine: fed decoded audio in chunks, so long files are
/// never held in memory.
#[derive(uniffi::Object)]
pub struct LoudnessMeasure {
    meter: Mutex<loudness::LoudnessMeter>,
}

#[uniffi::export]
impl LoudnessMeasure {
    #[uniffi::constructor]
    pub fn new(sample_rate: f64, channels: u32) -> Arc<LoudnessMeasure> {
        Arc::new(LoudnessMeasure {
            meter: Mutex::new(loudness::LoudnessMeter::new(sample_rate, channels as usize)),
        })
    }

    /// `frames` frames of deinterleaved float audio: one address per channel, each of `frames`
    /// floats, which the app keeps alive and unchanged until the call returns (read in place,
    /// as `rows`: a copy across the bridge cost more than the measuring).
    pub fn process(&self, channels: Vec<u64>, frames: u32) {
        let slices: Vec<&[f32]> = channels
            .iter()
            .map(|&a| unsafe { rows(a, 1, frames) })
            .collect();
        if let Ok(mut meter) = self.meter.lock() {
            meter.process(&slices, frames as usize);
        }
    }

    pub fn result(&self) -> Loudness {
        let r = self.meter.lock().map(|m| m.result()).unwrap_or_default();
        Loudness {
            integrated: r.integrated,
            peak: r.peak,
        }
    }
}

/// One sound to place in a timeline file, as Swift's `TimelineFile.Clip`.
#[derive(uniffi::Record)]
pub struct TimelineClip {
    pub path: String,
    pub name: String,
    pub length: f64,
    pub sample_rate: i64,
    pub channels: i64,
    pub time_reference: i64,
    pub start: Option<f64>,
    pub end: Option<f64>,
    pub at: Option<f64>,
}

/// Where a clip went: its lane and its timeline timecodes.
#[derive(uniffi::Record)]
pub struct TimelinePlacement {
    pub lane: i64,
    pub start: String,
    pub end: String,
}

/// A timeline file's text and where each clip went.
#[derive(uniffi::Record)]
pub struct TimelineText {
    pub xml: String,
    pub placements: Vec<TimelinePlacement>,
}

/// Why a timeline file couldn't be made, as Swift's `TimelineFile.Failure`.
#[derive(Debug, uniffi::Error)]
pub enum TimelineError {
    BadTimecode { timecode: String },
    TooShort { name: String },
    Nothing,
    UnknownRate { rate: String },
}

impl std::fmt::Display for TimelineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TimelineError::BadTimecode { timecode } => {
                timeline_file::Failure::BadTimecode(timecode.clone()).fmt(f)
            }
            TimelineError::TooShort { name } => {
                timeline_file::Failure::TooShort(name.clone()).fmt(f)
            }
            TimelineError::Nothing => timeline_file::Failure::Nothing.fmt(f),
            TimelineError::UnknownRate { rate } => {
                write!(f, "“{rate}” isn't a frame rate Earmark knows.")
            }
        }
    }
}

/// The FCPXML timeline file for `clips` at the frame rate named `rate` ("25", "29.97 DF"…), as
/// Swift's `TimelineFile.fcpxml`.
#[uniffi::export]
pub fn timeline_fcpxml(
    clips: Vec<TimelineClip>,
    rate: String,
    start_timecode: String,
    name: String,
) -> Result<TimelineText, TimelineError> {
    let found = timeline_file::Rate::named(&rate).ok_or(TimelineError::UnknownRate { rate })?;
    let clips: Vec<timeline_file::Clip> = clips
        .into_iter()
        .map(|c| timeline_file::Clip {
            path: c.path,
            name: c.name,
            length: c.length,
            sample_rate: c.sample_rate,
            channels: c.channels,
            time_reference: c.time_reference,
            start: c.start,
            end: c.end,
            at: c.at,
        })
        .collect();
    let (xml, placements) =
        timeline_file::fcpxml(&clips, &found, &start_timecode, &name).map_err(|e| match e {
            timeline_file::Failure::BadTimecode(timecode) => {
                TimelineError::BadTimecode { timecode }
            }
            timeline_file::Failure::TooShort(name) => TimelineError::TooShort { name },
            timeline_file::Failure::Nothing => TimelineError::Nothing,
        })?;
    Ok(TimelineText {
        xml,
        placements: placements
            .into_iter()
            .map(|p| TimelinePlacement {
                lane: p.lane,
                start: p.start,
                end: p.end,
            })
            .collect(),
    })
}

/// Where on the timeline: a timecode, or seconds from its start, as Swift's `ResolveBridge.At`.
#[derive(uniffi::Enum)]
pub enum ResolveAt {
    Timecode { timecode: String },
    Seconds { seconds: f64 },
}

/// Which audio track, as Swift's `ResolveBridge.Track`.
#[derive(uniffi::Enum)]
pub enum ResolveTrack {
    Free,
    Earmark,
    Index { index: i64 },
}

/// One sound to put on the timeline open in Resolve, as Swift's `ResolveBridge.Item`.
#[derive(uniffi::Record)]
pub struct ResolveItem {
    pub path: String,
    pub start: Option<f64>,
    pub end: Option<f64>,
    pub at: Option<ResolveAt>,
    pub track: ResolveTrack,
    pub length: Option<f64>,
    pub channels: Option<i64>,
}

/// Where one item went (or would go), or why it couldn't, as Swift's `ResolveBridge.Placement`.
#[derive(uniffi::Record)]
pub struct ResolvePlacement {
    pub ok: Option<bool>,
    pub error: Option<String>,
    pub track: Option<i64>,
    pub track_name: Option<String>,
    pub start: Option<String>,
    pub end: Option<String>,
    pub new_track: Option<bool>,
}

#[derive(uniffi::Record)]
pub struct ResolveAdded {
    pub project: String,
    pub timeline: String,
    pub items: Vec<ResolvePlacement>,
}

/// Why Resolve couldn't be asked, as Swift's `ResolveBridge.Failure`.
#[derive(Debug, uniffi::Error)]
pub enum ResolveError {
    NotInstalled,
    NotConnected,
    NoProject,
    NoTimeline,
    Other { detail: String },
}

impl std::fmt::Display for ResolveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResolveError::NotInstalled => earmark_resolve::Failure::NotInstalled.fmt(f),
            ResolveError::NotConnected => earmark_resolve::Failure::NotConnected.fmt(f),
            ResolveError::NoProject => earmark_resolve::Failure::NoProject.fmt(f),
            ResolveError::NoTimeline => earmark_resolve::Failure::NoTimeline.fmt(f),
            ResolveError::Other { detail } => {
                earmark_resolve::Failure::Other(detail.clone()).fmt(f)
            }
        }
    }
}

/// Places the items on the timeline open in DaVinci Resolve Studio, one after another, through
/// the same bridge script as Swift's `ResolveBridge.add`. `preview`: where they'd go, with
/// nothing imported or placed. Waits for Resolve (up to a minute): call it off the main thread.
#[uniffi::export]
pub fn resolve_add(
    items: Vec<ResolveItem>,
    preview: bool,
    move_playhead: bool,
) -> Result<ResolveAdded, ResolveError> {
    use earmark_resolve::{At, Item, Track};
    let items: Vec<Item> = items
        .into_iter()
        .map(|i| Item {
            path: i.path,
            start: i.start,
            end: i.end,
            at: i.at.map(|a| match a {
                ResolveAt::Timecode { timecode } => At::Timecode(timecode),
                ResolveAt::Seconds { seconds } => At::Seconds(seconds),
            }),
            track: match i.track {
                ResolveTrack::Free => Track::Free,
                ResolveTrack::Earmark => Track::Earmark,
                ResolveTrack::Index { index } => Track::Index(index),
            },
            length: i.length,
            channels: i.channels,
        })
        .collect();
    let added = earmark_resolve::add(&items, preview, move_playhead).map_err(|e| match e {
        earmark_resolve::Failure::NotInstalled => ResolveError::NotInstalled,
        earmark_resolve::Failure::NotConnected => ResolveError::NotConnected,
        earmark_resolve::Failure::NoProject => ResolveError::NoProject,
        earmark_resolve::Failure::NoTimeline => ResolveError::NoTimeline,
        earmark_resolve::Failure::Other(detail) => ResolveError::Other { detail },
    })?;
    Ok(ResolveAdded {
        project: added.project,
        timeline: added.timeline,
        items: added
            .items
            .into_iter()
            .map(|p| ResolvePlacement {
                ok: p.ok,
                error: p.error,
                track: p.track,
                track_name: p.track_name,
                start: p.start,
                end: p.end,
                new_track: p.new_track,
            })
            .collect(),
    })
}

/// The engine's version, so the app can say which engine it runs.
#[uniffi::export]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").into()
}
