//! The library database as the Mac app calls it (step 8j): `earmark_db::LibraryDatabase` behind
//! one UniFFI object. Records cross as JSON in the engine's own shape (the rows as stored: dates
//! as GRDB's text, bytes as lists); the Swift side turns them into the app's records.

use earmark_core::analysis::categories::SoundCategoryChoice;
use earmark_core::analysis::folder_rules::{FolderGuess, FolderRule};
use earmark_core::analysis::groups::Name;
use earmark_core::analysis_file::AnalysisFile;
use earmark_core::phase0::{Entry, SongAnalysis};
use earmark_core::scan::{self, ScannedSound};
use earmark_core::song_corrections::SongCorrection;
use earmark_db::{LibraryDatabase, SongFile};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;

/// Why a database call failed, with the engine's message.
#[derive(Debug, uniffi::Error)]
pub enum DatabaseError {
    Failed { message: String },
}

impl std::fmt::Display for DatabaseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DatabaseError::Failed { message } => f.write_str(message),
        }
    }
}

type Answer<T> = Result<T, DatabaseError>;

fn failed(e: impl std::fmt::Display) -> DatabaseError {
    DatabaseError::Failed {
        message: e.to_string(),
    }
}

fn read<T: DeserializeOwned>(json: &str) -> Answer<T> {
    serde_json::from_str(json).map_err(|e| failed(format!("bad request from the app: {e}")))
}

fn write<T: Serialize>(value: &T) -> Answer<String> {
    serde_json::to_string(value).map_err(failed)
}

/// Each sound's float vectors, one block per model asked for.
#[uniffi::export(with_foreign)]
pub trait VectorListener: Send + Sync {
    fn count(&self, sounds: u64);
    /// `data`: the blocks' floats one after another (little-endian), `lengths[i]` floats each.
    fn vectors(&self, id: i64, data: Vec<u8>, lengths: Vec<u32>);
}

/// Reads a sound file's fingerprint as the engine does (the same as Swift's `Fingerprint.of`).
fn fingerprint(path: &Path) -> Option<String> {
    scan::fingerprint(path)
}

#[derive(uniffi::Object)]
pub struct EngineDatabase {
    db: LibraryDatabase,
}

#[uniffi::export]
impl EngineDatabase {
    /// Opens (and migrates, unless `read_only`) the database at `path`; none: in memory.
    #[uniffi::constructor]
    pub fn open(path: Option<String>, read_only: bool) -> Answer<Arc<EngineDatabase>> {
        let db =
            LibraryDatabase::open(path.as_deref().map(Path::new), read_only).map_err(failed)?;
        Ok(Arc::new(EngineDatabase { db }))
    }

    // MARK: libraries

    pub fn add_library(
        &self,
        kind: String,
        path: String,
        bookmark: Option<Vec<u8>>,
    ) -> Answer<String> {
        write(
            &self
                .db
                .add_library(&kind, &path, bookmark.as_deref())
                .map_err(failed)?,
        )
    }

    pub fn libraries(&self, kind: Option<String>) -> Answer<String> {
        write(&self.db.libraries(kind.as_deref()).map_err(failed)?)
    }

    pub fn remove_library(&self, id: i64) -> Answer<()> {
        self.db.remove_library(id).map_err(failed)
    }

    // MARK: sounds

    /// `scanned`: JSON of `ScannedSound`s (`modified` in seconds since 1970).
    pub fn replace_sounds(&self, library_id: i64, root: String, scanned: String) -> Answer<()> {
        let scanned: Vec<ScannedSound> = read(&scanned)?;
        self.db
            .replace_sounds(library_id, &root, &scanned)
            .map_err(failed)
    }

    pub fn sounds(&self, library_id: Option<i64>) -> Answer<String> {
        write(&self.db.sounds(library_id).map_err(failed)?)
    }

    /// A list of facts (one per sound).
    pub fn sound_facts(&self) -> Answer<String> {
        let facts = self.db.sound_facts().map_err(failed)?;
        let mut list: Vec<_> = facts.into_values().collect();
        list.sort_by_key(|f| f.sound_id);
        write(&list)
    }

    pub fn save_facts(&self, facts: String) -> Answer<()> {
        self.db.save_facts(&read::<Vec<_>>(&facts)?).map_err(failed)
    }

    /// A list of `{soundId, fingerprint, version}`.
    pub fn embedding_status(&self, model: String) -> Answer<String> {
        let status = self.db.embedding_status(&model).map_err(failed)?;
        let mut list: Vec<Value> = status
            .into_iter()
            .map(|(id, s)| json!({"soundId": id, "fingerprint": s.fingerprint, "version": s.version}))
            .collect();
        list.sort_by_key(|v| v["soundId"].as_i64());
        write(&list)
    }

    /// Every sound's vector for `model`, flat, with each sound's id and length.
    pub fn vectors(&self, model: String) -> Answer<StoredVectors> {
        let found = self.db.vectors(&model).map_err(failed)?;
        Ok(StoredVectors {
            ids: found.iter().map(|v| v.0).collect(),
            lengths: found.iter().map(|v| v.1.len() as u32).collect(),
            data: floats_to_bytes(found.iter().flat_map(|v| v.1.iter())),
        })
    }

