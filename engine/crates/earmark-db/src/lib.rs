//! Earmark's own database (docs/rust-engine-plan.md, step 3): the same file, schema and rules as
//! the Swift app's `LibraryDatabase`, so the Mac app keeps its library and analysis when it
//! switches to the engine. The only place Earmark writes.

pub mod analysis_files;
pub mod categories;
pub mod groups;
pub mod schema;

pub use earmark_core::dates;
use earmark_core::paths::{self, canonical};
use earmark_core::phase0::{Entry, SongAnalysis};
pub use earmark_core::records::*;
use earmark_core::scan::ScannedSound;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Row, params};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

#[derive(Debug)]
pub enum DbError {
    Sqlite(rusqlite::Error),
    /// No database at that path (opening read-only).
    Missing(String),
    /// Made by a newer Earmark: these migrations aren't known here.
    Newer(Vec<String>),
    /// Writing a file, such as an analysis file.
    File(String),
}

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DbError::Sqlite(e) => write!(f, "{e}"),
            DbError::Missing(p) => {
                write!(
                    f,
                    "There's no Earmark database at {p}. Open Earmark once and add a library."
                )
            }
            DbError::Newer(m) => write!(
                f,
                "This database was made by a newer Earmark ({}).",
                m.join(", ")
            ),
            DbError::File(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for DbError {}

impl From<rusqlite::Error> for DbError {
    fn from(e: rusqlite::Error) -> Self {
        DbError::Sqlite(e)
    }
}

impl From<schema::MigrationError> for DbError {
    fn from(e: schema::MigrationError) -> Self {
        match e {
            schema::MigrationError::Sqlite(e) => DbError::Sqlite(e),
            schema::MigrationError::Newer(m) => DbError::Newer(m),
        }
    }
}

pub type Result<T> = std::result::Result<T, DbError>;

pub struct LibraryDatabase {
    conn: Mutex<Connection>,
}

const SOUND_COLUMNS: &str = "id, libraryId, path, fileName, folder, fileSize, modifiedAt, fingerprint, duration, \
    sampleRate, channels, bitsPerSample, fxName, details, keywords, vendorLibrary, manufacturer, designer, catID, \
    category, subcategory, categorySource";
const SONG_COLUMNS: &str = "id, libraryId, path, fileName, folder, fileSize, modifiedAt, title, artist, album, \
    duration, bpm, bpmLow, bpmHigh, tempoStability, beatsPerBar, keyPitchClass, keyMinor, keyConfidence, analysisSource";

fn sound_row(r: &Row) -> rusqlite::Result<SoundRecord> {
    Ok(SoundRecord {
        id: r.get(0)?,
        library_id: r.get(1)?,
        path: r.get(2)?,
        file_name: r.get(3)?,
        folder: r.get(4)?,
        file_size: r.get(5)?,
        modified_at: r.get(6)?,
        fingerprint: r.get(7)?,
        duration: r.get(8)?,
        sample_rate: r.get(9)?,
        channels: r.get(10)?,
        bits_per_sample: r.get(11)?,
        fx_name: r.get(12)?,
        details: r.get(13)?,
        keywords: r.get(14)?,
        vendor_library: r.get(15)?,
        manufacturer: r.get(16)?,
        designer: r.get(17)?,
        cat_id: r.get(18)?,
        category: r.get(19)?,
        subcategory: r.get(20)?,
        category_source: r.get(21)?,
    })
}

fn song_row(r: &Row) -> rusqlite::Result<SongRecord> {
    Ok(SongRecord {
        id: r.get(0)?,
        library_id: r.get(1)?,
        path: r.get(2)?,
        file_name: r.get(3)?,
        folder: r.get(4)?,
        file_size: r.get(5)?,
        modified_at: r.get(6)?,
        title: r.get(7)?,
        artist: r.get(8)?,
        album: r.get(9)?,
        duration: r.get(10)?,
        bpm: r.get(11)?,
        bpm_low: r.get(12)?,
        bpm_high: r.get(13)?,
        tempo_stability: r.get(14)?,
        beats_per_bar: r.get(15)?,
        key_pitch_class: r.get(16)?,
        key_minor: r.get(17)?,
        key_confidence: r.get(18)?,
        analysis_source: r.get(19)?,
        analysed: None,
        correction: None,
    })
}

/// Inserts a sound (with its id if it has one) or, with `update`, rewrites every column of the
/// row with its id, as GRDB's `insert` and `update` do.
fn write_sound(conn: &Connection, s: &SoundRecord, update: bool) -> rusqlite::Result<i64> {
    let values = params![
        s.library_id,
        s.path,
        s.file_name,
        s.folder,
        s.file_size,
        s.modified_at,
        s.fingerprint,
        s.duration,
        s.sample_rate,
        s.channels,
        s.bits_per_sample,
        s.fx_name,
        s.details,
        s.keywords,
        s.vendor_library,
        s.manufacturer,
        s.designer,
        s.cat_id,
        s.category,
        s.subcategory,
        s.category_source,
        s.id
    ];
    if update {
        conn.execute(
            "UPDATE sound SET libraryId = ?1, path = ?2, fileName = ?3, folder = ?4, fileSize = ?5, modifiedAt = ?6, \
             fingerprint = ?7, duration = ?8, sampleRate = ?9, channels = ?10, bitsPerSample = ?11, fxName = ?12, \
             details = ?13, keywords = ?14, vendorLibrary = ?15, manufacturer = ?16, designer = ?17, catID = ?18, \
             category = ?19, subcategory = ?20, categorySource = ?21 WHERE id = ?22",
            values,
        )?;
        Ok(s.id.unwrap_or_default())
    } else {
        conn.execute(
            &format!(
                "INSERT INTO sound (libraryId, path, fileName, folder, fileSize, modifiedAt, fingerprint, duration, \
                 sampleRate, channels, bitsPerSample, fxName, details, keywords, vendorLibrary, manufacturer, designer, \
                 catID, category, subcategory, categorySource, id) VALUES ({})",
                (1..=22).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
            ),
            values,
        )?;
        Ok(conn.last_insert_rowid())
    }
}

fn write_song(conn: &Connection, s: &SongRecord, update: bool) -> rusqlite::Result<i64> {
    let values = params![
        s.library_id,
        s.path,
        s.file_name,
        s.folder,
        s.file_size,
        s.modified_at,
        s.title,
        s.artist,
        s.album,
        s.duration,
        s.bpm,
        s.bpm_low,
        s.bpm_high,
        s.tempo_stability,
        s.beats_per_bar,
        s.key_pitch_class,
        s.key_minor,
        s.key_confidence,
        s.analysis_source,
        s.id
    ];
    if update {
        conn.execute(
            "UPDATE song SET libraryId = ?1, path = ?2, fileName = ?3, folder = ?4, fileSize = ?5, modifiedAt = ?6, \
             title = ?7, artist = ?8, album = ?9, duration = ?10, bpm = ?11, bpmLow = ?12, bpmHigh = ?13, \
             tempoStability = ?14, beatsPerBar = ?15, keyPitchClass = ?16, keyMinor = ?17, keyConfidence = ?18, \
             analysisSource = ?19 WHERE id = ?20",
            values,
        )?;
        Ok(s.id.unwrap_or_default())
    } else {
        conn.execute(
            &format!(
                "INSERT INTO song (libraryId, path, fileName, folder, fileSize, modifiedAt, title, artist, album, \
                 duration, bpm, bpmLow, bpmHigh, tempoStability, beatsPerBar, keyPitchClass, keyMinor, keyConfidence, \
                 analysisSource, id) VALUES ({})",
                (1..=20).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
            ),
            values,
        )?;
        Ok(conn.last_insert_rowid())
    }
}

pub(crate) fn save_fact(c: &Connection, f: &SoundFacts) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO soundFacts (soundId, fingerprint, version, loudness, peak, error, analyzedAt) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(soundId) DO UPDATE SET fingerprint = ?2, \
         version = ?3, loudness = ?4, peak = ?5, error = ?6, analyzedAt = ?7",
        params![
            f.sound_id,
            f.fingerprint,
            f.version,
            f.loudness,
            f.peak,
            f.error,
            f.analyzed_at
        ],
    )?;
    Ok(())
}

