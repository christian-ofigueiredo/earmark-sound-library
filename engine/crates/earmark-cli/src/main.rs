//! Command-line tools for the engine. Each mode writes JSON lines that the same mode of the Swift
//! `earmark-parity` writes too; `engine/parity/compare.py` compares the two. Files are only read.
//!
//!   earmark-engine metadata < paths.txt     what each file's chunks say, normalised
//!   earmark-engine scan <folder>            the scanner's record of every audio file
//!   earmark-engine twins < swift-twins.json format twins of the sounds Swift listed
//!   earmark-engine keys < texts.txt         each text parsed as a key
//!   earmark-engine phase0 <music_analysis.json>
//!   earmark-engine dates < seconds.txt       each time as the database stores it
//!   earmark-engine audio <work folder> < swift-rows   loudness and CLAP features of Swift's decoded audio
//!   earmark-engine similar <library.sqlite> < ids     each sound's 20 nearest by CLAP
//!   earmark-engine dupsets <library.sqlite>           identical copies and saved near pairs, as sets
//!   earmark-engine db-new <path>              a new, empty database
//!   earmark-engine db-ops <path> < ops.json   applies the operations (only on copies)

use earmark_core::analysis::{
    audio, duplicates, loudness::LoudnessMeter, similarity::SimilarityIndex,
};
use earmark_core::music_key::MusicKey;
use earmark_core::scan::ScannedSound;
use earmark_core::twins::{self, TwinCandidate};
use earmark_core::{metadata, normalize, phase0, scan, ucs::UcsCatalog};
use earmark_db::{LibraryDatabase, SongFile};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::io::{BufRead, Read, Write};
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    let mut emit = |v: Value| writeln!(out, "{v}").unwrap();
    match (args.get(1).map(String::as_str), args.get(2)) {
        (Some("metadata"), _) => {
            for path in stdin_lines() {
                let p = Path::new(&path);
                let raw = metadata::read(p);
                let normalized = normalize::normalize(&raw, p, UcsCatalog::shared());
                emit(json!({"path": path, "raw": raw, "normalized": normalized,
                            "timeReference": metadata::time_reference(p)}));
            }
        }
        (Some("scan"), Some(root)) => {
            for s in scan::scan(Path::new(root), UcsCatalog::shared(), 8, None, &|_, _| {}) {
                emit(serde_json::to_value(s).unwrap());
            }
        }
        (Some("twins"), _) => {
            #[derive(Deserialize)]
            struct Input {
                sounds: Vec<TwinCandidate>,
            }
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text).unwrap();
            let input: Input = serde_json::from_str(&text).unwrap();
            let groups = twins::group(&input.sounds);
            emit(
                json!({"sounds": input.sounds, "alternates": groups.alternates, "hidden": groups.hidden}),
            );
        }
        (Some("keys"), _) => {
            let key = |k: MusicKey| {
                json!({"key": k, "name": k.name(), "shortName": k.short_name(), "camelot": k.camelot(),
                       "relative": k.relative(), "mixesWith": k.mixes_with()})
            };
            for text in stdin_lines_keep_empty() {
                emit(json!({"text": text, "parsed": MusicKey::parse(&text).map(key)}));
            }
            for k in MusicKey::all() {
                emit(json!({"text": "all", "parsed": key(k)}));
            }
        }
        (Some("phase0"), Some(file)) => match phase0::read(&std::fs::read(file).unwrap()) {
            Ok(entries) => entries
                .into_iter()
                .for_each(|e| emit(serde_json::to_value(e).unwrap())),
            Err(e) => {
                eprintln!("earmark-engine: {e}");
                std::process::exit(1);
            }
        },
        (Some("dates"), _) => {
            for line in stdin_lines() {
                let t: f64 = line.parse().unwrap();
                emit(json!(format!("{line} {}", earmark_db::dates::format(t))));
            }
        }
        (Some("audio"), Some(work)) => {
            for line in stdin_lines() {
                emit(audio_row(
                    Path::new(work),
                    &serde_json::from_str(&line).unwrap(),
                ));
            }
        }
        (Some("similar"), Some(db)) => {
            let db = LibraryDatabase::open(Some(Path::new(db)), true).unwrap();
            let index = SimilarityIndex::new(&db.vectors("clap-general").unwrap());
            for line in stdin_lines() {
                let id: i64 = line.parse().unwrap();
                let near = index.nearest(id, 20, &HashSet::new());
                emit(
                    json!({"id": id, "ids": near.iter().map(|n| n.0).collect::<Vec<_>>(),
                            "scores": near.iter().map(|n| n.1).collect::<Vec<_>>()}),
                );
            }
        }
        (Some("dupsets"), Some(db)) => {
            let db = LibraryDatabase::open(Some(Path::new(db)), true).unwrap();
            let sounds = db.sounds(None).unwrap();
            let hidden = twins::group(&sounds.iter().map(twin).collect::<Vec<_>>()).hidden;
            let identical = duplicates::identical_pairs(
                &sounds
                    .iter()
                    .map(|s| (s.id.unwrap(), s.fingerprint.clone()))
                    .collect::<Vec<_>>(),
                &hidden.into_iter().collect(),
            );
            let near = db.near_duplicates().unwrap();
            let sets = duplicates::sets(&[identical.clone(), near.clone()].concat());
            let others: serde_json::Map<String, Value> = sets
                .others
                .iter()
                .map(|(id, list)| {
                    (
                        id.to_string(),
                        json!(
                            list.iter()
                                .map(|o| json!({"id": o.0, "identical": o.1, "similarity": o.2}))
                                .collect::<Vec<_>>()
                        ),
                    )
                })
                .collect();
            emit(
                json!({"identical": identical.len(), "near": near.len(), "members": sets.members, "others": others}),
            );
        }
        (Some("db-new"), Some(path)) => {
            LibraryDatabase::open(Some(Path::new(path)), false).unwrap();
        }
        (Some("db-ops"), Some(path)) => db_ops(Path::new(path)),
        (Some("--version"), _) => emit(json!(format!(
            "earmark-engine {}",
            env!("CARGO_PKG_VERSION")
        ))),
        _ => {
            eprintln!("usage: earmark-engine metadata|scan <folder>|twins|keys|phase0 <file>");
            std::process::exit(2);
        }
    }
}

