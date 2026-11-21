//! Earmark for Windows and Linux (docs/rust-engine-plan.md, step 9). The Rust engine reads the
//! libraries, keeps the database, searches, groups and maps the sounds; this shell owns the
//! window's side: dialogs, playing files, scanning in the background. The window (`../ui`) draws
//! what the commands return. Searching, a sound's details, Find Similar, timeline files and
//! DaVinci Resolve go through the same tools as the MCP server agents use (`earmark_mcp`), so they
//! answer exactly as there.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod analysis;

use earmark_core::analysis::linalg::Floats;
use earmark_core::analysis::sound_map;
use earmark_core::analysis_file::AnalysisFile;
use earmark_core::records::{SongFile, SoundRecord};
use earmark_core::scan;
use earmark_core::ucs::UcsCatalog;
use earmark_db::LibraryDatabase;
use earmark_db::catalog::{Filter, SoundCatalog};
use earmark_mcp::{EarmarkTools, Outside};
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt as _;
use tauri_plugin_opener::OpenerExt as _;

struct App {
    path: PathBuf,
    /// Writes (libraries, scans, imported analysis).
    db: Mutex<LibraryDatabase>,
    /// Reads, as the MCP server makes them; read again when the database changed.
    tools: EarmarkTools,
    /// The catalog the list is drawn from, made again after each change.
    catalog: Mutex<Option<Arc<SoundCatalog>>>,
    scanning: AtomicBool,
    analysing: AtomicBool,
    /// Asks the analysis to stop after the file it's on.
    stop: AtomicBool,
    /// The last map made, by its scope.
    map: Mutex<Option<(String, Value)>>,
}

fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}

impl App {
    fn catalog(&self) -> Result<Arc<SoundCatalog>, String> {
        let mut slot = self.catalog.lock().map_err(error)?;
        if let Some(c) = slot.as_ref() {
            return Ok(c.clone());
        }
        let db = self.db.lock().map_err(error)?;
        let fresh = Arc::new(SoundCatalog::new(&db).map_err(error)?);
        *slot = Some(fresh.clone());
        Ok(fresh)
    }

    fn changed(&self) {
        if let Ok(mut c) = self.catalog.lock() {
            *c = None;
        }
        if let Ok(mut m) = self.map.lock() {
            *m = None;
        }
    }

