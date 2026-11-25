//! Analysis on Windows and Linux (step 9b), as the Mac app's AnalysisEngine and GroupBuilder:
//! loudness for every sound, the two models' vectors when their ONNX files are installed, then
//! the similarity groups. Runs on one background thread at a time, in small batches, saving as it
//! goes; stops when asked.

use earmark_core::analysis::groups::{self, Member, Work};
use earmark_core::analysis::linalg::Floats;
use earmark_core::analysis::loudness::LoudnessMeter;
use earmark_core::analysis::sound_map;
use earmark_core::dates;
use earmark_core::records::{EmbeddingStatus, SoundEmbedding, SoundFacts, SoundRecord};
use earmark_db::LibraryDatabase;
use earmark_db::catalog::SoundCatalog;
use earmark_models::{ClapEmbedder, Compute, FileResult, PeavEmbedder};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

pub const CLAP: &str = "clap-general";
pub const PEAV: &str = "pe-av-large";
/// Phase 0's audio for the models: mono, 48 kHz, the first 10 minutes at most.
const RATE: u32 = 48_000;
const MAX_SECONDS: f64 = 600.0;
const BATCH: usize = 8;

/// Where the models go: the data folder's `Models` (CLAPAudio.onnx, PEAV/PEAV*.onnx), the files
/// models/convert_onnx.py makes.
pub fn models_folder(database: &Path) -> PathBuf {
    database.parent().unwrap_or(Path::new(".")).join("Models")
}

pub struct Progress<'a> {
    pub report: &'a (dyn Fn(&str, usize, usize) + Sync),
    pub stop: &'a AtomicBool,
}

fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Loudness and peak of one file, decoded by the engine (Symphonia). None when stopped.
fn facts(sound: &SoundRecord, stop: &AtomicBool) -> Option<SoundFacts> {
    let id = sound.id?;
    let now = dates::now();
    let made = |loudness: Option<f64>, peak: Option<f64>, error: Option<String>| SoundFacts {
        sound_id: id,
        fingerprint: sound.fingerprint.clone(),
        version: SoundFacts::CURRENT_VERSION,
        loudness,
        peak,
        error,
        analyzed_at: now.clone(),
    };
    let mut reader = match earmark_audio::decode::Reader::open(Path::new(&sound.path)) {
        Ok(r) => r,
        Err(e) => return Some(made(None, None, Some(e.to_string()))),
    };
    let mut meter: Option<LoudnessMeter> = None;
    let mut block = Vec::new();
    let mut planes: Vec<Vec<f32>> = Vec::new();
    loop {
        if stop.load(Ordering::Relaxed) {
            return None;
        }
        match reader.next_block(&mut block) {
            Ok(true) => {}
            Ok(false) => break,
            Err(e) => return Some(made(None, None, Some(e.to_string()))),
        }
        let channels = reader.channels.max(1);
        let m = meter.get_or_insert_with(|| LoudnessMeter::new(reader.sample_rate as f64, channels));
        let frames = block.len() / channels;
        planes.resize(channels, Vec::new());
        for (c, plane) in planes.iter_mut().enumerate() {
            plane.clear();
            plane.extend(block.iter().skip(c).step_by(channels));
        }
        let slices: Vec<&[f32]> = planes.iter().map(Vec::as_slice).collect();
        m.process(&slices, frames);
    }
    let result = meter.map(|m| m.result()).unwrap_or_default();
    Some(made(result.integrated, result.peak, None))
}

fn embedding(sound: &SoundRecord, model: &str, vector: Option<Vec<f32>>, error: Option<String>) -> SoundEmbedding {
    SoundEmbedding {
        sound_id: sound.id.unwrap_or_default(),
        model: model.into(),
        fingerprint: sound.fingerprint.clone(),
        version: SoundEmbedding::version_of(model),
        vector: vector.map(|v| SoundEmbedding::bytes(&v)),
        error,
        analyzed_at: dates::now(),
    }
}

