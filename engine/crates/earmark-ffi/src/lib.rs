//! The engine as the Mac app calls it (docs/rust-engine-plan.md, step 8). UniFFI writes the
//! Swift side from these declarations (scripts/build-engine.sh), so the two can't drift apart.
//!
//! Records with many fields cross as JSON in the shape Swift's `Codable` types already read
//! (the parity checks compare exactly that JSON), so the app keeps its own types.

use earmark_core::analysis::{groups, sound_map};
use earmark_core::metadata::AudioTechnical;
use earmark_core::scan;
use earmark_core::ucs::UcsCatalog;
use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

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

/// The engine's version, so the app can say which engine it runs.
#[uniffi::export]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").into()
}