    /// Each sound with a vector from every one of `models` (in id order), one at a time.
    pub fn for_each_vectors(
        &self,
        models: Vec<String>,
        ids: Option<Vec<i64>>,
        listener: Arc<dyn VectorListener>,
    ) -> Answer<()> {
        let models: Vec<&str> = models.iter().map(String::as_str).collect();
        self.db
            .for_each_vectors(
                &models,
                ids.as_deref(),
                &mut |n| listener.count(n as u64),
                &mut |id, blocks| {
                    let lengths = blocks.iter().map(|b| b.len() as u32).collect();
                    listener.vectors(id, floats_to_bytes(blocks.iter().flatten()), lengths)
                },
            )
            .map_err(failed)
    }

    /// One stored embedding (JSON), or none.
    pub fn embedding(&self, sound_id: i64, model: String) -> Answer<Option<String>> {
        match self.db.embedding(sound_id, &model).map_err(failed)? {
            Some(e) => Ok(Some(write(&e)?)),
            None => Ok(None),
        }
    }

    pub fn save_embeddings(&self, embeddings: String) -> Answer<()> {
        self.db
            .save_embeddings(&read::<Vec<_>>(&embeddings)?)
            .map_err(failed)
    }

    pub fn near_duplicates(&self) -> Answer<Vec<crate::DuplicatePair>> {
        Ok(self
            .db
            .near_duplicates()
            .map_err(failed)?
            .into_iter()
            .map(crate::DuplicatePair::from)
            .collect())
    }

    pub fn save_near_duplicates(&self, pairs: Vec<crate::DuplicatePair>) -> Answer<()> {
        let pairs: Vec<_> = pairs
            .into_iter()
            .map(|p| {
                earmark_core::analysis::duplicates::Pair::new(p.a, p.b, p.identical, p.similarity)
            })
            .collect();
        self.db.save_near_duplicates(&pairs).map_err(failed)
    }

    // MARK: songs

    /// `files`: JSON of `SongFile`s (`modified` in seconds since 1970).
    pub fn replace_songs(&self, library_id: i64, root: String, files: String) -> Answer<()> {
        let files: Vec<SongFile> = read(&files)?;
        self.db
            .replace_songs(library_id, &root, &files)
            .map_err(failed)
    }

    pub fn songs(&self, library_id: Option<i64>) -> Answer<String> {
        write(&self.db.songs(library_id).map_err(failed)?)
    }

    /// `results`: JSON list of `[songId, analysis]`; the songs as saved.
    pub fn save_song_analysis(&self, results: String) -> Answer<String> {
        let results: Vec<(i64, SongAnalysis)> = read(&results)?;
        write(&self.db.save_song_analysis(&results).map_err(failed)?)
    }

    pub fn apply_song_analysis(&self, entries: String) -> Answer<u64> {
        let entries: Vec<Entry> = read(&entries)?;
        Ok(self.db.apply_song_analysis(&entries).map_err(failed)? as u64)
    }

    pub fn song_corrections(&self) -> Answer<String> {
        write(&self.db.song_corrections().map_err(failed)?)
    }

    /// `changes`: JSON list of `[path, correction or null]`.
    pub fn set_song_corrections(&self, changes: String) -> Answer<()> {
        let changes: Vec<(String, Option<SongCorrection>)> = read(&changes)?;
        self.db.set_song_corrections(&changes).map_err(failed)
    }

    // MARK: categories

    /// A list of choices (one per sound).
    pub fn sound_category_choices(&self) -> Answer<String> {
        let mut list: Vec<SoundCategoryChoice> = self
            .db
            .sound_category_choices()
            .map_err(failed)?
            .into_values()
            .collect();
        list.sort_by_key(|c| c.sound_id);
        write(&list)
    }

    /// `sounds`: JSON list of `[id, fingerprint]`.
    pub fn set_sound_category(&self, sounds: String, cat_id: Option<String>) -> Answer<()> {
        let sounds: Vec<(i64, Option<String>)> = read(&sounds)?;
        self.db
            .set_sound_category(&sounds, cat_id.as_deref())
            .map_err(failed)
    }

    pub fn replace_sound_guesses(&self, guesses: String) -> Answer<bool> {
        let guesses: Vec<SoundCategoryChoice> = read(&guesses)?;
        self.db.replace_sound_guesses(&guesses).map_err(failed)
    }

    pub fn folder_rules(&self) -> Answer<String> {
        write(&self.db.folder_rules().map_err(failed)?)
    }

    pub fn save_folder_rules(&self, rules: String) -> Answer<()> {
        let rules: Vec<FolderRule> = read(&rules)?;
        self.db.save_folder_rules(&rules).map_err(failed)
    }

    pub fn remove_folder_rule(&self, library_id: i64, folder: String) -> Answer<()> {
        self.db
            .remove_folder_rule(library_id, &folder)
            .map_err(failed)
    }

