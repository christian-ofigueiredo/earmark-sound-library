//! The tools: what each answers from the catalog. Port of `EarmarkTools.swift`.

use earmark_core::analysis::similarity::SimilarityIndex;
use earmark_core::metadata;
use earmark_core::text::{capitalized, trim};
use earmark_core::timeline_file::{self, Clip, RATES, Rate};
use earmark_core::ucs::UcsCatalog;
use earmark_db::LibraryDatabase;
use earmark_db::SoundRecord;
use earmark_db::catalog::{Filter, SoundCatalog};
use earmark_resolve::{Added, At, Failure, Item, Status, Track};
use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

/// The user's home folder.
pub(crate) fn home_folder() -> PathBuf {
    let name = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// Places items (with `preview`, only says where they'd go).
pub type ResolveAdd = Box<dyn Fn(&[Item], bool) -> Result<Added, Failure> + Send + Sync>;

/// Ways out of the process, so tests can stand in for them.
pub struct Outside {
    /// Opens a URL (earmark://sound/<id>).
    pub open: Box<dyn Fn(&str) + Send + Sync>,
    pub resolve_status: Box<dyn Fn() -> Result<Status, Failure> + Send + Sync>,
    pub resolve_add: ResolveAdd,
    /// Where save_timeline_file writes.
    pub timeline_folder: PathBuf,
}

impl Outside {
    pub fn live() -> Outside {
        let videos = if cfg!(target_os = "macos") {
            "Movies"
        } else {
            "Videos"
        };
        Outside {
            open: Box::new(open_url),
            resolve_status: Box::new(earmark_resolve::status),
            resolve_add: Box::new(|items, preview| earmark_resolve::add(items, preview, false)),
            timeline_folder: home_folder().join(videos).join("Earmark"),
        }
    }
}

fn open_url(url: &str) {
    use std::process::{Command, Stdio};
    let mut command = if cfg!(windows) {
        let mut c = Command::new("rundll32");
        c.args(["url.dll,FileProtocolHandler", url]);
        c
    } else {
        let mut c = Command::new(if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        });
        c.arg(url);
        c
    };
    // Its output would otherwise mix into the protocol on standard output.
    let _ = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|mut child| std::thread::spawn(move || child.wait()));
}

/// A tool's answer: JSON text, the same as structured content; or a problem for the agent to read.
#[derive(Clone, Debug, PartialEq)]
pub struct Answer {
    pub text: String,
    pub structured: Option<Value>,
    pub is_error: bool,
}

/// A problem with a tool call, told to the agent.
#[derive(Debug)]
struct ToolError(String);

impl<E: std::fmt::Display> From<E> for ToolError {
    fn from(e: E) -> ToolError {
        ToolError(e.to_string())
    }
}

fn problem<T>(text: impl Into<String>) -> Result<T, ToolError> {
    Err(ToolError(text.into()))
}

/// Whole numbers without ".0", as JSONEncoder writes them.
fn plain_numbers(value: Value) -> Value {
    match value {
        Value::Number(n) => match n.as_f64() {
            Some(f) if n.is_f64() && f == f.trunc() && f.abs() < 1e15 => Value::from(f as i64),
            _ => Value::Number(n),
        },
        Value::Array(list) => Value::Array(list.into_iter().map(plain_numbers).collect()),
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(k, v)| (k, plain_numbers(v)))
                .collect(),
        ),
        other => other,
    }
}

fn encoded<T: Serialize>(value: &T) -> Result<Answer, ToolError> {
    let structured = plain_numbers(serde_json::to_value(value)?);
    Ok(Answer {
        text: serde_json::to_string(&structured)?,
        structured: Some(structured),
        is_error: false,
    })
}

/// A tool call's arguments, read leniently (agents send numbers as strings at times).
struct Arguments<'a>(&'a Map<String, Value>);