pub(crate) fn save_embedding(c: &Connection, e: &SoundEmbedding) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO soundEmbedding (soundId, model, fingerprint, version, vector, error, analyzedAt) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(soundId, model) DO UPDATE SET fingerprint = ?3, \
         version = ?4, vector = ?5, error = ?6, analyzedAt = ?7",
        params![e.sound_id, e.model, e.fingerprint, e.version, e.vector, e.error, e.analyzed_at],
    )?;
    Ok(())
}

impl LibraryDatabase {
    /// `None` opens a database in memory (tests). `read_only`: for another process reading what
    /// the app saved (the MCP server); it never migrates or writes.
    pub fn open(path: Option<&Path>, read_only: bool) -> Result<LibraryDatabase> {
        let mut conn = match path {
            Some(p) if read_only => {
                if !p.exists() {
                    return Err(DbError::Missing(p.display().to_string()));
                }
                Connection::open_with_flags(
                    p,
                    OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
                )?
            }
            Some(p) => {
                if let Some(dir) = p.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                let c = Connection::open(p)?;
                // As GRDB's DatabasePool: other processes can read while this one writes.
                c.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
                c
            }
            None => Connection::open_in_memory()?,
        };
        // Wait a moment rather than fail while another process holds a lock.
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch("PRAGMA foreign_keys = ON")?;
        if !read_only {
            schema::migrate(&mut conn)?;
        }
        Ok(LibraryDatabase {
            conn: Mutex::new(conn),
        })
    }

