//! Command-line tools for the engine. Each mode writes JSON lines that the same mode of the Swift
//! `earmark-parity` writes too; `engine/parity/compare.py` compares the two. Files are only read.
//!
//!   earmark-engine metadata < paths.txt     what each file's chunks say, normalised
//!   earmark-engine scan <folder>            the scanner's record of every audio file
//!   earmark-engine twins < swift-twins.json format twins of the sounds Swift listed
//!   earmark-engine keys < texts.txt         each text parsed as a key
//!   earmark-engine phase0 <music_analysis.json>

use earmark_core::music_key::MusicKey;
use earmark_core::twins::{self, TwinCandidate};
use earmark_core::{metadata, normalize, phase0, scan, ucs::UcsCatalog};
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