impl Arguments<'_> {
    fn string(&self, key: &str) -> Option<String> {
        match self.0.get(key)? {
            Value::String(s) if !s.is_empty() => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    }

    fn double(&self, key: &str) -> Option<f64> {
        match self.0.get(key)? {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.parse().ok(),
            _ => None,
        }
    }

    fn int(&self, key: &str) -> Option<i64> {
        match self.0.get(key)? {
            Value::Number(n) => n
                .as_i64()
                .or_else(|| n.as_f64().filter(|d| *d == d.round()).map(|d| d as i64)),
            Value::String(s) => s.parse().ok(),
            _ => None,
        }
    }

    fn bool(&self, key: &str) -> Option<bool> {
        match self.0.get(key)? {
            Value::Bool(b) => Some(*b),
            Value::String(s) => Some(matches!(s.to_lowercase().as_str(), "true" | "yes" | "1")),
            _ => None,
        }
    }

    fn list(&self, key: &str) -> Option<&Vec<Value>> {
        self.0.get(key)?.as_array()
    }
}

static NO_FIELDS: std::sync::LazyLock<Map<String, Value>> = std::sync::LazyLock::new(Map::new);

fn entry(value: &Value) -> Arguments<'_> {
    Arguments(value.as_object().unwrap_or(&NO_FIELDS))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Row {
    id: i64,
    name: String,
    file: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    #[serde(rename = "catID", skip_serializing_if = "Option::is_none")]
    cat_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    group: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    group_id: Option<i64>,
    /// Seconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    length: Option<f64>,
    format: String,
    library: String,
    folder: String,
    path: String,
    /// Integrated loudness, LUFS.
    #[serde(skip_serializing_if = "Option::is_none")]
    loudness: Option<f64>,
    /// Cosine similarity, for find_similar.
    #[serde(skip_serializing_if = "Option::is_none")]
    similarity: Option<f64>,
}

fn row(s: &SoundRecord, c: &SoundCatalog, similarity: Option<f32>) -> Row {
    let g = c.group_of(s);
    let facts = current_facts(s, c);
    Row {
        id: s.id.unwrap_or(-1),
        name: s.display_name(),
        file: s.file_name.clone(),
        category: s.ucs_label().map(|l| capitalized(&l)),
        cat_id: s.cat_id.clone(),
        group: g.map(|g| g.title().to_string()),
        group_id: g.map(|g| g.id),
        length: s.duration.map(|d| (d * 1000.0).round() / 1000.0),
        format: s.format_text(),
        library: c
            .library(s.library_id)
            .map(|l| l.name())
            .unwrap_or_default(),
        folder: s.folder.clone(),
        path: s.path.clone(),
        loudness: facts
            .and_then(|f| f.loudness)
            .map(|l| (l * 10.0).round() / 10.0),
        similarity: similarity.map(|x| (f64::from(x) * 1000.0).round() / 1000.0),
    }
}

fn current_facts<'a>(s: &SoundRecord, c: &'a SoundCatalog) -> Option<&'a earmark_db::SoundFacts> {
    c.facts.get(&s.id?).filter(|f| f.is_current(s))
}