    pub(crate) fn with<T>(
        &self,
        f: impl FnOnce(&mut Connection) -> rusqlite::Result<T>,
    ) -> Result<T> {
        let mut c = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        Ok(f(&mut c)?)
    }

    // MARK: libraries

    /// Adds a library, or updates the bookmark of the one at that path.
    pub fn add_library(&self, kind: &str, path: &str, bookmark: Option<&[u8]>) -> Result<Library> {
        self.with(|c| {
            let tx = c.transaction()?;
            let existing = tx
                .query_row("SELECT id, kind, path, bookmark, addedAt FROM library WHERE path = ?1", [path], library_row)
                .optional()?;
            let lib = match existing {
                Some(mut lib) => {
                    if let Some(b) = bookmark {
                        lib.bookmark = Some(b.to_vec());
                    }
                    tx.execute(
                        "UPDATE library SET kind = ?1, path = ?2, bookmark = ?3, addedAt = ?4 WHERE id = ?5",
                        params![lib.kind, lib.path, lib.bookmark, lib.added_at, lib.id],
                    )?;
                    lib
                }
                None => {
                    let added_at = dates::now();
                    tx.execute(
                        "INSERT INTO library (kind, path, bookmark, addedAt) VALUES (?1, ?2, ?3, ?4)",
                        params![kind, path, bookmark, added_at],
                    )?;
                    Library {
                        id: tx.last_insert_rowid(),
                        kind: kind.into(),
                        path: path.into(),
                        bookmark: bookmark.map(<[u8]>::to_vec),
                        added_at,
                    }
                }
            };
            tx.commit()?;
            Ok(lib)
        })
    }

