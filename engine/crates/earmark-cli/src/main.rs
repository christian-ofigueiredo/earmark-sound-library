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
//!   earmark-engine map <library.sqlite> <out.json> [category]    the sound map, as earmark-parity map
//!   earmark-engine groups <library.sqlite> <swift.json> <out.json> the groups of the sounds Swift grouped
//!   earmark-engine categories <library.sqlite>   categories, folder suggestions and votes, as earmark-parity
//!   earmark-engine musicsteps <work folder> < swift-rows   the music maths on Swift's decoded songs and model outputs
//!   earmark-engine anafile-export <library.sqlite> <out folder>     one analysis file per library
//!   earmark-engine anafile-import <copy of library.sqlite> <file…>  imports them, says what it added
//!   earmark-engine timeline < cases.json     each case's timeline file text or failure
//!   earmark-engine db-new <path>              a new, empty database
//!   earmark-engine db-ops <path> < ops.json   applies the operations (only on copies)

use earmark_core::analysis::linalg::Floats;
use earmark_core::analysis::{
    audio, duplicates, groups, loudness::LoudnessMeter, similarity::SimilarityIndex, sound_map,
};
use earmark_core::music_key::MusicKey;
use earmark_core::scan::ScannedSound;
use earmark_core::twins::{self, TwinCandidate};
use earmark_core::{metadata, normalize, phase0, scan, ucs::UcsCatalog};
use earmark_db::{LibraryDatabase, SongFile};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
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
        (Some("names"), _) => {
            let names = stdin_lines_keep_empty();
            let mut keyed: Vec<_> = names
                .iter()
                .map(|n| (earmark_core::text::StandardKey::new(n), n))
                .collect();
            keyed.sort_by(|a, b| a.0.cmp(&b.0));
            let sorted: Vec<_> = keyed.into_iter().map(|(_, n)| n).collect();
            let capitalized: Vec<_> = names
                .iter()
                .map(|n| earmark_core::text::capitalized(n))
                .collect();
            emit(json!({"sorted": sorted, "capitalized": capitalized}));
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
        (Some("knn"), Some(db)) => knn_mode(
            Path::new(db),
            Path::new(&args[3]),
            args.get(4).map(String::as_str),
        ),
        (Some("map"), Some(db)) => map_mode(
            Path::new(db),
            Path::new(&args[3]),
            args.get(4).map(String::as_str),
        ),
        (Some("groups"), Some(db)) => {
            groups_mode(Path::new(db), Path::new(&args[3]), Path::new(&args[4]))
        }
        (Some("categories"), Some(db)) => categories_mode(Path::new(db), &mut emit),
        (Some("musicsteps"), Some(work)) => {
            for line in stdin_lines() {
                emit(music_row(
                    Path::new(work),
                    &serde_json::from_str(&line).unwrap(),
                ));
            }
        }
        (Some("anafile-export"), Some(db)) => {
            let db = LibraryDatabase::open(Some(Path::new(db)), true).unwrap();
            for lib in db.libraries(None).unwrap() {
                let path = Path::new(&args[3]).join(earmark_core::analysis_file::file_name(&lib));
                db.write_analysis_file(
                    &lib,
                    true,
                    &path,
                    "2027-01-15T08:00:00Z",
                    &scan::fingerprint,
                )
                .unwrap();
            }
        }
        (Some("anafile-import"), Some(db)) => {
            let db = LibraryDatabase::open(Some(Path::new(db)), false).unwrap();
            for path in &args[3..] {
                let file =
                    earmark_core::analysis_file::AnalysisFile::read(&std::fs::read(path).unwrap())
                        .unwrap();
                emit(
                    serde_json::to_value(db.import_analysis(&file, &scan::fingerprint).unwrap())
                        .unwrap(),
                );
            }
        }
        (Some("timeline"), _) => timeline_mode(&mut emit),
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

/// Each sound's two models' vectors, by id.
fn model_vectors(db: &LibraryDatabase) -> (BTreeMap<i64, Vec<f32>>, BTreeMap<i64, Vec<f32>>) {
    let peav: BTreeMap<i64, Vec<f32>> = db.vectors("pe-av-large").unwrap().into_iter().collect();
    let clap: BTreeMap<i64, Vec<f32>> = db.vectors("clap-general").unwrap().into_iter().collect();
    (peav, clap)
}

/// The map of every sound analysed by both models (or those in `category`), in id order.
fn map_mode(db: &Path, out: &Path, category: Option<&str>) {
    let db = LibraryDatabase::open(Some(db), true).unwrap();
    let (peav, clap) = model_vectors(&db);
    let mut sounds: Vec<earmark_db::SoundRecord> = db
        .sounds(None)
        .unwrap()
        .into_iter()
        .filter(|s| {
            let id = s.id.unwrap();
            peav.contains_key(&id)
                && clap.contains_key(&id)
                && (category.is_none() || s.category.as_deref() == category)
        })
        .collect();
    sounds.sort_by_key(|s| s.id);
    // In a page-aligned buffer, as the app's (Accelerate's sums depend on where it sits).
    let x = Floats::page_from(
        &sounds
            .iter()
            .flat_map(|s| sound_map::combine(&[&peav[&s.id.unwrap()], &clap[&s.id.unwrap()]]))
            .collect::<Vec<f32>>(),
    );
    let started = std::time::Instant::now();
    let m = sound_map::map(
        &x,
        sounds.len(),
        1536,
        &sound_map::Settings::default(),
        3,
        &|_| {},
        &|| false,
    )
    .unwrap();
    let seconds = started.elapsed().as_secs_f64();
    println!("{} sounds: layout in {seconds:.1} s", sounds.len());
    let json = json!({"ids": sounds.iter().map(|s| s.id.unwrap()).collect::<Vec<_>>(),
                      "x": m.points.iter().map(|p| p[0]).collect::<Vec<_>>(),
                      "y": m.points.iter().map(|p| p[1]).collect::<Vec<_>>(), "seconds": seconds});
    std::fs::write(out, json.to_string()).unwrap();
}

/// Groups and names for the same sounds Swift grouped (`earmark-parity groups`' output), each
/// subcategory's sounds in id order.
fn groups_mode(db: &Path, swift: &Path, out: &Path) {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Bucket {
        #[serde(rename = "catID")]
        cat_id: String,
        ids: Vec<i64>,
    }
    let db = LibraryDatabase::open(Some(db), true).unwrap();
    let (peav, clap) = model_vectors(&db);
    let buckets: Vec<Bucket> = serde_json::from_slice(&std::fs::read(swift).unwrap()).unwrap();
    let sounds: BTreeMap<i64, earmark_db::SoundRecord> = db
        .sounds(None)
        .unwrap()
        .into_iter()
        .map(|s| (s.id.unwrap(), s))
        .collect();
    // The mean of every sound's combined vector, so words that fit everything count less.
    let mut mean = vec![0f32; 1536];
    let mut counted = 0;
    for (id, v) in &peav {
        if let Some(c) = clap.get(id) {
            for (k, x) in sound_map::combine(&[v, c]).iter().enumerate() {
                mean[k] += x;
            }
            counted += 1;
        }
    }
    for m in &mut mean {
        *m /= counted.max(1) as f32;
    }
    let mut results = Vec::new();
    let started = std::time::Instant::now();
    for b in buckets {
        let x: Vec<f32> = b
            .ids
            .iter()
            .flat_map(|id| sound_map::combine(&[&peav[id], &clap[id]]))
            .collect();
        let t = std::time::Instant::now();
        let labels = groups::cluster(&x, b.ids.len(), 1536, &|| false).unwrap();
        let count = labels.iter().max().map_or(0, |m| m + 1);
        let members_of: Vec<Vec<usize>> = (0..count)
            .map(|g| (0..labels.len()).filter(|&i| labels[i] == g).collect())
            .collect();
        let records: Vec<&earmark_db::SoundRecord> = b.ids.iter().map(|id| &sounds[id]).collect();
        let members: Vec<groups::Member> = records
            .iter()
            .map(|s| {
                groups::Member::new(
                    s.duration,
                    &s.file_name,
                    s.fx_name.as_deref(),
                    s.details.as_deref(),
                    s.keywords.as_deref(),
                )
            })
            .collect();
        let exclude = groups::excluded_words(
            &records
                .iter()
                .map(|s| {
                    (
                        s.vendor_library.as_deref(),
                        s.manufacturer.as_deref(),
                        s.designer.as_deref(),
                        s.folder.as_str(),
                    )
                })
                .collect::<Vec<_>>(),
        );
        let names = groups::names(&members_of, &x, 1536, &members, &mean, &exclude);
        let seconds = t.elapsed().as_secs_f64();
        println!(
            "{} {} sounds: {} groups, {seconds:.2} s",
            b.cat_id,
            b.ids.len(),
            members_of.len()
        );
        results.push(json!({"catID": b.cat_id, "ids": b.ids, "labels": labels, "names": names, "seconds": seconds}));
    }
    println!(
        "{} subcategories in {:.1} s",
        results.len(),
        started.elapsed().as_secs_f64()
    );
    std::fs::write(out, Value::Array(results).to_string()).unwrap();
}

/// Each sound's 15 nearest, as `earmark-parity knn`.
fn knn_mode(db: &Path, out: &Path, category: Option<&str>) {
    let db = LibraryDatabase::open(Some(db), true).unwrap();
    let (peav, clap) = model_vectors(&db);
    let mut ids: Vec<i64> = db
        .sounds(None)
        .unwrap()
        .into_iter()
        .filter(|s| {
            let id = s.id.unwrap();
            peav.contains_key(&id)
                && clap.contains_key(&id)
                && (category.is_none() || s.category.as_deref() == category)
        })
        .map(|s| s.id.unwrap())
        .collect();
    ids.sort_unstable();
    let x = Floats::page_from(
        &ids.iter()
            .flat_map(|id| sound_map::combine(&[&peav[id], &clap[id]]))
            .collect::<Vec<f32>>(),
    );
    let (indices, distances) =
        sound_map::neighbours(&x, ids.len(), 1536, 15, &|_| {}, &|| false).unwrap();
    std::fs::write(
        out,
        json!({"indices": indices, "distances": distances}).to_string(),
    )
    .unwrap();
}

/// The categories as the app works them out (see `earmark-parity categories`).
fn categories_mode(db: &Path, emit: &mut dyn FnMut(Value)) {
    use earmark_core::analysis::{categories, folder_rules};
    let catalog = UcsCatalog::shared();
    let db = LibraryDatabase::open(Some(db), true).unwrap();
    let (rules, guesses, choices) = (
        db.folder_rules().unwrap(),
        db.folder_guesses().unwrap(),
        db.sound_category_choices().unwrap(),
    );
    let all = db.sounds(None).unwrap();
    let applied = categories::apply(
        &choices,
        &folder_rules::apply(&rules, &guesses, &all, catalog),
        catalog,
    );
    for s in &applied {
        emit(json!({"id": s.id, "catID": s.cat_id, "source": s.category_source}));
    }

    let hidden: HashSet<i64> = twins::group(&applied.iter().map(twin).collect::<Vec<_>>())
        .hidden
        .into_iter()
        .collect();
    let mut open: BTreeMap<String, (String, Vec<earmark_db::SoundRecord>)> = BTreeMap::new();
    for s in &applied {
        let src = s.category_source.as_deref();
        let open_source = matches!(
            src,
            Some(folder_rules::SOURCE)
                | Some(folder_rules::GUESS_SOURCE)
                | Some(categories::SOUND_GUESS_SOURCE)
        );
        if (s.cat_id.is_none() || open_source) && !hidden.contains(&s.id.unwrap()) {
            open.entry(format!("{}/{}", s.library_id, s.folder))
                .or_insert_with(|| (s.folder.clone(), vec![]))
                .1
                .push(s.clone());
        }
    }
    let index = SimilarityIndex::new(&db.vectors("clap-general").unwrap());
    let labels = folder_rules::labels(&applied);
    let shared = folder_rules::shared_descriptions(&applied, 3);
    for (key, (folder, sounds)) in &open {
        let options = folder_rules::suggest(
            folder,
            sounds,
            Some(&index),
            &labels,
            &shared,
            3,
            &folder_rules::Tuning::default(),
        );
        emit(
            json!({"folder": key, "options": options.iter().map(|o| json!({"catID": o.entry.cat_id, "score": o.score,
            "words": o.words, "fileWords": o.file_words, "soundShare": o.sound_share, "uncertain": o.is_uncertain})).collect::<Vec<_>>()}),
        );
    }

    // SoundGuesser.run, step by step.
    let owners: std::collections::HashMap<i64, _> =
        choices.into_iter().filter(|c| c.1.by_owner).collect();
    let sounds = categories::apply(
        &owners,
        &folder_rules::apply(&rules, &guesses, &all, catalog),
        catalog,
    );
    let twins_hidden: HashSet<i64> = twins::group(&sounds.iter().map(twin).collect::<Vec<_>>())
        .hidden
        .into_iter()
        .collect();
    let by_id: BTreeMap<i64, &earmark_db::SoundRecord> =
        sounds.iter().map(|s| (s.id.unwrap(), s)).collect();
    let d = 1536;
    let mut rows: Vec<&earmark_db::SoundRecord> = Vec::new();
    // Both callbacks fill the same buffer: the first sizes it, the second writes rows.
    let buffer = std::cell::RefCell::new(Floats::page(0));
    db.for_each_vectors(
        &["pe-av-large", "clap-general"],
        None,
        &mut |n| *buffer.borrow_mut() = Floats::page(n * d),
        &mut |id, blocks| {
            let Some(s) = by_id.get(&id) else { return };
            let mut b = buffer.borrow_mut();
            if twins_hidden.contains(&id) || (rows.len() + 1) * d > b.len() {
                return;
            }
            let r = rows.len();
            b[r * d..(r + 1) * d].copy_from_slice(&sound_map::combine(&[&blocks[0], &blocks[1]]));
            rows.push(s);
        },
    )
    .unwrap();
    let buffer = buffer.into_inner();
    let k = 60.min(rows.len());
    let (indices, distances) = sound_map::neighbours(
        &buffer[..rows.len() * d],
        rows.len(),
        d,
        k,
        &|_| {},
        &|| false,
    )
    .unwrap();
    let row_labels: Vec<Option<String>> = rows.iter().map(|s| s.cat_id.clone()).collect();
    let row_folders: Vec<String> = rows
        .iter()
        .map(|s| format!("{}/{}", s.library_id, s.folder))
        .collect();
    let votes = categories::votes_from(&indices, &distances, k, &row_labels, &row_folders, 15);
    let durations: Vec<Option<f64>> = rows.iter().map(|s| s.duration).collect();
    let ids: Vec<i64> = rows.iter().map(|s| s.id.unwrap()).collect();
    let duplicates = duplicates::near_pairs(&ids, &durations, &indices, &distances, k);
    let mut folders: std::collections::HashMap<i64, HashSet<String>> =
        std::collections::HashMap::new();
    let mut by_folder: std::collections::HashMap<String, &folder_rules::FolderGuess> =
        std::collections::HashMap::new();
    for g in &guesses {
        folders
            .entry(g.library_id)
            .or_default()
            .insert(g.folder.clone());
        by_folder
            .entry(format!("{}/{}", g.library_id, g.folder))
            .or_insert(g);
    }
    let alternatives = |s: &earmark_db::SoundRecord| -> HashSet<String> {
        folders
            .get(&s.library_id)
            .and_then(|f| folder_rules::rule_folder(&s.folder, f))
            .and_then(|f| by_folder.get(&format!("{}/{}", s.library_id, f)))
            .map(|g| g.alternative_ids().into_iter().collect())
            .unwrap_or_default()
    };
    let owned: Vec<earmark_db::SoundRecord> = rows.iter().map(|s| (*s).clone()).collect();
    let made = categories::guesses(&owned, &votes, &alternatives, 0.6, 0.1, "now");
    for g in &made {
        emit(
            json!({"guess": g.sound_id, "catID": g.cat_id, "share": g.share, "replaced": g.replaced}),
        );
    }
    for p in &duplicates {
        emit(json!({"pair": [p.a, p.b], "similarity": p.similarity}));
    }
    for (r, v) in votes.iter().enumerate().filter(|(r, _)| r % 50 == 0) {
        emit(json!({"vote": ids[r], "votes": v}));
    }
}

/// Rust's music maths on one of `earmark-parity musicsteps`' songs: the half-rate filter on its
/// decoded audio, the spectrogram on its half-rate audio, and the beat summary and key from its
/// model outputs; with how far each step is from Swift's.
fn music_row(work: &Path, swift: &Value) -> Value {
    use earmark_core::analysis::music;
    let index = swift["index"].as_u64().unwrap();
    let file = |ext: &str| floats(&work.join(format!("{index}.{ext}")));
    let worst = |a: &[f32], b: &[f32]| {
        if a.len() != b.len() {
            return json!("different lengths");
        }
        let differ = a.iter().zip(b).filter(|(x, y)| x != y).count();
        json!({"differ": differ, "largest": a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0f32, f32::max)})
    };
    let half = file("half");
    let ours_half = music::decimate(&file("m44"));
    let sr = music::SAMPLE_RATE;
    let x = &half[..half.len().min((music::MAX_SECONDS as usize) * sr)];
    let ours_spect = music::spectrogram(x);
    let (beat, down) = (file("beat"), file("down"));
    let (beats, downbeats) = music::peaks(&beat, &down);
    let prob: Vec<f32> = beat.iter().map(|&v| music::sigmoid(v)).collect();
    let t = music::summarize(&beats, &downbeats, &prob);
    let probs: Vec<f32> = swift["keyProbabilities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_f64().unwrap() as f32)
        .collect();
    let k = music::estimate_key(&probs);
    json!({
        "index": index, "path": swift["path"], "keyProbabilities": swift["keyProbabilities"],
        "beats": t.beats, "downbeats": t.downbeats, "bpm": t.bpm, "bpmRange": t.bpm_range.map(|r| vec![r.0, r.1]),
        "stability": t.stability, "beatsPerBar": t.beats_per_bar, "confidence": t.confidence,
        "key": k.as_ref().map(|k| k.key), "keyConfidence": k.as_ref().map(|k| k.confidence),
        "runnerUp": k.as_ref().map(|k| k.runner_up),
        "halfRate": worst(&ours_half, &half), "spectrogram": worst(&ours_spect, &file("spect")),
    })
}

/// Each case's timeline file (see `earmark-parity timeline`). Numbers come as text.
fn timeline_mode(emit: &mut dyn FnMut(Value)) {
    use earmark_core::timeline_file::{Clip, Rate, fcpxml};
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct RawClip {
        path: String,
        name: String,
        length: String,
        sample_rate: i64,
        channels: i64,
        time_reference: i64,
        start: Option<String>,
        end: Option<String>,
        at: Option<String>,
    }
    #[derive(Deserialize)]
    struct Case {
        clips: Vec<RawClip>,
        rate: String,
        start: String,
        name: String,
    }
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).unwrap();
    let number = |t: &Option<String>| t.as_ref().map(|v| v.parse::<f64>().unwrap());
    for c in serde_json::from_str::<Vec<Case>>(&text).unwrap() {
        let clips: Vec<Clip> = c
            .clips
            .iter()
            .map(|x| Clip {
                path: x.path.clone(),
                name: x.name.clone(),
                length: x.length.parse().unwrap(),
                sample_rate: x.sample_rate,
                channels: x.channels,
                time_reference: x.time_reference,
                start: number(&x.start),
                end: number(&x.end),
                at: number(&x.at),
            })
            .collect();
        match fcpxml(&clips, &Rate::named(&c.rate).unwrap(), &c.start, &c.name) {
            Ok((xml, placements)) => emit(json!({"xml": xml, "placements": placements})),
            Err(e) => emit(json!({"failure": e.to_string()})),
        }
    }
}