#[derive(Serialize)]
struct LibraryInfo {
    id: i64,
    name: String,
    path: String,
    online: bool,
    sounds: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Sub {
    #[serde(rename = "catID")]
    cat_id: String,
    name: String,
    sounds: usize,
    groups: usize,
}

#[derive(Serialize)]
struct Category {
    category: String,
    sounds: usize,
    subcategories: Vec<Sub>,
}

#[derive(Serialize)]
struct Overview {
    libraries: Vec<LibraryInfo>,
    sounds: usize,
    analysed: usize,
    songs: usize,
    duplicates: usize,
    categories: Vec<Category>,
    uncategorised: usize,
}

#[derive(Serialize)]
struct Found {
    total: usize,
    offset: usize,
    sounds: Vec<Row>,
}

#[derive(Serialize)]
struct Other {
    id: i64,
    path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    similarity: Option<f64>,
}

#[derive(Serialize)]
struct GroupInfo {
    id: i64,
    name: String,
    keywords: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Details {
    sound: Row,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    keywords: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    vendor_library: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    manufacturer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    designer: Option<String>,
    category_source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    group_info: Option<GroupInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    peak: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sample_rate: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    channels: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bits_per_sample: Option<i64>,
    analysed: bool,
    online: bool,
    /// The same sound in other formats in its pack (hidden from lists).
    other_formats: Vec<String>,
    /// Byte-identical copies, and the same recording in other files.
    copies: Vec<Other>,
    same_recording: Vec<Other>,
}

#[derive(Serialize)]
struct Similar {
    sound: Row,
    similar: Vec<Row>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GroupRow {
    id: i64,
    name: String,
    keywords: Vec<String>,
    sounds: usize,
    renamed_by_owner: bool,
}

#[derive(Serialize)]
struct Groups {
    #[serde(rename = "catID")]
    cat_id: String,
    subcategory: String,
    groups: Vec<GroupRow>,
}

#[derive(Serialize)]
struct Shown {
    shown: i64,
    name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PlacedItem {
    #[serde(rename = "sound_id")]
    sound_id: i64,
    placed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    track: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    track_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    start: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    end: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    new_track: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    problem: Option<String>,
}

#[derive(Serialize)]
struct Placed {
    preview: bool,
    project: String,
    timeline: String,
    items: Vec<PlacedItem>,
}

#[derive(Serialize)]
struct SavedItem {
    sound_id: i64,
    track: i64,
    start: String,
    end: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SavedTimeline {
    path: String,
    frame_rate: String,
    items: Vec<SavedItem>,
    how_to_import: String,
}

/// What's read once and kept.
#[derive(Default)]
struct State {
    db: Option<LibraryDatabase>,
    catalog: Option<Arc<SoundCatalog>>,
    read_at: Option<Instant>,
    stamp: Vec<Option<SystemTime>>,
    similarity: Option<Arc<SimilarityIndex>>,
    similarity_for: usize,
}

pub struct EarmarkTools {
    /// Earmark's database file, opened read-only. None: `state.db` is given (tests).
    path: Option<PathBuf>,
    outside: Outside,
    state: Mutex<State>,
}

impl EarmarkTools {
    /// `path`: Earmark's database, opened read-only.
    pub fn new(path: PathBuf, outside: Outside) -> EarmarkTools {
        EarmarkTools {
            path: Some(path),
            outside,
            state: Mutex::new(State::default()),
        }
    }

    /// An open database (tests).
    pub fn with_database(db: LibraryDatabase, outside: Outside) -> EarmarkTools {
        EarmarkTools {
            path: None,
            outside,
            state: Mutex::new(State {
                db: Some(db),
                ..State::default()
            }),
        }
    }

    /// The catalog, read again when Earmark has saved something since (at most every 10 s, as
    /// analysis saves often).
    fn current(&self) -> Result<Arc<SoundCatalog>, ToolError> {
        let mut state = self.state.lock().map_err(|_| ToolError("Busy.".into()))?;
        let stamp: Vec<Option<SystemTime>> = self.path.as_ref().map_or(Vec::new(), |p| {
            let mut wal = p.clone().into_os_string();
            wal.push("-wal");
            [p.as_path(), Path::new(&wal)]
                .iter()
                .map(|f| std::fs::metadata(f).and_then(|m| m.modified()).ok())
                .collect()
        });
        if let (Some(catalog), Some(read_at)) = (&state.catalog, state.read_at)
            && (stamp == state.stamp || read_at.elapsed() < Duration::from_secs(10))
        {
            return Ok(catalog.clone());
        }
        if state.db.is_none() {
            let path = self
                .path
                .as_deref()
                .ok_or(ToolError("No database.".into()))?;
            state.db = Some(LibraryDatabase::open(Some(path), true)?);
        }
        let fresh = Arc::new(SoundCatalog::new(state.db.as_ref().expect("opened"))?);
        state.catalog = Some(fresh.clone());
        state.read_at = Some(Instant::now());
        state.stamp = stamp;
        Ok(fresh)
    }

