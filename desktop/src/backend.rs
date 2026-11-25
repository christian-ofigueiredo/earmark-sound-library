//! What the window shows and does, on the Rust engine: the libraries, the list, a sound's details,
//! Find Similar, the map, scanning and analysing in the background, timeline files and DaVinci
//! Resolve. Searching, a sound's details, Find Similar, timeline files and Resolve go through the
//! same tools as the MCP server agents use (`earmark_mcp`), so they answer exactly as there.
//! (The same calls the Tauri window made, without the web layer.)

use crate::analysis;
use earmark_core::analysis::linalg::Floats;
use earmark_core::analysis::sound_map;
use earmark_core::analysis_file::AnalysisFile;
use earmark_core::records::{SongFile, SoundRecord};
use earmark_core::scan;
use earmark_core::ucs::UcsCatalog;
use earmark_db::LibraryDatabase;
use earmark_db::catalog::{Filter, SoundCatalog};
use earmark_mcp::{EarmarkTools, Outside};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

pub fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// What the background work tells the window.
pub enum Event {
    /// Reading a library: its name, files done, files in all.
    Progress(String, usize, usize),
    /// Reading ended (with the problem, if any).
    Scanned(Option<String>),
    /// Analysing: the step, done, in all.
    Analysis(String, usize, usize),
    /// Analysis ended: what it says.
    Analysed(String),
    /// Find Similar's answer for a sound.
    Similar(i64, Result<Vec<serde_json::Value>, String>),
    /// A map made for a scope.
    Map(String, Result<Arc<SoundMap>, String>),
    /// DaVinci Resolve's answer, or a timeline file saved: a line for the status bar.
    Said(String),
    /// A problem worth a dialog.
    Problem(String),
}

pub struct Backend {
    pub path: PathBuf,
    /// Writes (libraries, scans, imported analysis).
    db: Mutex<LibraryDatabase>,
    /// Reads, as the MCP server makes them.
    tools: EarmarkTools,
    /// The catalog the list is drawn from, made again after each change.
    catalog: Mutex<Option<Arc<SoundCatalog>>>,
    pub scanning: AtomicBool,
    pub analysing: AtomicBool,
    /// Asks the analysis to stop after the file it's on.
    stop: AtomicBool,
    /// The last map made, by its scope.
    map: Mutex<Option<(String, Arc<SoundMap>)>>,
}

#[derive(Clone)]
pub struct LibraryInfo {
    pub id: i64,
    pub music: bool,
    pub name: String,
    pub path: String,
    pub online: bool,
    pub count: usize,
}

#[derive(Clone)]
pub struct Subcategory {
    pub label: String,
    pub cat_id: String,
    pub count: usize,
}

#[derive(Clone)]
pub struct Category {
    pub name: String,
    pub count: usize,
    pub subcategories: Vec<Subcategory>,
}

#[derive(Clone, Default)]
pub struct Snapshot {
    pub libraries: Vec<LibraryInfo>,
    pub sounds: usize,
    pub songs: usize,
    pub analysed: usize,
    pub duplicates: usize,
    pub categories: Vec<Category>,
}

#[derive(Clone)]
pub struct Row {
    pub id: i64,
    pub name: String,
    pub category: String,
    pub length: Option<f64>,
    pub folder: String,
    pub format: String,
    pub path: String,
}

#[derive(Clone)]
pub struct SongRow {
    pub id: i64,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub length: Option<f64>,
    pub bpm: Option<f64>,
    pub key: Option<String>,
    pub path: String,
}

/// Which sounds the list shows.
#[derive(Clone, PartialEq, Debug, Default)]
pub enum Scope {
    #[default]
    All,
    Library(i64),
    Duplicates,
    /// A category ("DOORS") or a subcategory's CatID ("DOORWood").
    Category(String),
}

pub struct MapPoint {
    pub id: i64,
    pub x: f32,
    pub y: f32,
    pub category: String,
    pub name: String,
}