/// Non-empty lines of stdin (Swift's `while let line = readLine(), !line.isEmpty`).
fn stdin_lines() -> Vec<String> {
    stdin_lines_keep_empty()
        .into_iter()
        .take_while(|l| !l.is_empty())
        .collect()
}

fn stdin_lines_keep_empty() -> Vec<String> {
    std::io::stdin()
        .lock()
        .lines()
        .map_while(Result::ok)
        .collect()
}

#[derive(Deserialize)]
struct Op {
    op: String,
    kind: Option<String>,
    path: Option<String>,
    root: Option<String>,
    scanned: Option<Vec<ScannedSound>>,
    files: Option<Vec<SongFile>>,
    file: Option<String>,
    results: Option<Vec<SongResult>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SongResult {
    song_id: i64,
    analysis: phase0::SongAnalysis,
}

/// The same operations as `earmark-parity db-ops`, in order.
fn db_ops(path: &Path) {
    let db = LibraryDatabase::open(Some(path), false).unwrap();
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).unwrap();
    let ops: Vec<Op> = serde_json::from_str(&text).unwrap();
    let library = |p: &Option<String>| {
        db.libraries(None)
            .unwrap()
            .into_iter()
            .find(|l| Some(&l.path) == p.as_ref())
            .expect("no such library")
            .id
    };
    for op in ops {
        match op.op.as_str() {
            "addLibrary" => {
                db.add_library(
                    op.kind.as_deref().unwrap(),
                    op.path.as_deref().unwrap(),
                    None,
                )
                .unwrap();
            }
            "removeLibrary" => db.remove_library(library(&op.path)).unwrap(),
            "replaceSounds" => db
                .replace_sounds(
                    library(&op.path),
                    op.root.as_deref().unwrap(),
                    op.scanned.as_deref().unwrap(),
                )
                .unwrap(),
            "replaceSongs" => db
                .replace_songs(
                    library(&op.path),
                    op.root.as_deref().unwrap(),
                    op.files.as_deref().unwrap(),
                )
                .unwrap(),
            "applySongAnalysis" => {
                let entries = phase0::read(&std::fs::read(op.file.unwrap()).unwrap()).unwrap();
                println!("{}", db.apply_song_analysis(&entries).unwrap());
            }
            "saveSongAnalysis" => {
                let results: Vec<(i64, phase0::SongAnalysis)> = op
                    .results
                    .unwrap()
                    .into_iter()
                    .map(|r| (r.song_id, r.analysis))
                    .collect();
                let ids: Vec<i64> = db
                    .save_song_analysis(&results)
                    .unwrap()
                    .iter()
                    .filter_map(|s| s.id)
                    .collect();
                println!("{}", serde_json::to_string(&ids).unwrap());
            }
            other => panic!("unknown operation {other}"),
        }
    }
}

