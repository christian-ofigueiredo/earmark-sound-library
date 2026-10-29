//! Command-line tools for the engine. Each mode writes JSON lines that the same mode of the Swift
//! `earmark-parity` writes too; `engine/parity/compare.py` compares the two. Files are only read.
//!
//!   earmark-engine metadata < paths.txt     what each file's chunks say, normalised
//!   earmark-engine scan <folder>            the scanner's record of every audio file
//!   earmark-engine twins < swift-twins.json format twins of the sounds Swift listed
//!   earmark-engine keys < texts.txt         each text parsed as a key
//!   earmark-engine phase0 <music_analysis.json>
//!   earmark-engine dates < seconds.txt       each time as the database stores it
//!   earmark-engine db-new <path>              a new, empty database
//!   earmark-engine db-ops <path> < ops.json   applies the operations (only on copies)

use earmark_core::music_key::MusicKey;
use earmark_core::scan::ScannedSound;
use earmark_core::twins::{self, TwinCandidate};
use earmark_core::{metadata, normalize, phase0, scan, ucs::UcsCatalog};
use earmark_db::{LibraryDatabase, SongFile};
use serde::Deserialize;
use serde_json::{Value, json};
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