    pub fn libraries(&self, kind: Option<&str>) -> Result<Vec<Library>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT id, kind, path, bookmark, addedAt FROM library WHERE ?1 IS NULL OR kind = ?1 ORDER BY path",
            )?;
            st.query_map([kind], library_row)?.collect()
        })
    }

    /// Forgets a library. Its sounds' ids are kept by fingerprint, so adding the folder again
    /// (or the same files elsewhere) restores them.
    pub fn remove_library(&self, id: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "INSERT OR REPLACE INTO retiredSound (fingerprint, soundId) \
                 SELECT fingerprint, id FROM sound WHERE libraryId = ?1 AND fingerprint IS NOT NULL",
                [id],
            )?;
            // Earmark's guesses are remade if the folder comes back; the user's rules stay.
            tx.execute("DELETE FROM folderGuess WHERE libraryId = ?1", [id])?;
            tx.execute("DELETE FROM library WHERE id = ?1", [id])?;
            tx.commit()
        })
    }

    // MARK: sounds

    /// Replaces a library's sounds with a fresh scan. A file keeps its id when its path is
    /// unchanged; a renamed or moved file keeps it through its fingerprint, as does a file
    /// returning after it was removed. Files no longer there are removed (their ids retired by
    /// fingerprint). Only call this when the library folder is online.
    ///
    /// Paths compare as Swift's dictionaries compare them, by canonical equivalence. Where Swift's
    /// choice depends on its dictionaries' order (several moved files with the same
    /// fingerprint), this goes by path, so it's the same every time.
    pub fn replace_sounds(
        &self,
        library_id: i64,
        root: &str,
        scanned: &[ScannedSound],
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            let mut existing: Vec<(i64, String, Option<String>)> = {
                let mut st = tx.prepare("SELECT id, path, fingerprint FROM sound WHERE libraryId = ?1")?;
                st.query_map([library_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<rusqlite::Result<_>>()?
            };
            existing.sort_by(|a, b| a.1.cmp(&b.1));
            let mut id_by_path: HashMap<String, i64> = HashMap::new();
            let mut fingerprint_by_id: HashMap<i64, String> = HashMap::new();
            for (id, path, f) in &existing {
                id_by_path.insert(canonical(path), *id);
                if let Some(f) = f {
                    fingerprint_by_id.insert(*id, f.clone());
                }
            }
            let records: Vec<SoundRecord> = scanned.iter().map(|s| SoundRecord::from_scan(library_id, root, s)).collect();
            let scanned_paths: HashSet<String> = records.iter().map(|r| canonical(&r.path)).collect();

            // Rows whose file is no longer at their path may have moved: index them by fingerprint.
            let mut movable: HashMap<String, Vec<i64>> = HashMap::new();
            for (_, path, _) in &existing {
                let key = canonical(path);
                let Some(&id) = id_by_path.get(&key) else { continue };
                if scanned_paths.contains(&key) {
                    continue;
                }
                if let Some(f) = fingerprint_by_id.get(&id) {
                    let ids = movable.entry(f.clone()).or_default();
                    if !ids.contains(&id) {
                        ids.push(id);
                    }
                }
            }
            let mut kept: HashSet<i64> = HashSet::new();
            let mut fresh: Vec<SoundRecord> = Vec::new();
            for mut rec in records {
                if let Some(&id) = id_by_path.get(&canonical(&rec.path)) {
                    rec.id = Some(id);
                } else if let Some(id) = rec.fingerprint.as_ref().and_then(|f| movable.get_mut(f)).and_then(Vec::pop) {
                    rec.id = Some(id);
                } else {
                    fresh.push(rec);
                    continue;
                }
                kept.insert(rec.id.unwrap());
                write_sound(&tx, &rec, true)?;
            }
            let mut gone: Vec<i64> = id_by_path.values().copied().filter(|id| !kept.contains(id)).collect();
            gone.sort_unstable();
            for id in gone {
                if let Some(f) = fingerprint_by_id.get(&id) {
                    tx.execute("INSERT OR REPLACE INTO retiredSound (fingerprint, soundId) VALUES (?1, ?2)", params![f, id])?;
                }
                tx.execute("DELETE FROM sound WHERE id = ?1", [id])?;
            }
            for mut rec in fresh {
                if let Some(f) = &rec.fingerprint {
                    let retired: Option<i64> = tx
                        .query_row("SELECT soundId FROM retiredSound WHERE fingerprint = ?1", [f], |r| r.get(0))
                        .optional()?;
                    if let Some(id) = retired {
                        let taken: bool =
                            tx.query_row("SELECT EXISTS(SELECT 1 FROM sound WHERE id = ?1)", [id], |r| r.get(0))?;
                        if !taken {
                            rec.id = Some(id);
                        }
                    }
                }
                write_sound(&tx, &rec, false)?;
                if let Some(f) = &rec.fingerprint {
                    tx.execute("DELETE FROM retiredSound WHERE fingerprint = ?1", [f])?;
                }
            }
            tx.commit()
        })
    }

    pub fn sounds(&self, library_id: Option<i64>) -> Result<Vec<SoundRecord>> {
        self.with(|c| {
            let mut st = c.prepare(&format!(
                "SELECT {SOUND_COLUMNS} FROM sound WHERE ?1 IS NULL OR libraryId = ?1 ORDER BY path"
            ))?;
            st.query_map([library_id], sound_row)?.collect()
        })
    }

    // MARK: analysis facts

    pub fn sound_facts(&self) -> Result<HashMap<i64, SoundFacts>> {
        self.with(|c| {
            let mut st =
                c.prepare("SELECT soundId, fingerprint, version, loudness, peak, error, analyzedAt FROM soundFacts")?;
            let rows = st.query_map([], |r| {
                Ok(SoundFacts {
                    sound_id: r.get(0)?,
                    fingerprint: r.get(1)?,
                    version: r.get(2)?,
                    loudness: r.get(3)?,
                    peak: r.get(4)?,
                    error: r.get(5)?,
                    analyzed_at: r.get(6)?,
                })
            })?;
            let mut out = HashMap::new();
            for f in rows {
                let f = f?;
                out.entry(f.sound_id).or_insert(f);
            }
            Ok(out)
        })
    }

    pub fn save_facts(&self, facts: &[SoundFacts]) -> Result<()> {
        if facts.is_empty() {
            return Ok(());
        }
        self.with(|c| {
            let tx = c.transaction()?;
            for f in facts {
                save_fact(&tx, f)?;
            }
            tx.commit()
        })
    }

    // MARK: analysis embeddings

    /// What's stored for `model`, without the vectors (enough to know what's left to do).
    pub fn embedding_status(&self, model: &str) -> Result<HashMap<i64, EmbeddingStatus>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT soundId, fingerprint, version FROM soundEmbedding WHERE model = ?1",
            )?;
            let rows = st.query_map([model], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    EmbeddingStatus {
                        fingerprint: r.get(1)?,
                        version: r.get(2)?,
                    },
                ))
            })?;
            let mut out = HashMap::new();
            for row in rows {
                let (id, s) = row?;
                out.entry(id).or_insert(s);
            }
            Ok(out)
        })
    }

    /// Every stored vector for `model` that still describes its sound (the same fingerprint,
    /// the current version), in the database's order.
    pub fn vectors(&self, model: &str) -> Result<Vec<(i64, Vec<f32>)>> {
        let version = SoundEmbedding::version_of(model);
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT e.soundId, e.vector FROM soundEmbedding e JOIN sound s ON s.id = e.soundId \
                 WHERE e.model = ?1 AND e.vector IS NOT NULL AND e.version >= ?2 AND e.fingerprint IS s.fingerprint",
            )?;
            st.query_map(params![model, version], |r| {
                Ok((r.get(0)?, SoundEmbedding::floats(&r.get::<_, Vec<u8>>(1)?)))
            })?
            .collect()
        })
    }

    /// The same for sounds that have a current vector from every one of `models`, in sound id
    /// order, one sound at a time (`body` gets them in `models`' order). `count` first gets how
    /// many there will be. `ids`: only these sounds.
    pub fn for_each_vectors(
        &self,
        models: &[&str],
        ids: Option<&[i64]>,
        count: &mut dyn FnMut(usize),
        body: &mut dyn FnMut(i64, Vec<Vec<f32>>),
    ) -> Result<()> {
        let mut joins: Vec<String> = (0..models.len())
            .map(|i| {
                format!(
                    "JOIN soundEmbedding e{i} ON e{i}.soundId = s.id AND e{i}.model = ? AND e{i}.vector IS NOT NULL \
                     AND e{i}.version >= ? AND e{i}.fingerprint IS s.fingerprint"
                )
            })
            .collect();
        // Only these sounds (ids are integers, so written in).
        if let Some(ids) = ids {
            joins.push(format!(
                "AND s.id IN ({})",
                ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",")
            ));
        }
        let joins = joins.join(" ");
        let columns: Vec<String> = (0..models.len()).map(|i| format!("e{i}.vector")).collect();
        let mut values: Vec<rusqlite::types::Value> = Vec::new();
        for m in models {
            values.push(m.to_string().into());
            values.push(SoundEmbedding::version_of(m).into());
        }
        self.with(|c| {
            let n: i64 = c.query_row(
                &format!("SELECT COUNT(*) FROM sound s {joins}"),
                rusqlite::params_from_iter(values.iter()),
                |r| r.get(0),
            )?;
            count(n as usize);
            let mut st = c.prepare(&format!(
                "SELECT s.id, {} FROM sound s {joins} ORDER BY s.id",
                columns.join(", ")
            ))?;
            let mut rows = st.query(rusqlite::params_from_iter(values.iter()))?;
            while let Some(r) = rows.next()? {
                let mut vectors = Vec::with_capacity(models.len());
                for i in 0..models.len() {
                    vectors.push(SoundEmbedding::floats(&r.get::<_, Vec<u8>>(i + 1)?));
                }
                body(r.get(0)?, vectors);
            }
            Ok(())
        })
    }

    pub fn embedding(&self, sound_id: i64, model: &str) -> Result<Option<SoundEmbedding>> {
        self.with(|c| {
            c.query_row(
                "SELECT soundId, model, fingerprint, version, vector, error, analyzedAt FROM soundEmbedding \
                 WHERE soundId = ?1 AND model = ?2",
                params![sound_id, model],
                |r| {
                    Ok(SoundEmbedding {
                        sound_id: r.get(0)?,
                        model: r.get(1)?,
                        fingerprint: r.get(2)?,
                        version: r.get(3)?,
                        vector: r.get(4)?,
                        error: r.get(5)?,
                        analyzed_at: r.get(6)?,
                    })
                },
            )
            .optional()
        })
    }

    pub fn save_embeddings(&self, embeddings: &[SoundEmbedding]) -> Result<()> {
        if embeddings.is_empty() {
            return Ok(());
        }
        self.with(|c| {
            let tx = c.transaction()?;
            for e in embeddings {
                save_embedding(&tx, e)?;
            }
            tx.commit()
        })
    }

    // MARK: duplicates

    /// The same-recording pairs last found (byte-identical copies come from the fingerprints).
    pub fn near_duplicates(&self) -> Result<Vec<earmark_core::analysis::duplicates::Pair>> {
        use earmark_core::analysis::duplicates::Pair;
        self.with(|c| {
            // A database the app hasn't opened since this table came (read-only readers can't migrate).
            let exists: bool = c.query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'soundDuplicate')",
                [],
                |r| r.get(0),
            )?;
            if !exists {
                return Ok(Vec::new());
            }
            let mut st = c.prepare("SELECT soundA, soundB, similarity FROM soundDuplicate")?;
            st.query_map([], |r| Ok(Pair::new(r.get(0)?, r.get(1)?, false, r.get::<_, f64>(2)? as f32)))?.collect()
        })
    }

    pub fn save_near_duplicates(
        &self,
        pairs: &[earmark_core::analysis::duplicates::Pair],
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute("DELETE FROM soundDuplicate", [])?;
            for p in pairs.iter().filter(|p| !p.identical) {
                tx.execute(
                    "INSERT OR REPLACE INTO soundDuplicate (soundA, soundB, similarity) VALUES (?1, ?2, ?3)",
                    params![p.a, p.b, p.similarity as f64],
                )?;
            }
            tx.commit()
        })
    }

    // MARK: songs

    /// Replaces a music folder's songs with a fresh listing, keeping any analysis already
    /// stored for files that are still there.
    pub fn replace_songs(&self, library_id: i64, root: &str, files: &[SongFile]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            let existing: Vec<SongRecord> = {
                let mut st = tx.prepare(&format!(
                    "SELECT {SONG_COLUMNS} FROM song WHERE libraryId = ?1"
                ))?;
                st.query_map([library_id], song_row)?
                    .collect::<rusqlite::Result<_>>()?
            };
            let mut by_path: HashMap<String, SongRecord> = HashMap::new();
            for s in existing {
                by_path.entry(canonical(&s.path)).or_insert(s);
            }
            let mut seen: HashSet<String> = HashSet::new();
            for f in files {
                let key = canonical(&f.path);
                seen.insert(key.clone());
                if let Some(mut rec) = by_path.remove(&key) {
                    rec.file_size = f.file_size;
                    rec.modified_at = dates::format(f.modified);
                    rec.title = f.title.clone();
                    rec.artist = f.artist.clone();
                    rec.album = f.album.clone();
                    rec.duration = f.duration.or(rec.duration);
                    write_song(&tx, &rec, true)?;
                } else {
                    let rec = SongRecord {
                        id: None,
                        library_id,
                        path: f.path.clone(),
                        file_name: paths::file_name(&f.path),
                        folder: paths::relative_folder(&f.path, root),
                        file_size: f.file_size,
                        modified_at: dates::format(f.modified),
                        title: f.title.clone(),
                        artist: f.artist.clone(),
                        album: f.album.clone(),
                        duration: f.duration,
                        bpm: None,
                        bpm_low: None,
                        bpm_high: None,
                        tempo_stability: None,
                        beats_per_bar: None,
                        key_pitch_class: None,
                        key_minor: None,
                        key_confidence: None,
                        analysis_source: None,
                        analysed: None,
                        correction: None,
                    };
                    write_song(&tx, &rec, false)?;
                }
            }
            for (key, rec) in by_path {
                if !seen.contains(&key) {
                    tx.execute("DELETE FROM song WHERE id = ?1", [rec.id])?;
                }
            }
            tx.commit()
        })
    }

    pub fn songs(&self, library_id: Option<i64>) -> Result<Vec<SongRecord>> {
        self.with(|c| {
            let mut st = c.prepare(&format!(
                "SELECT {SONG_COLUMNS} FROM song WHERE ?1 IS NULL OR libraryId = ?1 ORDER BY path"
            ))?;
            st.query_map([library_id], song_row)?.collect()
        })
    }

    /// Stores Earmark's own analysis for songs that still have none (a Phase 0 import that came
    /// in meanwhile wins). Returns the updated songs.
    pub fn save_song_analysis(&self, results: &[(i64, SongAnalysis)]) -> Result<Vec<SongRecord>> {
        self.with(|c| {
            let tx = c.transaction()?;
            let mut updated = Vec::new();
            for (id, analysis) in results {
                let rec = tx
                    .query_row(
                        &format!("SELECT {SONG_COLUMNS} FROM song WHERE id = ?1"),
                        [id],
                        song_row,
                    )
                    .optional()?;
                let Some(mut rec) = rec.filter(|r| r.analysis_source.is_none()) else {
                    continue;
                };
                rec.apply(analysis);
                write_song(&tx, &rec, true)?;
                updated.push(rec);
            }
            tx.commit()?;
            Ok(updated)
        })
    }

    /// Attaches imported analysis to songs: by full path first, then by file name + size, then
    /// by a unique file name. Returns how many matched.
    pub fn apply_song_analysis(&self, entries: &[Entry]) -> Result<usize> {
        self.with(|c| {
            let tx = c.transaction()?;
            let songs: Vec<SongRecord> = {
                let mut st = tx.prepare(&format!("SELECT {SONG_COLUMNS} FROM song"))?;
                st.query_map([], song_row)?
                    .collect::<rusqlite::Result<_>>()?
            };
            let name = |s: &str| canonical(&s.to_lowercase());
            let mut by_path: HashMap<String, usize> = HashMap::new();
            let mut by_name_size: HashMap<String, usize> = HashMap::new();
            let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
            for (i, s) in songs.iter().enumerate() {
                by_path.entry(canonical(&s.path)).or_insert(i);
                by_name_size
                    .entry(format!("{}|{}", name(&s.file_name), s.file_size))
                    .or_insert(i);
                by_name.entry(name(&s.file_name)).or_default().push(i);
            }
            let mut matched = 0;
            for e in entries {
                let mut target = e
                    .path
                    .as_ref()
                    .and_then(|p| by_path.get(&canonical(p)).copied());
                if target.is_none()
                    && let Some(size) = e.size
                {
                    target = by_name_size
                        .get(&format!("{}|{size}", name(&e.file_name)))
                        .copied();
                }
                if target.is_none() {
                    target = by_name
                        .get(&name(&e.file_name))
                        .filter(|c| c.len() == 1)
                        .map(|c| c[0]);
                }
                let Some(i) = target else { continue };
                // Each match updates the song as it was read before the loop (as Swift does), so
                // a song matched twice keeps the last entry's analysis.
                let mut rec = songs[i].clone();
                rec.apply(&e.analysis);
                write_song(&tx, &rec, true)?;
                matched += 1;
            }
            tx.commit()?;
            Ok(matched)
        })
    }
}

fn library_row(r: &Row) -> rusqlite::Result<Library> {
    Ok(Library {
        id: r.get(0)?,
        kind: r.get(1)?,
        path: r.get(2)?,
        bookmark: r.get(3)?,
        added_at: r.get(4)?,
    })
}