    fn similarity_index(&self, c: &SoundCatalog) -> Result<Arc<SimilarityIndex>, ToolError> {
        let mut state = self.state.lock().map_err(|_| ToolError("Busy.".into()))?;
        if let Some(index) = &state.similarity
            && state.similarity_for == c.analysed.len()
        {
            return Ok(index.clone());
        }
        let db = state.db.as_ref().ok_or(ToolError("No database.".into()))?;
        let index = Arc::new(SimilarityIndex::new(&db.vectors("clap-general")?));
        state.similarity = Some(index.clone());
        state.similarity_for = c.analysed.len();
        Ok(index)
    }

    /// Runs a tool. Problems come back as an error result for the agent to read, not a failure.
    pub fn call(&self, name: &str, arguments: &Map<String, Value>) -> Answer {
        let a = Arguments(arguments);
        let answer = match name {
            "library_overview" => self.overview().and_then(|v| encoded(&v)),
            "search_sounds" => self.search(&a).and_then(|v| encoded(&v)),
            "get_sound" => self.details(&a).and_then(|v| encoded(&v)),
            "find_similar" => self.similar(&a).and_then(|v| encoded(&v)),
            "list_groups" => self.groups(&a).and_then(|v| encoded(&v)),
            "show_in_earmark" => self.show(&a).and_then(|v| encoded(&v)),
            "resolve_status" => (self.outside.resolve_status)()
                .map_err(ToolError::from)
                .and_then(|v| encoded(&v)),
            "add_to_resolve" => self.add(&a).and_then(|v| encoded(&v)),
            "save_timeline_file" => self.save_timeline_file(&a).and_then(|v| encoded(&v)),
            _ => problem(format!("There's no tool “{name}”.")),
        };
        answer.unwrap_or_else(|e| Answer {
            text: e.0,
            structured: None,
            is_error: true,
        })
    }

    fn overview(&self) -> Result<Overview, ToolError> {
        let c = self.current()?;
        let shown: Vec<&SoundRecord> = c.sounds.iter().filter(|s| c.is_shown(s)).collect();
        // Most sounds first, then by CatID where Swift's order depends on its dictionary.
        let mut by_sub: BTreeMap<&str, (&str, &str, usize)> = BTreeMap::new();
        for s in &shown {
            let (Some(cat_id), Some(category)) = (s.cat_id.as_deref(), s.category.as_deref())
            else {
                continue;
            };
            by_sub
                .entry(cat_id)
                .or_insert((category, s.subcategory.as_deref().unwrap_or(cat_id), 0))
                .2 += 1;
        }
        let mut by_category: BTreeMap<&str, Vec<Sub>> = BTreeMap::new();
        for (cat_id, (category, name, count)) in by_sub {
            by_category.entry(category).or_default().push(Sub {
                cat_id: cat_id.to_string(),
                name: capitalized(name),
                sounds: count,
                groups: c.groups.groups.get(cat_id).map_or(0, Vec::len),
            });
        }
        let categories = by_category
            .into_iter()
            .map(|(category, mut subs)| {
                subs.sort_by_key(|s| std::cmp::Reverse(s.sounds));
                Category {
                    category: capitalized(category),
                    sounds: subs.iter().map(|s| s.sounds).sum(),
                    subcategories: subs,
                }
            })
            .collect();
        let libraries = c
            .libraries
            .iter()
            .filter(|l| l.kind == "sounds")
            .map(|l| LibraryInfo {
                id: l.id,
                name: l.name(),
                path: l.path.clone(),
                online: l.is_online(),
                sounds: shown.iter().filter(|s| s.library_id == l.id).count(),
            })
            .collect();
        Ok(Overview {
            libraries,
            sounds: shown.len(),
            analysed: shown
                .iter()
                .filter(|s| s.id.is_some_and(|id| c.analysed.contains(&id)))
                .count(),
            songs: c.song_count,
            duplicates: c.duplicates.set_of.len(),
            categories,
            uncategorised: shown.iter().filter(|s| s.cat_id.is_none()).count(),
        })
    }