/// Everything not analysed yet: loudness, then the vectors (if the models are installed), then
/// the groups. Returns what it did, in words.
pub fn run(db: &Mutex<LibraryDatabase>, database: &Path, progress: &Progress) -> Result<String, String> {
    let catalog = {
        let db = db.lock().map_err(error)?;
        SoundCatalog::new(&db).map_err(error)?
    };
    let shown: Vec<&SoundRecord> = catalog
        .sounds
        .iter()
        .filter(|s| catalog.is_shown(s) && Path::new(&s.path).exists())
        .collect();
    let mut said = Vec::new();

    // Loudness.
    let missing: Vec<&SoundRecord> = shown
        .iter()
        .copied()
        .filter(|s| {
            !s.id
                .and_then(|id| catalog.facts.get(&id))
                .is_some_and(|f| f.is_current(s))
        })
        .collect();
    let mut done = 0;
    for chunk in missing.chunks(BATCH * 4) {
        let mut made = Vec::new();
        for s in chunk {
            match facts(s, progress.stop) {
                Some(f) => made.push(f),
                None => break,
            }
            done += 1;
            (progress.report)("Measuring loudness", done, missing.len());
        }
        db.lock().map_err(error)?.save_facts(&made).map_err(error)?;
        if progress.stop.load(Ordering::Relaxed) {
            return Ok("Stopped.".into());
        }
    }
    if !missing.is_empty() {
        said.push(format!("loudness of {done} sounds"));
    }

    // The two models' vectors, when installed.
    let folder = models_folder(database);
    let clap_file = folder.join("CLAPAudio.onnx");
    let peav = PeavEmbedder::new(folder.join("PEAV"), Compute::Gpu);
    if clap_file.is_file() && peav.is_ok() {
        let clap = ClapEmbedder::open(&clap_file).map_err(error)?;
        let peav = peav.map_err(error)?;
        let (clap_status, peav_status) = {
            let db = db.lock().map_err(error)?;
            (
                db.embedding_status(CLAP).map_err(error)?,
                db.embedding_status(PEAV).map_err(error)?,
            )
        };
        let current = |status: &HashMap<i64, EmbeddingStatus>, model: &str, s: &SoundRecord| {
            EmbeddingStatus::is_current(s.id.and_then(|id| status.get(&id)), model, s)
        };
        let todo: Vec<&SoundRecord> = shown
            .iter()
            .copied()
            .filter(|s| !current(&clap_status, CLAP, s) || !current(&peav_status, PEAV, s))
            .collect();
        let mut done = 0;
        for chunk in todo.chunks(BATCH) {
            let mut audio = Vec::new();
            let mut saved = Vec::new();
            for s in chunk {
                match earmark_audio::decode::mono(Path::new(&s.path), RATE, MAX_SECONDS) {
                    Ok(a) => audio.push((*s, a)),
                    Err(e) => {
                        saved.push(embedding(s, CLAP, None, Some(e.to_string())));
                        saved.push(embedding(s, PEAV, None, Some(e.to_string())));
                    }
                }
            }
            for (s, a) in &audio {
                if !current(&clap_status, CLAP, s) {
                    saved.push(match clap.embed(a) {
                        Ok(v) => embedding(s, CLAP, v, None),
                        Err(e) => embedding(s, CLAP, None, Some(e.to_string())),
                    });
                }
            }
            let need: Vec<&(&SoundRecord, Vec<f32>)> =
                audio.iter().filter(|(s, _)| !current(&peav_status, PEAV, s)).collect();
            let windows: Vec<Vec<Vec<f32>>> = need.iter().map(|(_, a)| PeavEmbedder::windows(a)).collect();
            let stop = || progress.stop.load(Ordering::Relaxed);
            match peav.embed(&windows, &stop).map_err(error)? {
                Some(results) => {
                    for ((s, _), r) in need.iter().zip(results) {
                        saved.push(match r {
                            FileResult::Vector(v) => embedding(s, PEAV, Some(v), None),
                            FileResult::Silent => embedding(s, PEAV, None, None),
                            FileResult::Failed(e) => embedding(s, PEAV, None, Some(e)),
                        });
                    }
                }
                None => return Ok("Stopped.".into()),
            }
            db.lock().map_err(error)?.save_embeddings(&saved).map_err(error)?;
            done += chunk.len();
            (progress.report)("Listening to the sounds", done, todo.len());
            if progress.stop.load(Ordering::Relaxed) {
                return Ok("Stopped.".into());
            }
        }
        if !todo.is_empty() {
            said.push(format!("{done} sounds listened to"));
        }
    } else {
        said.push(format!(
            "no models in {} (Find Similar, groups and the map need them, or an analysis file from the Mac)",
            folder.display()
        ));
    }

    // Similarity groups.
    let grouped = group(db, progress)?;
    if grouped > 0 {
        said.push(format!("{grouped} subcategories grouped"));
    }
    Ok(if said.is_empty() {
        "Everything is analysed.".into()
    } else {
        format!("Done: {}.", said.join(", "))
    })
}

const D: usize = 1536;

/// The sounds' combined vectors (both models), row after row, in the order found.
fn vectors(db: &LibraryDatabase, ids: &[i64]) -> Result<(Vec<i64>, Floats), String> {
    let mut found = Vec::new();
    let mut flat = Vec::new();
    db.for_each_vectors(&[PEAV, CLAP], Some(ids), &mut |_| {}, &mut |id, blocks| {
        let refs: Vec<&[f32]> = blocks.iter().map(Vec::as_slice).collect();
        let v = sound_map::combine(&refs);
        if v.len() == D {
            flat.extend(v);
            found.push(id);
        }
    })
    .map_err(error)?;
    let mut x = Floats::page(flat.len());
    x.copy_from_slice(&flat);
    Ok((found, x))
}