fn twin(s: &earmark_db::SoundRecord) -> TwinCandidate {
    TwinCandidate {
        id: s.id.unwrap(),
        library_id: s.library_id,
        file_name: s.file_name.clone(),
        folder: s.folder.clone(),
        path: s.path.clone(),
        duration: s.duration,
        sample_rate: s.sample_rate,
        bits_per_sample: s.bits_per_sample,
    }
}

fn floats(path: &Path) -> Vec<f32> {
    earmark_db::SoundEmbedding::floats(&std::fs::read(path).unwrap())
}

/// What Rust measures from the audio Swift decoded (one of `earmark-parity audio`'s rows), and
/// how far its CLAP features are from Swift's.
fn audio_row(work: &Path, swift: &Value) -> Value {
    let index = swift["index"].as_u64().unwrap();
    let (channels, frames) = (
        swift["channels"].as_u64().unwrap() as usize,
        swift["frames"].as_u64().unwrap() as usize,
    );
    let pcm = floats(&work.join(format!("{index}.pcm")));
    let mut meter = LoudnessMeter::new(swift["rate"].as_f64().unwrap(), channels);
    let slices: Vec<&[f32]> = (0..channels)
        .map(|c| &pcm[c * frames..(c + 1) * frames])
        .collect();
    // In the app's chunks (64 K frames).
    let mut start = 0;
    while start < frames {
        let n = (1 << 16).min(frames - start);
        let chunk: Vec<&[f32]> = slices.iter().map(|s| &s[start..start + n]).collect();
        meter.process(&chunk, n);
        start += n;
    }
    let mono = floats(&work.join(format!("{index}.mono")));
    let prepared = audio::prepare(&mono);
    let windows = prepared.as_deref().map(audio::windows).unwrap_or_default();
    let swift_clap = floats(&work.join(format!("{index}.clap")));
    let ours: Vec<f32> = windows
        .iter()
        .flat_map(|w| audio::clap_features(w))
        .collect();
    let worst = if ours.len() == swift_clap.len() {
        ours.iter()
            .zip(&swift_clap)
            .map(|(a, b)| (a - b).abs())
            .fold(0f32, f32::max) as f64
    } else {
        f64::INFINITY
    };
    json!({
        "index": index, "path": swift["path"], "rate": swift["rate"], "channels": channels, "frames": frames,
        "loudness": meter.result(), "monoFrames": mono.len(), "prepared": prepared.as_ref().map(Vec::len),
        "windows": windows.iter().map(|w| json!({"length": w.len(), "rms": audio::rms(w)})).collect::<Vec<_>>(),
        "peavLengths": windows.iter().map(|w| audio::peav_input(w).len()).collect::<Vec<_>>(),
        "clapWorst": if worst.is_finite() { json!(worst) } else { json!("different lengths") },
    })
}