    fn search(&self, a: &Arguments) -> Result<Found, ToolError> {
        let c = self.current()?;
        let all = c.search(&Filter {
            query: a.string("query"),
            category: a.string("category"),
            group_id: a.int("group_id"),
            library_id: a.int("library_id"),
            min_length: a.double("min_length"),
            max_length: a.double("max_length"),
            source: a.string("source"),
        });
        let offset = a.int("offset").unwrap_or(0).max(0) as usize;
        let limit = a.int("limit").unwrap_or(25).clamp(1, 200) as usize;
        Ok(Found {
            total: all.len(),
            offset,
            sounds: all
                .iter()
                .skip(offset)
                .take(limit)
                .map(|s| row(s, &c, None))
                .collect(),
        })
    }

    fn sound<'a>(&self, a: &Arguments, c: &'a SoundCatalog) -> Result<&'a SoundRecord, ToolError> {
        let Some(id) = a.int("sound_id") else {
            return problem("Give “sound_id”, a sound's id from search_sounds.");
        };
        match c.sound(id) {
            Some(s) => Ok(s),
            None => problem(format!("There's no sound {id}.")),
        }
    }

    fn details(&self, a: &Arguments) -> Result<Details, ToolError> {
        let c = self.current()?;
        let s = self.sound(a, &c)?;
        let id = s.id.unwrap_or(-1);
        let others = c.duplicates.others.get(&id).map_or(&[][..], Vec::as_slice);
        let other = |wanted: bool, similarity: bool| -> Vec<Other> {
            others
                .iter()
                .filter(|o| o.1 == wanted)
                .filter_map(|&(oid, _, score)| {
                    c.sound(oid).map(|x| Other {
                        id: oid,
                        path: x.path.clone(),
                        similarity: similarity.then_some(f64::from(score)),
                    })
                })
                .collect()
        };
        Ok(Details {
            sound: row(s, &c, None),
            description: s.details.clone(),
            keywords: s.keywords.clone(),
            vendor_library: s.vendor_library.clone(),
            manufacturer: s.manufacturer.clone(),
            designer: s.designer.clone(),
            category_source: SoundCatalog::source_text(s),
            group_info: c.group_of(s).map(|g| GroupInfo {
                id: g.id,
                name: g.title().to_string(),
                keywords: keyword_list(&g.keywords),
            }),
            peak: current_facts(s, &c).and_then(|f| f.peak),
            sample_rate: s.sample_rate,
            channels: s.channels,
            bits_per_sample: s.bits_per_sample,
            analysed: c.analysed.contains(&id),
            online: c.library(s.library_id).is_some_and(|l| l.is_online()),
            other_formats: c.twins.alternates.get(&id).map_or(Vec::new(), |list| {
                list.iter()
                    .filter_map(|&o| c.sound(o).map(|x| x.path.clone()))
                    .collect()
            }),
            copies: other(true, false),
            same_recording: other(false, true),
        })
    }

    fn similar(&self, a: &Arguments) -> Result<Similar, ToolError> {
        let c = self.current()?;
        let s = self.sound(a, &c)?;
        let index = self.similarity_index(&c)?;
        let id = s.id.unwrap_or(-1);
        if !index.contains(id) {
            return problem(format!("Sound {id} hasn't been analysed yet."));
        }
        // As the app's Find Similar Sounds: hidden format twins and byte-identical copies left out.
        let mut skip: HashSet<i64> = c.twins.hidden.iter().copied().collect();
        if s.fingerprint.is_some() {
            skip.extend(
                c.sounds
                    .iter()
                    .filter(|o| o.fingerprint == s.fingerprint && o.id != s.id)
                    .filter_map(|o| o.id),
            );
        }
        let limit = a.int("limit").unwrap_or(20).clamp(1, 100) as usize;
        let found = index.nearest(id, limit, &skip);
        Ok(Similar {
            sound: row(s, &c, None),
            similar: found
                .into_iter()
                .filter_map(|(m, score)| c.sound(m).map(|x| row(x, &c, Some(score))))
                .collect(),
        })
    }