/// The groups as GroupBuilder makes them: each subcategory's sounds analysed by both models.
fn group(db: &Mutex<LibraryDatabase>, progress: &Progress) -> Result<usize, String> {
    let db = db.lock().map_err(error)?;
    let catalog = SoundCatalog::new(&db).map_err(error)?;
    let clap = db.embedding_status(CLAP).map_err(error)?;
    let peav = db.embedding_status(PEAV).map_err(error)?;
    let mut buckets: BTreeMap<String, Vec<(i64, Option<String>)>> = BTreeMap::new();
    for s in &catalog.sounds {
        let (Some(id), Some(cat_id)) = (s.id, &s.cat_id) else {
            continue;
        };
        if catalog.is_shown(s)
            && EmbeddingStatus::is_current(clap.get(&id), CLAP, s)
            && EmbeddingStatus::is_current(peav.get(&id), PEAV, s)
        {
            buckets
                .entry(cat_id.clone())
                .or_default()
                .push((id, s.fingerprint.clone()));
        }
    }
    let work = groups::work(&buckets, &catalog.groups.plan);
    if work.is_empty() {
        return Ok(0);
    }
    let by_id: HashMap<i64, &SoundRecord> = catalog.sounds.iter().filter_map(|s| s.id.map(|id| (id, s))).collect();
    let mut mean: Option<Vec<f32>> = None;
    let mut regrouped = 0;
    for (i, item) in work.iter().enumerate() {
        if progress.stop.load(Ordering::Relaxed) {
            break;
        }
        (progress.report)("Grouping similar sounds", i, work.len());
        match item {
            Work::Drop { cat_id } => db.drop_groups(cat_id).map_err(error)?,
            Work::Regroup { cat_id, sounds } => {
                if mean.is_none() {
                    let mut sum = vec![0f64; D];
                    let mut n = 0usize;
                    db.for_each_vectors(&[PEAV, CLAP], None, &mut |_| {}, &mut |_, blocks| {
                        let refs: Vec<&[f32]> = blocks.iter().map(Vec::as_slice).collect();
                        for (c, v) in sound_map::combine(&refs).iter().enumerate().take(D) {
                            sum[c] += *v as f64;
                        }
                        n += 1;
                    })
                    .map_err(error)?;
                    mean = Some(sum.iter().map(|s| (s / n.max(1) as f64) as f32).collect());
                }
                let (ids, x) = vectors(&db, sounds)?;
                let records: Vec<&SoundRecord> = ids.iter().filter_map(|id| by_id.get(id).copied()).collect();
                if records.len() != ids.len() || ids.is_empty() {
                    continue;
                }
                let n = ids.len();
                let Some(labels) = groups::cluster(&x, n, D, &|| progress.stop.load(Ordering::Relaxed)) else {
                    break;
                };
                let k = labels.iter().max().map_or(0, |m| m + 1);
                let rows: Vec<Vec<usize>> = (0..k).map(|g| (0..n).filter(|&r| labels[r] == g).collect()).collect();
                let members: Vec<Member> = records
                    .iter()
                    .map(|s| {
                        Member::new(
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
                let names = groups::names(&rows, &x, D, &members, mean.as_deref().unwrap_or(&[]), &exclude);
                let made: Vec<Vec<(i64, Option<String>)>> = rows
                    .iter()
                    .map(|g| g.iter().map(|&r| (ids[r], records[r].fingerprint.clone())).collect())
                    .collect();
                db.replace_groups(cat_id, &made, &names).map_err(error)?;
                regrouped += 1;
            }
            Work::Update { cat_id, add, remove } => {
                let snapshot = &catalog.groups.plan;
                let in_cat: HashSet<i64> = snapshot
                    .groups
                    .get(cat_id)
                    .map(|g| g.iter().copied().collect())
                    .unwrap_or_default();
                let removing: HashSet<i64> = remove.iter().copied().collect();
                let members: Vec<(i64, i64)> = snapshot
                    .membership
                    .iter()
                    .filter(|(s, g)| in_cat.contains(g) && !removing.contains(s))
                    .map(|(&s, &g)| (s, g))
                    .collect();
                let mut wanted: Vec<i64> = members.iter().map(|m| m.0).collect();
                wanted.extend(add);
                let (ids, x) = vectors(&db, &wanted)?;
                let row: HashMap<i64, usize> = ids.iter().enumerate().map(|(r, &id)| (id, r)).collect();
                let mut by_group: BTreeMap<i64, Vec<usize>> = BTreeMap::new();
                for (s, g) in &members {
                    if let Some(&r) = row.get(s) {
                        by_group.entry(*g).or_default().push(r);
                    }
                }
                let mut joined = Vec::new();
                for id in add {
                    let (Some(&r), Some(s)) = (row.get(id), by_id.get(id)) else {
                        continue;
                    };
                    if let Some(g) = groups::nearest(&x[r * D..(r + 1) * D], &x, D, &by_group) {
                        joined.push((*id, s.fingerprint.clone(), g));
                    }
                }
                db.update_groups(cat_id, &joined, remove).map_err(error)?;
            }
        }
    }
    Ok(regrouped)
}