    fn tool(&self, name: &str, arguments: Value) -> Result<Value, String> {
        let arguments: Map<String, Value> = match arguments {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        let answer = self.tools.call(name, &arguments);
        if answer.is_error {
            return Err(answer.text);
        }
        Ok(answer
            .structured
            .unwrap_or_else(|| serde_json::from_str(&answer.text).unwrap_or(Value::Null)))
    }
}

// MARK: what the window shows

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LibraryInfo {
    id: i64,
    kind: String,
    name: String,
    path: String,
    online: bool,
    count: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Subcategory {
    label: String,
    cat_id: String,
    count: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Category {
    name: String,
    count: usize,
    subcategories: Vec<Subcategory>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    libraries: Vec<LibraryInfo>,
    sounds: usize,
    songs: usize,
    analysed: usize,
    duplicates: usize,
    categories: Vec<Category>,
    scanning: bool,
    database: String,
}

#[tauri::command]
fn snapshot(app: State<'_, App>) -> Result<Snapshot, String> {
    snapshot_of(&app)
}

fn snapshot_of(app: &App) -> Result<Snapshot, String> {
    let c = app.catalog()?;
    let shown: Vec<&SoundRecord> = c.sounds.iter().filter(|s| c.is_shown(s)).collect();
    let mut by_library: HashMap<i64, usize> = HashMap::new();
    for s in &shown {
        *by_library.entry(s.library_id).or_default() += 1;
    }
    let songs = app.db.lock().map_err(error)?.songs(None).map_err(error)?;
    for s in &songs {
        *by_library.entry(s.library_id).or_default() += 1;
    }
    // Category → its count and its subcategories (label → CatID and count).
    type Subs = BTreeMap<String, (String, usize)>;
    let mut cats: BTreeMap<String, (usize, Subs)> = BTreeMap::new();
    for s in &shown {
        let (Some(category), Some(cat_id)) = (&s.category, &s.cat_id) else {
            continue;
        };
        let entry = cats.entry(category.clone()).or_default();
        entry.0 += 1;
        let sub = s.subcategory.clone().unwrap_or_default();
        let e = entry.1.entry(sub).or_insert((cat_id.clone(), 0));
        e.1 += 1;
    }
    let catalog = UcsCatalog::shared();
    Ok(Snapshot {
        libraries: c
            .libraries
            .iter()
            .map(|l| LibraryInfo {
                id: l.id,
                kind: l.kind.clone(),
                name: l.name(),
                path: l.path.clone(),
                online: l.is_online(),
                count: by_library.get(&l.id).copied().unwrap_or(0),
            })
            .collect(),
        sounds: shown.len(),
        songs: songs.len(),
        analysed: c.analysed.len(),
        duplicates: c.duplicates.set_of.len(),
        categories: cats
            .into_iter()
            .map(|(name, (count, subs))| Category {
                name: catalog
                    .entries
                    .iter()
                    .find(|e| e.category == name)
                    .map_or(name.clone(), |e| e.category.clone()),
                count,
                subcategories: subs
                    .into_iter()
                    .map(|(label, (cat_id, count))| Subcategory {
                        label,
                        cat_id,
                        count,
                    })
                    .collect(),
            })
            .collect(),
        scanning: app.scanning.load(Ordering::Relaxed),
        database: app.path.to_string_lossy().into_owned(),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Row {
    id: i64,
    name: String,
    category: String,
    length: Option<f64>,
    folder: String,
    format: String,
    path: String,
}

#[derive(Serialize)]
struct Page {
    total: usize,
    rows: Vec<Row>,
}

/// One page of the list: the sounds matching `query`, in a category ("FOOTSTEPS", "FEETHmn"), a
/// group, a library, or the duplicates.
#[tauri::command]
#[allow(clippy::too_many_arguments)]
fn sounds(
    app: State<'_, App>,
    query: Option<String>,
    category: Option<String>,
    group_id: Option<i64>,
    library_id: Option<i64>,
    duplicates: Option<bool>,
    offset: usize,
    limit: usize,
) -> Result<Page, String> {
    let filter = Filter {
        query: query.filter(|q| !q.trim().is_empty()),
        category,
        group_id,
        library_id,
        ..Filter::default()
    };
    sounds_of(&app, &filter, duplicates == Some(true), offset, limit)
}

fn sounds_of(
    app: &App,
    filter: &Filter,
    duplicates: bool,
    offset: usize,
    limit: usize,
) -> Result<Page, String> {
    let c = app.catalog()?;
    let mut found: Vec<&SoundRecord> = c.search(filter);
    if duplicates {
        found.retain(|s| s.id.is_some_and(|id| c.duplicates.set_of.contains_key(&id)));
        found.sort_by_key(|s| s.id.and_then(|id| c.duplicates.set_of.get(&id).copied()));
    }
    Ok(Page {
        total: found.len(),
        rows: found
            .iter()
            .skip(offset)
            .take(limit)
            .map(|s| Row {
                id: s.id.unwrap_or_default(),
                name: s.display_name(),
                category: s.ucs_label().unwrap_or_default(),
                length: s.duration,
                folder: s.path_in_library(),
                format: s.format_text(),
                path: s.path.clone(),
            })
            .collect(),
    })
}

/// A sound's details, as the MCP server's `get_sound`.
#[tauri::command]
fn sound(app: State<'_, App>, id: i64) -> Result<Value, String> {
    app.tool("get_sound", json!({ "sound_id": id }))
}

/// The sounds most like it, as `find_similar`.
#[tauri::command]
fn similar(app: State<'_, App>, id: i64) -> Result<Value, String> {
    app.tool("find_similar", json!({ "sound_id": id, "limit": 50 }))
}

/// A subcategory's similarity groups, as `list_groups`.
#[tauri::command]
fn groups(app: State<'_, App>, cat_id: String) -> Result<Value, String> {
    app.tool("list_groups", json!({ "category": cat_id }))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SongRow {
    id: i64,
    title: String,
    artist: Option<String>,
    album: Option<String>,
    length: Option<f64>,
    bpm: Option<f64>,
    key: Option<String>,
    path: String,
}

#[tauri::command]
fn songs(app: State<'_, App>, query: Option<String>) -> Result<Vec<SongRow>, String> {
    songs_of(&app, query)
}

fn songs_of(app: &App, query: Option<String>) -> Result<Vec<SongRow>, String> {
    let all = app.db.lock().map_err(error)?.songs(None).map_err(error)?;
    let words: Vec<String> = query
        .unwrap_or_default()
        .to_lowercase()
        .split_whitespace()
        .map(String::from)
        .collect();
    Ok(all
        .into_iter()
        .filter(|s| {
            let text = format!(
                "{} {} {} {}",
                s.title.as_deref().unwrap_or(""),
                s.artist.as_deref().unwrap_or(""),
                s.album.as_deref().unwrap_or(""),
                s.file_name
            )
            .to_lowercase();
            words.iter().all(|w| text.contains(w.as_str()))
        })
        .map(|s| SongRow {
            id: s.id.unwrap_or_default(),
            title: s
                .title
                .clone()
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| file_stem(&s.file_name)),
            key: s.key().map(|k| k.name()),
            artist: s.artist,
            album: s.album,
            length: s.duration,
            bpm: s.bpm,
            path: s.path,
        })
        .collect())
}

fn file_stem(name: &str) -> String {
    Path::new(name)
        .file_stem()
        .map_or_else(|| name.to_string(), |s| s.to_string_lossy().into_owned())
}

// MARK: libraries

/// Asks for a folder and adds it as a sound library or music folder, then reads it.
#[tauri::command]
async fn add_library(handle: AppHandle, kind: String) -> Result<bool, String> {
    let picked = handle.dialog().file().blocking_pick_folder();
    let Some(folder) = picked.and_then(|f| f.into_path().ok()) else {
        return Ok(false);
    };
    let app = handle.state::<App>();
    let library = {
        let db = app.db.lock().map_err(error)?;
        db.add_library(&kind, &folder.to_string_lossy(), None)
            .map_err(error)?
    };
    app.changed();
    allow_playing(&handle, &folder);
    start_scan(handle.clone(), vec![library.id]);
    Ok(true)
}

#[tauri::command]
fn remove_library(app: State<'_, App>, id: i64) -> Result<(), String> {
    app.db
        .lock()
        .map_err(error)?
        .remove_library(id)
        .map_err(error)?;
    app.changed();
    Ok(())
}

/// Reads the libraries again (all, or one).
#[tauri::command]
fn rescan(handle: AppHandle, app: State<'_, App>, id: Option<i64>) -> Result<(), String> {
    let ids = match id {
        Some(id) => vec![id],
        None => app.catalog()?.libraries.iter().map(|l| l.id).collect(),
    };
    start_scan(handle, ids);
    Ok(())
}

fn start_scan(handle: AppHandle, ids: Vec<i64>) {
    let app = handle.state::<App>();
    if app.scanning.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let app = handle.state::<App>();
        let result = scan_libraries(&handle, &app, &ids);
        app.scanning.store(false, Ordering::SeqCst);
        app.changed();
        let _ = handle.emit("scanned", result.err());
    });
}

fn scan_libraries(handle: &AppHandle, app: &App, ids: &[i64]) -> Result<(), String> {
    let libraries = app
        .db
        .lock()
        .map_err(error)?
        .libraries(None)
        .map_err(error)?;
    for library in libraries.iter().filter(|l| ids.contains(&l.id)) {
        if !library.is_online() {
            continue;
        }
        let name = library.name();
        let root = Path::new(&library.path);
        let progress = |done: usize, total: usize| {
            if done == total || done.is_multiple_of(25) {
                let _ = handle.emit(
                    "progress",
                    json!({ "name": name, "done": done, "total": total }),
                );
            }
        };
        if library.kind == "music" {
            let files = scan::list_audio_files(root);
            let mut songs = Vec::with_capacity(files.len());
            for (i, path) in files.iter().enumerate() {
                songs.push(song_file(path));
                progress(i + 1, files.len());
            }
            let known = app
                .db
                .lock()
                .map_err(error)?
                .songs(Some(library.id))
                .map_err(error)?
                .len();
            if songs.is_empty() && known > 0 {
                continue; // The folder is empty for now: keep what's known.
            }
            app.db
                .lock()
                .map_err(error)?
                .replace_songs(library.id, &library.path, &songs)
                .map_err(error)?;
        } else {
            let fallback = |p: &Path| earmark_audio::technical(p);
            let found = scan::scan(root, UcsCatalog::shared(), 8, Some(&fallback), &progress);
            let known = app
                .db
                .lock()
                .map_err(error)?
                .sounds(Some(library.id))
                .map_err(error)?
                .len();
            if found.is_empty() && known > 0 {
                continue;
            }
            app.db
                .lock()
                .map_err(error)?
                .replace_sounds(library.id, &library.path, &found)
                .map_err(error)?;
        }
    }
    Ok(())
}

/// A song as found on disk. Its length from the audio; the Mac reads titles, artists and albums
/// from the tags, which the engine doesn't read yet, so the file's name stands in.
fn song_file(path: &Path) -> SongFile {
    let meta = std::fs::metadata(path).ok();
    let modified = meta
        .as_ref()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64());
    SongFile {
        path: path.to_string_lossy().into_owned(),
        file_size: meta.map_or(0, |m| m.len() as i64),
        modified,
        title: None,
        artist: None,
        album: None,
        duration: earmark_audio::technical(path).and_then(|t| t.duration),
    }
}

// MARK: analysing

/// Measures loudness, listens with the two models (if installed in the data folder's Models) and
/// groups similar sounds, in the background. "analysis" events say how far it is; "analysed" when
/// it ends.
#[tauri::command]
fn analyse(handle: AppHandle) {
    let app = handle.state::<App>();
    if app.analysing.swap(true, Ordering::SeqCst) {
        return;
    }
    app.stop.store(false, Ordering::SeqCst);
    std::thread::spawn(move || {
        let app = handle.state::<App>();
        let report = |what: &str, done: usize, total: usize| {
            let _ = handle.emit(
                "analysis",
                json!({ "what": what, "done": done, "total": total }),
            );
        };
        let progress = analysis::Progress {
            report: &report,
            stop: &app.stop,
        };
        let result = analysis::run(&app.db, &app.path, &progress);
        app.analysing.store(false, Ordering::SeqCst);
        app.changed();
        let _ = handle.emit(
            "analysed",
            result.unwrap_or_else(|e| format!("Analysis stopped: {e}")),
        );
    });
}

#[tauri::command]
fn stop_analysis(app: State<'_, App>) {
    app.stop.store(true, Ordering::SeqCst);
}

/// Where the models go, for the window to say.
#[tauri::command]
fn models_folder(app: State<'_, App>) -> String {
    analysis::models_folder(&app.path)
        .to_string_lossy()
        .into_owned()
}

// MARK: analysis files

/// Brings in an analysis file exported by Earmark on another computer (a Mac's included).
#[tauri::command]
async fn import_analysis(handle: AppHandle) -> Result<Value, String> {
    let picked = handle
        .dialog()
        .file()
        .add_filter("Earmark analysis", &["json"])
        .blocking_pick_file();
    let Some(path) = picked.and_then(|f| f.into_path().ok()) else {
        return Ok(Value::Null);
    };
    let data = std::fs::read(&path).map_err(error)?;
    let file = AnalysisFile::read(&data).map_err(error)?;
    let app = handle.state::<App>();
    let report = app
        .db
        .lock()
        .map_err(error)?
        .import_analysis(&file, &|p: &Path| scan::fingerprint(p))
        .map_err(error)?;
    app.changed();
    serde_json::to_value(report).map_err(error)
}

// MARK: map

/// Every analysed sound in scope as a point on the sound map (both models' vectors), with links
/// between neighbours. Takes a while for a whole library: made off the window's thread.
#[tauri::command]
async fn sound_map(app: State<'_, App>, category: Option<String>) -> Result<Value, String> {
    sound_map_of(&app, category)
}

fn sound_map_of(app: &App, category: Option<String>) -> Result<Value, String> {
    let scope = category.clone().unwrap_or_default();
    if let Some((s, v)) = app.map.lock().map_err(error)?.as_ref()
        && *s == scope
    {
        return Ok(v.clone());
    }
    let c = app.catalog()?;
    let wanted: HashMap<i64, &SoundRecord> = c
        .search(&Filter {
            category: category.clone(),
            ..Filter::default()
        })
        .into_iter()
        .filter_map(|s| s.id.map(|id| (id, s)))
        .collect();
    let mut ids: Vec<i64> = Vec::new();
    let mut rows: Vec<f32> = Vec::new();
    let mut d = 0;
    {
        let db = app.db.lock().map_err(error)?;
        db.for_each_vectors(
            &["pe-av-large", "clap-general"],
            None,
            &mut |_| {},
            &mut |id, blocks| {
                if !wanted.contains_key(&id) {
                    return;
                }
                let refs: Vec<&[f32]> = blocks.iter().map(Vec::as_slice).collect();
                let v = sound_map::combine(&refs);
                d = v.len();
                rows.extend(v);
                ids.push(id);
            },
        )
        .map_err(error)?;
    }
    let mut x = Floats::page(rows.len());
    x.copy_from_slice(&rows);
    drop(rows);
    let map = sound_map::map(
        &x,
        ids.len(),
        d,
        &sound_map::Settings::default(),
        3,
        &|_| {},
        &|| false,
    )
    .ok_or("The map was stopped.")?;
    let points: Vec<Value> = ids
        .iter()
        .zip(&map.points)
        .map(|(id, p)| {
            let s = wanted[id];
            json!([
                id,
                p[0],
                p[1],
                s.category.clone().unwrap_or_default(),
                s.display_name()
            ])
        })
        .collect();
    let value = json!({ "points": points, "links": map.links });
    *app.map.lock().map_err(error)? = Some((scope, value.clone()));
    Ok(value)
}

// MARK: putting sounds to use

/// Saves the sounds as a timeline file (FCPXML) in the Videos folder's Earmark folder, as the
/// `save_timeline_file` tool, and shows it.
#[tauri::command]
fn save_timeline(
    handle: AppHandle,
    app: State<'_, App>,
    ids: Vec<i64>,
    frame_rate: String,
) -> Result<Value, String> {
    let items: Vec<Value> = ids.iter().map(|id| json!({ "sound_id": id })).collect();
    let saved = app.tool(
        "save_timeline_file",
        json!({ "items": items, "frame_rate": frame_rate }),
    )?;
    if let Some(path) = saved.get("path").and_then(Value::as_str) {
        let _ = handle.opener().reveal_item_in_dir(path);
    }
    Ok(saved)
}

/// Puts a sound on the timeline open in DaVinci Resolve Studio, as `add_to_resolve`.
#[tauri::command]
async fn add_to_resolve(app: State<'_, App>, id: i64) -> Result<Value, String> {
    app.tool(
        "add_to_resolve",
        json!({ "items": [{ "sound_id": id, "track": "free" }] }),
    )
}

#[tauri::command]
fn reveal(handle: AppHandle, path: String) -> Result<(), String> {
    handle.opener().reveal_item_in_dir(path).map_err(error)
}

// MARK: playing

/// Files inside the libraries may be read by the window (to play them), nothing else.
fn allow_playing(handle: &AppHandle, folder: &Path) {
    let _ = handle.asset_protocol_scope().allow_directory(folder, true);
}

/// `earmark-desktop --check`: the window's commands without the window, on the database
/// EARMARK_DATABASE names (a copy), printing what they return. For testing on a computer where the
/// window can't be driven.
fn check() -> Result<(), String> {
    let path = earmark_mcp::default_database_path();
    let app = App {
        tools: EarmarkTools::new(path.clone(), Outside::live()),
        db: Mutex::new(LibraryDatabase::open(Some(&path), false).map_err(error)?),
        path,
        catalog: Mutex::new(None),
        scanning: AtomicBool::new(false),
        analysing: AtomicBool::new(false),
        stop: AtomicBool::new(false),
        map: Mutex::new(None),
    };
    let started = std::time::Instant::now();
    let snap = snapshot_of(&app)?;
    println!(
        "snapshot: {} libraries, {} sounds, {} songs, {} analysed, {} in duplicates, {} categories ({:?})",
        snap.libraries.len(),
        snap.sounds,
        snap.songs,
        snap.analysed,
        snap.duplicates,
        snap.categories.len(),
        started.elapsed()
    );
    let all = sounds_of(&app, &Filter::default(), false, 0, 3)?;
    println!(
        "all sounds: {} — first: {:?}",
        all.total,
        all.rows.iter().map(|r| &r.name).collect::<Vec<_>>()
    );
    for (label, filter) in [
        (
            "“door”",
            Filter {
                query: Some("door".into()),
                ..Filter::default()
            },
        ),
        (
            "DOORS",
            Filter {
                category: Some("DOORS".into()),
                ..Filter::default()
            },
        ),
        (
            "DOORWood",
            Filter {
                category: Some("DOORWood".into()),
                ..Filter::default()
            },
        ),
    ] {
        println!(
            "{label}: {} sounds",
            sounds_of(&app, &filter, false, 0, 1)?.total
        );
    }
    let dups = sounds_of(&app, &Filter::default(), true, 0, 2)?;
    println!("duplicates: {} sounds", dups.total);
    if let Some(first) = all.rows.first() {
        let details = app.tool("get_sound", json!({ "sound_id": first.id }))?;
        println!(
            "get_sound {}: {}",
            first.id,
            details.to_string().chars().take(160).collect::<String>()
        );
        let similar = app.tool("find_similar", json!({ "sound_id": first.id, "limit": 3 }))?;
        let names: Vec<&str> = similar["similar"]
            .as_array()
            .map(|a| a.iter().filter_map(|r| r["name"].as_str()).collect())
            .unwrap_or_default();
        println!("find_similar {}: {names:?}", first.id);
    }
    let songs = songs_of(&app, None)?;
    println!(
        "songs: {} — first: {:?}",
        songs.len(),
        songs.first().map(|s| (&s.title, s.bpm, &s.key))
    );
    let started = std::time::Instant::now();
    let map = sound_map_of(&app, Some("DOORS".into()))?;
    println!(
        "map of DOORS: {} points, {} links ({:?})",
        map["points"].as_array().map_or(0, Vec::len),
        map["links"].as_array().map_or(0, Vec::len),
        started.elapsed()
    );
    Ok(())
}

fn main() {
    if std::env::args().any(|a| a == "--analyse") {
        // The analysis without the window, on the database EARMARK_DATABASE names (a copy).
        let path = earmark_mcp::default_database_path();
        let db = match LibraryDatabase::open(Some(&path), false) {
            Ok(db) => Mutex::new(db),
            Err(e) => {
                eprintln!("earmark-desktop --analyse: {e}");
                std::process::exit(1);
            }
        };
        let stop = AtomicBool::new(false);
        let report = |what: &str, done: usize, total: usize| {
            if done == total || done.is_multiple_of(10) {
                println!("{what}: {done} of {total}");
            }
        };
        let progress = analysis::Progress {
            report: &report,
            stop: &stop,
        };
        match analysis::run(&db, &path, &progress) {
            Ok(said) => println!("{said}"),
            Err(e) => {
                eprintln!("earmark-desktop --analyse: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    if std::env::args().any(|a| a == "--check") {
        if let Err(e) = check() {
            eprintln!("earmark-desktop --check: {e}");
            std::process::exit(1);
        }
        return;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let handle = app.handle();
            // As the MCP server: %APPDATA%\Earmark on Windows, ~/.local/share/Earmark on Linux
            // (EARMARK_DATABASE for a test run on a copy).
            let path = earmark_mcp::default_database_path();
            let db = LibraryDatabase::open(Some(&path), false)?;
            for library in db.libraries(None)? {
                allow_playing(handle, Path::new(&library.path));
            }
            app.manage(App {
                tools: EarmarkTools::new(path.clone(), Outside::live()),
                path,
                db: Mutex::new(db),
                catalog: Mutex::new(None),
                scanning: AtomicBool::new(false),
                analysing: AtomicBool::new(false),
                stop: AtomicBool::new(false),
                map: Mutex::new(None),
            });
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            snapshot,
            sounds,
            sound,
            similar,
            groups,
            songs,
            add_library,
            remove_library,
            rescan,
            import_analysis,
            analyse,
            stop_analysis,
            models_folder,
            sound_map,
            save_timeline,
            add_to_resolve,
            reveal,
        ])
        .run(tauri::generate_context!())
        .expect("Earmark couldn't start");
}