    fn groups(&self, a: &Arguments) -> Result<Groups, ToolError> {
        let c = self.current()?;
        let ucs = UcsCatalog::shared();
        let found = a.string("subcategory").and_then(|key| {
            ucs.entry_by_cat_id(Some(&key)).or_else(|| {
                let lower = key.to_lowercase();
                ucs.entries
                    .iter()
                    .find(|e| e.label().to_lowercase() == lower)
            })
        });
        let Some(e) = found else {
            return problem(
                "Give “subcategory”: a CatID (“FEETHmn”) or “Category / Subcategory”, as library_overview lists them.",
            );
        };
        let mut counts: HashMap<i64, usize> = HashMap::new();
        for s in c.sounds.iter().filter(|s| c.is_shown(s)) {
            if let Some(g) = c.group_of(s) {
                *counts.entry(g.id).or_default() += 1;
            }
        }
        let groups = c.groups.groups.get(&e.cat_id).map_or(Vec::new(), |list| {
            list.iter()
                .map(|g| GroupRow {
                    id: g.id,
                    name: g.title().to_string(),
                    keywords: keyword_list(&g.keywords),
                    sounds: counts.get(&g.id).copied().unwrap_or(0),
                    renamed_by_owner: g.user_name.is_some(),
                })
                .collect()
        });
        Ok(Groups {
            cat_id: e.cat_id.clone(),
            subcategory: capitalized(&e.label()),
            groups,
        })
    }

    fn show(&self, a: &Arguments) -> Result<Shown, ToolError> {
        let c = self.current()?;
        let s = self.sound(a, &c)?;
        let id = s.id.unwrap_or(-1);
        (self.outside.open)(&format!("earmark://sound/{id}"));
        Ok(Shown {
            shown: id,
            name: s.display_name(),
        })
    }

    /// The item's sound, on a connected drive.
    fn item_sound<'a>(
        n: usize,
        e: &Arguments,
        c: &'a SoundCatalog,
    ) -> Result<(i64, &'a SoundRecord), ToolError> {
        let Some((id, s)) = e.int("sound_id").and_then(|id| Some((id, c.sound(id)?))) else {
            return problem(format!("Item {}: no such sound_id.", n + 1));
        };
        if !Path::new(&s.path).exists() {
            return problem(format!(
                "Item {}: “{}” is offline (its drive isn't connected).",
                n + 1,
                s.display_name()
            ));
        }
        Ok((id, s))
    }

    fn add(&self, a: &Arguments) -> Result<Placed, ToolError> {
        let c = self.current()?;
        let Some(list) = a.list("items").filter(|l| !l.is_empty()) else {
            return problem("Give “items”: a list of { sound_id, start, end, at, track }.");
        };
        let preview = a.bool("preview").unwrap_or(false);
        let mut items = Vec::new();
        let mut ids = Vec::new();
        for (n, value) in list.iter().enumerate() {
            let e = entry(value);
            let (id, s) = Self::item_sound(n, &e, &c)?;
            let at = e
                .double("at")
                .map(At::Seconds)
                .or_else(|| e.string("at").map(At::Timecode));
            let track = match e.int("track") {
                Some(i) => Track::Index(i),
                None if e.string("track").as_deref() == Some("free") => Track::Free,
                None => Track::Earmark,
            };
            items.push(Item {
                path: s.path.clone(),
                start: e.double("start"),
                end: e.double("end"),
                at,
                track,
                length: s.duration,
                channels: s.channels,
            });
            ids.push(id);
        }
        let added = (self.outside.resolve_add)(&items, preview)?;
        Ok(Placed {
            preview,
            project: added.project,
            timeline: added.timeline,
            items: ids
                .into_iter()
                .zip(added.items)
                .map(|(sound_id, p)| PlacedItem {
                    sound_id,
                    placed: p.ok == Some(true),
                    problem: p.problem(),
                    track: p.track,
                    track_name: p.track_name,
                    start: p.start,
                    end: p.end,
                    new_track: p.new_track,
                })
                .collect(),
        })
    }