    pub fn folder_guesses(&self) -> Answer<String> {
        write(&self.db.folder_guesses().map_err(failed)?)
    }

    /// `removing`: JSON list of `[libraryId, folder]`.
    pub fn update_guesses(&self, saving: String, removing: String) -> Answer<()> {
        let saving: Vec<FolderGuess> = read(&saving)?;
        let removing: Vec<(i64, String)> = read(&removing)?;
        self.db.update_guesses(&saving, &removing).map_err(failed)
    }

    // MARK: groups

    /// `{sets, groups, membership, memberFingerprints}`: the sets and groups as stored, and
    /// each grouped sound's group and fingerprint as lists of `[soundId, value]`.
    pub fn group_snapshot(&self) -> Answer<String> {
        let snap = self.db.group_snapshot().map_err(failed)?;
        let mut membership: Vec<(i64, i64)> = snap.plan.membership.into_iter().collect();
        membership.sort();
        let mut prints: Vec<(i64, Option<String>)> =
            snap.plan.member_fingerprints.into_iter().collect();
        prints.sort();
        write(&json!({
            "sets": snap.plan.sets,
            "groups": snap.groups,
            "membership": membership,
            "memberFingerprints": prints,
        }))
    }

    /// `groups`: JSON list of groups, each a list of `[id, fingerprint]`; `names`: one per group.
    pub fn replace_groups(&self, cat_id: String, groups: String, names: String) -> Answer<()> {
        let groups: Vec<Vec<(i64, Option<String>)>> = read(&groups)?;
        let names: Vec<Name> = read(&names)?;
        self.db
            .replace_groups(&cat_id, &groups, &names)
            .map_err(failed)
    }

    /// `add`: JSON list of `[id, fingerprint, group]`.
    pub fn update_groups(&self, cat_id: String, add: String, remove: Vec<i64>) -> Answer<()> {
        let add: Vec<(i64, Option<String>, i64)> = read(&add)?;
        self.db
            .update_groups(&cat_id, &add, &remove)
            .map_err(failed)
    }

    pub fn drop_groups(&self, cat_id: String) -> Answer<()> {
        self.db.drop_groups(&cat_id).map_err(failed)
    }

    pub fn rename_group(&self, id: i64, name: Option<String>) -> Answer<()> {
        self.db.rename_group(id, name.as_deref()).map_err(failed)
    }

    /// `sounds`: JSON list of `[id, fingerprint]`.
    pub fn move_sounds(&self, sounds: String, group: i64) -> Answer<()> {
        let sounds: Vec<(i64, Option<String>)> = read(&sounds)?;
        self.db.move_sounds(&sounds, group).map_err(failed)
    }

    /// `sounds`: JSON list of `[id, fingerprint]`; the new group's id.
    pub fn new_group(&self, cat_id: String, name: String, sounds: String) -> Answer<i64> {
        let sounds: Vec<(i64, Option<String>)> = read(&sounds)?;
        self.db.new_group(&cat_id, &name, &sounds).map_err(failed)
    }

    pub fn merge_groups(&self, groups: Vec<i64>, target: i64) -> Answer<()> {
        self.db.merge_groups(&groups, target).map_err(failed)
    }

    pub fn regroup(&self, cat_id: String) -> Answer<()> {
        self.db.regroup(&cat_id).map_err(failed)
    }

    // MARK: analysis files

    /// `library`: JSON of the library; the file as JSON (its own format).
    pub fn analysis_file(
        &self,
        library: String,
        include_embeddings: bool,
        exported_at: String,
    ) -> Answer<String> {
        let library = read(&library)?;
        write(
            &self
                .db
                .analysis_file(&library, include_embeddings, &exported_at, &fingerprint)
                .map_err(failed)?,
        )
    }

    /// Writes the file at `path`; how many entries it holds.
    pub fn write_analysis_file(
        &self,
        library: String,
        include_embeddings: bool,
        path: String,
        exported_at: String,
    ) -> Answer<u64> {
        let library = read(&library)?;
        Ok(self
            .db
            .write_analysis_file(
                &library,
                include_embeddings,
                Path::new(&path),
                &exported_at,
                &fingerprint,
            )
            .map_err(failed)? as u64)
    }

    /// `file`: an analysis file's JSON; the report as JSON.
    pub fn import_analysis(&self, file: String) -> Answer<String> {
        let file: AnalysisFile = read(&file)?;
        write(
            &self
                .db
                .import_analysis(&file, &fingerprint)
                .map_err(failed)?,
        )
    }
}

/// Vectors one after another: `lengths[i]` floats for `ids[i]`, as little-endian bytes (UniFFI
/// copies bytes in one go; a list of floats crosses one number at a time, 40 times slower).
#[derive(uniffi::Record)]
pub struct StoredVectors {
    pub ids: Vec<i64>,
    pub lengths: Vec<u32>,
    pub data: Vec<u8>,
}

fn floats_to_bytes<'a>(values: impl Iterator<Item = &'a f32>) -> Vec<u8> {
    values.flat_map(|v| v.to_le_bytes()).collect()
}