pub struct SoundMap {
    pub points: Vec<MapPoint>,
}

fn file_stem(name: &str) -> String {
    Path::new(name)
        .file_stem()
        .map_or_else(|| name.to_string(), |s| s.to_string_lossy().into_owned())
}

impl Backend {
    /// The database the MCP server uses: %APPDATA%\Earmark on Windows, ~/.local/share/Earmark on
    /// Linux (EARMARK_DATABASE for a test run on a copy).
    pub fn open() -> Result<Self, String> {
        let path = earmark_mcp::default_database_path();
        let db = LibraryDatabase::open(Some(&path), false).map_err(error)?;
        Ok(Backend {
            tools: EarmarkTools::new(path.clone(), Outside::live()),
            path,
            db: Mutex::new(db),
            catalog: Mutex::new(None),
            scanning: AtomicBool::new(false),
            analysing: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            map: Mutex::new(None),
        })
    }

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

    /// Forgets what was read from the database, after a change.
    pub fn changed(&self) {
        if let Ok(mut c) = self.catalog.lock() {
            *c = None;
        }
        if let Ok(mut m) = self.map.lock() {
            *m = None;
        }
    }

    pub fn tool(&self, name: &str, arguments: Value) -> Result<Value, String> {
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

    // MARK: what the window shows

    pub fn snapshot(&self) -> Result<Snapshot, String> {
        let c = self.catalog()?;
        let shown: Vec<&SoundRecord> = c.sounds.iter().filter(|s| c.is_shown(s)).collect();
        let mut by_library: HashMap<i64, usize> = HashMap::new();
        for s in &shown {
            *by_library.entry(s.library_id).or_default() += 1;
        }
        let songs = self.db.lock().map_err(error)?.songs(None).map_err(error)?;
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
        let ucs = UcsCatalog::shared();
        Ok(Snapshot {
            libraries: c
                .libraries
                .iter()
                .map(|l| LibraryInfo {
                    id: l.id,
                    music: l.kind == "music",
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
                    name: ucs
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
        })
    }

    /// Every sound matching `query` in the scope (the list draws only the rows on screen).
    pub fn sounds(&self, scope: &Scope, query: &str) -> Result<Vec<Row>, String> {
        let filter = Filter {
            query: Some(query.trim().to_string()).filter(|q| !q.is_empty()),
            category: match scope {
                Scope::Category(c) => Some(c.clone()),
                _ => None,
            },
            library_id: match scope {
                Scope::Library(id) => Some(*id),
                _ => None,
            },
            ..Filter::default()
        };
        let c = self.catalog()?;
        let mut found: Vec<&SoundRecord> = c.search(&filter);
        if *scope == Scope::Duplicates {
            found.retain(|s| s.id.is_some_and(|id| c.duplicates.set_of.contains_key(&id)));
            found.sort_by_key(|s| s.id.and_then(|id| c.duplicates.set_of.get(&id).copied()));
        }
        Ok(found
            .iter()
            .map(|s| Row {
                id: s.id.unwrap_or_default(),
                name: s.display_name(),
                category: s.ucs_label().unwrap_or_default(),
                length: s.duration,
                folder: s.path_in_library(),
                format: s.format_text(),
                path: s.path.clone(),
            })
            .collect())
    }

    pub fn songs(&self, scope: &Scope, query: &str) -> Result<Vec<SongRow>, String> {
        let library = match scope {
            Scope::Library(id) => Some(*id),
            _ => None,
        };
        let all = self
            .db
            .lock()
            .map_err(error)?
            .songs(library)
            .map_err(error)?;
        let words: Vec<String> = query
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

    // MARK: libraries

    pub fn add_library(&self, music: bool, folder: &Path) -> Result<i64, String> {
        let kind = if music { "music" } else { "sounds" };
        let library = self
            .db
            .lock()
            .map_err(error)?
            .add_library(kind, &folder.to_string_lossy(), None)
            .map_err(error)?;
        self.changed();
        Ok(library.id)
    }

    pub fn remove_library(&self, id: i64) -> Result<(), String> {
        self.db
            .lock()
            .map_err(error)?
            .remove_library(id)
            .map_err(error)?;
        self.changed();
        Ok(())
    }

    pub fn library_ids(&self) -> Vec<i64> {
        self.catalog()
            .map(|c| c.libraries.iter().map(|l| l.id).collect())
            .unwrap_or_default()
    }

    /// Reads the libraries again, on a thread of its own; `tell` hears how far it is.
    pub fn start_scan(
        self: &Arc<Self>,
        ids: Vec<i64>,
        tell: impl Fn(Event) + Send + Sync + 'static,
    ) {
        if self.scanning.swap(true, Ordering::SeqCst) {
            return;
        }
        let me = self.clone();
        std::thread::spawn(move || {
            let result = me.scan_libraries(&ids, &tell);
            me.scanning.store(false, Ordering::SeqCst);
            me.changed();
            tell(Event::Scanned(result.err()));
        });
    }

    fn scan_libraries(&self, ids: &[i64], tell: &(dyn Fn(Event) + Sync)) -> Result<(), String> {
        let libraries = self
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
                    tell(Event::Progress(name.clone(), done, total));
                }
            };
            if library.kind == "music" {
                let files = scan::list_audio_files(root);
                let mut songs = Vec::with_capacity(files.len());
                for (i, path) in files.iter().enumerate() {
                    songs.push(song_file(path));
                    progress(i + 1, files.len());
                }
                let known = self
                    .db
                    .lock()
                    .map_err(error)?
                    .songs(Some(library.id))
                    .map_err(error)?
                    .len();
                if songs.is_empty() && known > 0 {
                    continue; // The folder is empty for now: keep what's known.
                }
                self.db
                    .lock()
                    .map_err(error)?
                    .replace_songs(library.id, &library.path, &songs)
                    .map_err(error)?;
            } else {
                let fallback = |p: &Path| earmark_audio::technical(p);
                let found = scan::scan(root, UcsCatalog::shared(), 8, Some(&fallback), &progress);
                let known = self
                    .db
                    .lock()
                    .map_err(error)?
                    .sounds(Some(library.id))
                    .map_err(error)?
                    .len();
                if found.is_empty() && known > 0 {
                    continue;
                }
                self.db
                    .lock()
                    .map_err(error)?
                    .replace_sounds(library.id, &library.path, &found)
                    .map_err(error)?;
            }
        }
        Ok(())
    }

    // MARK: analysing

    /// Measures loudness, listens with the two models (if installed in the data folder's
    /// Models) and groups similar sounds, on a thread of its own.
    pub fn start_analysis(self: &Arc<Self>, tell: impl Fn(Event) + Send + Sync + 'static) {
        if self.analysing.swap(true, Ordering::SeqCst) {
            return;
        }
        self.stop.store(false, Ordering::SeqCst);
        let me = self.clone();
        std::thread::spawn(move || {
            let report = |what: &str, done: usize, total: usize| {
                tell(Event::Analysis(what.to_string(), done, total));
            };
            let progress = analysis::Progress {
                report: &report,
                stop: &me.stop,
            };
            let result = analysis::run(&me.db, &me.path, &progress);
            me.analysing.store(false, Ordering::SeqCst);
            me.changed();
            let mut said = result.unwrap_or_else(|e| format!("Analysis stopped: {e}"));
            if said.contains("no models in") {
                said += &format!(
                    " To add them, put CLAPAudio.onnx and the PEAV folder in {}.",
                    me.models_folder().display()
                );
            }
            tell(Event::Analysed(said));
        });
    }

    pub fn stop_analysis(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }

    pub fn models_folder(&self) -> PathBuf {
        analysis::models_folder(&self.path)
    }

    // MARK: analysis files

    /// Brings in an analysis file exported by Earmark on another computer (a Mac's included).
    pub fn import_analysis(&self, path: &Path) -> Result<String, String> {
        let data = std::fs::read(path).map_err(error)?;
        let file = AnalysisFile::read(&data).map_err(error)?;
        let report = self
            .db
            .lock()
            .map_err(error)?
            .import_analysis(&file, &|p: &Path| scan::fingerprint(p))
            .map_err(error)?;
        self.changed();
        let r = serde_json::to_value(report).map_err(error)?;
        let n = |k: &str| crate::ui::number(r[k].as_u64().unwrap_or(0) as usize);
        Ok(format!(
            "Imported: {} sounds matched, {} loudness values, {} sound vectors, {} song analyses.",
            n("soundsMatched"),
            n("facts"),
            n("embeddings"),
            n("songAnalyses")
        ))
    }

    // MARK: map

    /// Every analysed sound in scope as a point on the sound map (both models' vectors). Takes a
    /// while for a whole library: call it off the window's thread.
    pub fn sound_map(&self, category: Option<String>) -> Result<Arc<SoundMap>, String> {
        let scope = category.clone().unwrap_or_default();
        if let Some((s, v)) = self.map.lock().map_err(error)?.as_ref()
            && *s == scope
        {
            return Ok(v.clone());
        }
        let c = self.catalog()?;
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
            let db = self.db.lock().map_err(error)?;
            db.for_each_vectors(
                &[analysis::PEAV, analysis::CLAP],
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
        let points = if ids.is_empty() {
            Vec::new()
        } else {
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
            ids.iter()
                .zip(&map.points)
                .map(|(id, p)| {
                    let s = wanted[id];
                    MapPoint {
                        id: *id,
                        x: p[0],
                        y: p[1],
                        category: s.category.clone().unwrap_or_default(),
                        name: s.display_name(),
                    }
                })
                .collect()
        };
        let made = Arc::new(SoundMap { points });
        *self.map.lock().map_err(error)? = Some((scope, made.clone()));
        Ok(made)
    }

    // MARK: putting sounds to use

    /// Saves the sounds as a timeline file (FCPXML) in the Videos folder's Earmark folder, as the
    /// `save_timeline_file` tool. Answers the file's path.
    pub fn save_timeline(&self, ids: &[i64], frame_rate: &str) -> Result<String, String> {
        let items: Vec<Value> = ids.iter().map(|id| json!({ "sound_id": id })).collect();
        let saved = self.tool(
            "save_timeline_file",
            json!({ "items": items, "frame_rate": frame_rate }),
        )?;
        Ok(saved
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string())
    }

    /// Puts a sound on the timeline open in DaVinci Resolve Studio, as `add_to_resolve`.
    /// Answers a line for the status bar.
    pub fn add_to_resolve(&self, id: i64) -> Result<String, String> {
        let added = self.tool(
            "add_to_resolve",
            json!({ "items": [{ "sound_id": id, "track": "free" }] }),
        )?;
        let placed = &added["items"][0];
        Ok(if placed["ok"].as_bool() == Some(true) {
            format!(
                "Added to “{}”, track A{}",
                added["timeline"].as_str().unwrap_or("the timeline"),
                placed["track"]
            )
        } else {
            placed["problem"]
                .as_str()
                .unwrap_or("Resolve didn't place it.")
                .to_string()
        })
    }
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

/// A channel sender as a `tell` function that also wakes the window.
pub fn teller(tx: Sender<Event>, ctx: egui::Context) -> impl Fn(Event) + Send + Sync + 'static {
    let tx = Mutex::new(tx);
    move |e| {
        if let Ok(tx) = tx.lock() {
            let _ = tx.send(e);
        }
        ctx.request_repaint();
    }
}