    /// The items as an FCPXML timeline file (docs/timeline-file-plan.md), for the free DaVinci
    /// Resolve or Final Cut Pro. Writes only into `outside.timeline_folder`.
    fn save_timeline_file(&self, a: &Arguments) -> Result<SavedTimeline, ToolError> {
        let c = self.current()?;
        let Some(list) = a.list("items").filter(|l| !l.is_empty()) else {
            return problem("Give “items”: a list of { sound_id, start, end, at }.");
        };
        let rate_name = a.string("frame_rate").unwrap_or_else(|| "25".into());
        let Some(rate) = Rate::named(&rate_name) else {
            let names: Vec<&str> = RATES.iter().map(|r| r.name).collect();
            return problem(format!(
                "“frame_rate” must be one of: {}.",
                names.join(", ")
            ));
        };
        let mut clips = Vec::new();
        let mut ids = Vec::new();
        for (n, value) in list.iter().enumerate() {
            let e = entry(value);
            let (id, s) = Self::item_sound(n, &e, &c)?;
            let Some(length) = s.duration.filter(|&l| l > 0.0) else {
                return problem(format!("Item {}: Earmark doesn't know its length.", n + 1));
            };
            clips.push(Clip {
                path: s.path.clone(),
                name: s.display_name(),
                length,
                sample_rate: s.sample_rate.unwrap_or(48000.0) as i64,
                channels: s.channels.unwrap_or(2),
                time_reference: metadata::time_reference(Path::new(&s.path)),
                start: e.double("start"),
                end: e.double("end"),
                at: e.double("at"),
            });
            ids.push(id);
        }
        let raw_name = a.string("name").unwrap_or_else(|| "Earmark sounds".into());
        let unsafe_in_names: &[char] = if cfg!(windows) {
            &['/', ':', '\\', '*', '?', '"', '<', '>', '|']
        } else {
            &['/', ':']
        };
        let cleaned = raw_name.replace(unsafe_in_names, "-");
        let name = match trim(&cleaned) {
            "" => "Earmark sounds",
            name => name,
        };
        let start_timecode = a.string("start_timecode");
        let (xml, placements) = timeline_file::fcpxml(
            &clips,
            &rate,
            start_timecode.as_deref().unwrap_or("01:00:00:00"),
            name,
        )?;
        let folder = &self.outside.timeline_folder;
        std::fs::create_dir_all(folder)?;
        let mut path = folder.join(format!("{name}.fcpxml"));
        let mut n = 2;
        while path.exists() {
            path = folder.join(format!("{name} {n}.fcpxml"));
            n += 1;
        }
        // Never over a file that appeared meanwhile.
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        file.write_all(xml.as_bytes())?;
        Ok(SavedTimeline {
            path: path.to_string_lossy().into_owned(),
            frame_rate: rate.name.to_string(),
            items: ids
                .into_iter()
                .zip(placements)
                .map(|(sound_id, p)| SavedItem {
                    sound_id,
                    track: p.lane,
                    start: p.start,
                    end: p.end,
                })
                .collect(),
            how_to_import: "DaVinci Resolve: File ▸ Import ▸ Timeline… (a new timeline; copy its clips into yours). \
                 Final Cut Pro: File ▸ Import ▸ XML…"
                .to_string(),
        })
    }
}

fn keyword_list(keywords: &str) -> Vec<String> {
    keywords
        .split('|')
        .filter(|k| !k.is_empty())
        .map(str::to_string)
        .collect()
}
