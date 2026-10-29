//! The category tables: per-sound choices (`SoundCategories.swift`), folder rules and Earmark's
//! folder guesses (`FolderRules.swift`), and the owner's song corrections (`SongCorrections.swift`).

use crate::{LibraryDatabase, Result};
use earmark_core::analysis::categories::SoundCategoryChoice;
use earmark_core::analysis::folder_rules::{FolderGuess, FolderRule};
use earmark_core::dates;
use earmark_core::song_corrections::SongCorrection;
use rusqlite::{Connection, Row, params};
use std::collections::{HashMap, HashSet};

fn table_exists(c: &Connection, name: &str) -> rusqlite::Result<bool> {
    c.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
        [name],
        |r| r.get(0),
    )
}

fn choice_row(r: &Row) -> rusqlite::Result<SoundCategoryChoice> {
    Ok(SoundCategoryChoice {
        sound_id: r.get(0)?,
        fingerprint: r.get(1)?,
        cat_id: r.get(2)?,
        by_owner: r.get(3)?,
        share: r.get(4)?,
        replaced: r.get(5)?,
        version: r.get(6)?,
        created_at: r.get(7)?,
    })
}

fn save_choice(c: &Connection, x: &SoundCategoryChoice) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO soundCategory (soundId, fingerprint, catID, byOwner, share, replaced, version, createdAt) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(soundId) DO UPDATE SET fingerprint = ?2, catID = ?3, \
         byOwner = ?4, share = ?5, replaced = ?6, version = ?7, createdAt = ?8",
        params![x.sound_id, x.fingerprint, x.cat_id, x.by_owner, x.share, x.replaced, x.version, x.created_at],
    )?;
    Ok(())
}

const CHOICE_COLUMNS: &str =
    "soundId, fingerprint, catID, byOwner, share, replaced, version, createdAt";

impl LibraryDatabase {
    // MARK: per-sound categories

    pub fn sound_category_choices(&self) -> Result<HashMap<i64, SoundCategoryChoice>> {
        self.with(|c| {
            if !table_exists(c, "soundCategory")? {
                return Ok(HashMap::new());
            }
            let mut st = c.prepare(&format!("SELECT {CHOICE_COLUMNS} FROM soundCategory"))?;
            let mut out = HashMap::new();
            for x in st.query_map([], choice_row)? {
                let x = x?;
                out.entry(x.sound_id).or_insert(x);
            }
            Ok(out)
        })
    }

    /// The owner's category for these sounds; None takes their choice away.
    pub fn set_sound_category(
        &self,
        sounds: &[(i64, Option<String>)],
        cat_id: Option<&str>,
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for (id, fp) in sounds {
                match cat_id {
                    Some(cat) => save_choice(
                        &tx,
                        &SoundCategoryChoice {
                            sound_id: *id,
                            fingerprint: fp.clone(),
                            cat_id: cat.into(),
                            by_owner: true,
                            share: None,
                            replaced: None,
                            version: earmark_core::analysis::categories::VERSION,
                            created_at: dates::now(),
                        },
                    )?,
                    None => {
                        tx.execute("DELETE FROM soundCategory WHERE soundId = ?1", [id])?;
                    }
                }
            }
            tx.commit()
        })
    }

    /// Replaces Earmark's per-sound guesses; the owner's choices stay. True if anything changed.
    pub fn replace_sound_guesses(&self, guesses: &[SoundCategoryChoice]) -> Result<bool> {
        self.with(|c| {
            let tx = c.transaction()?;
            let old: Vec<SoundCategoryChoice> = {
                let mut st = tx.prepare(&format!("SELECT {CHOICE_COLUMNS} FROM soundCategory WHERE byOwner = 0"))?;
                st.query_map([], choice_row)?.collect::<rusqlite::Result<_>>()?
            };
            let owners: HashSet<i64> = {
                let mut st = tx.prepare("SELECT soundId FROM soundCategory WHERE byOwner = 1")?;
                st.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
            };
            let new: Vec<&SoundCategoryChoice> = guesses.iter().filter(|g| !owners.contains(&g.sound_id)).collect();
            let key = |x: &SoundCategoryChoice| format!("{} {} {}", x.sound_id, x.cat_id, x.fingerprint.as_deref().unwrap_or(""));
            let a: HashSet<String> = old.iter().map(key).collect();
            let b: HashSet<String> = new.iter().map(|x| key(x)).collect();
            if a == b {
                return Ok(false);
            }
            tx.execute("DELETE FROM soundCategory WHERE byOwner = 0", [])?;
            for g in new {
                tx.execute(
                    &format!("INSERT INTO soundCategory ({CHOICE_COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"),
                    params![g.sound_id, g.fingerprint, g.cat_id, g.by_owner, g.share, g.replaced, g.version, g.created_at],
                )?;
            }
            tx.commit()?;
            Ok(true)
        })
    }

    // MARK: folder rules and guesses

    pub fn folder_rules(&self) -> Result<Vec<FolderRule>> {
        self.with(|c| {
            let mut st = c.prepare("SELECT libraryId, folder, catID, createdAt FROM folderRule")?;
            st.query_map([], |r| {
                Ok(FolderRule {
                    library_id: r.get(0)?,
                    folder: r.get(1)?,
                    cat_id: r.get(2)?,
                    created_at: r.get(3)?,
                })
            })?
            .collect()
        })
    }

    pub fn save_folder_rules(&self, rules: &[FolderRule]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for r in rules {
                tx.execute(
                    "INSERT INTO folderRule (libraryId, folder, catID, createdAt) VALUES (?1, ?2, ?3, ?4) \
                     ON CONFLICT(libraryId, folder) DO UPDATE SET catID = ?3, createdAt = ?4",
                    params![r.library_id, r.folder, r.cat_id, r.created_at],
                )?;
            }
            tx.commit()
        })
    }

    pub fn remove_folder_rule(&self, library_id: i64, folder: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "DELETE FROM folderRule WHERE libraryId = ?1 AND folder = ?2",
                params![library_id, folder],
            )?;
            Ok(())
        })
    }

    pub fn folder_guesses(&self) -> Result<Vec<FolderGuess>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT libraryId, folder, catID, alternatives, reason, isUnsure, analysed, version, createdAt FROM folderGuess",
            )?;
            st.query_map([], |r| {
                Ok(FolderGuess {
                    library_id: r.get(0)?,
                    folder: r.get(1)?,
                    cat_id: r.get(2)?,
                    alternatives: r.get(3)?,
                    reason: r.get(4)?,
                    is_unsure: r.get(5)?,
                    analysed: r.get(6)?,
                    version: r.get(7)?,
                    created_at: r.get(8)?,
                })
            })?
            .collect()
        })
    }

    /// Saves new guesses and forgets those of folders that no longer need one.
    pub fn update_guesses(&self, saving: &[FolderGuess], removing: &[(i64, String)]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for g in saving {
                tx.execute(
                    "INSERT INTO folderGuess (libraryId, folder, catID, alternatives, reason, isUnsure, analysed, version, \
                     createdAt) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) ON CONFLICT(libraryId, folder) DO UPDATE SET \
                     catID = ?3, alternatives = ?4, reason = ?5, isUnsure = ?6, analysed = ?7, version = ?8, createdAt = ?9",
                    params![
                        g.library_id, g.folder, g.cat_id, g.alternatives, g.reason, g.is_unsure, g.analysed, g.version,
                        g.created_at
                    ],
                )?;
            }
            for (lib, folder) in removing {
                tx.execute("DELETE FROM folderGuess WHERE libraryId = ?1 AND folder = ?2", params![lib, folder])?;
            }
            tx.commit()
        })
    }

    // MARK: song corrections

    pub fn song_corrections(&self) -> Result<Vec<SongCorrection>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT path, bpm, bpmLow, bpmHigh, keyPitchClass, keyMinor, beatsPerBar, correctedAt FROM songCorrection",
            )?;
            st.query_map([], |r| {
                Ok(SongCorrection {
                    path: r.get(0)?,
                    bpm: r.get(1)?,
                    bpm_low: r.get(2)?,
                    bpm_high: r.get(3)?,
                    key_pitch_class: r.get(4)?,
                    key_minor: r.get(5)?,
                    beats_per_bar: r.get(6)?,
                    corrected_at: r.get(7)?,
                })
            })?
            .collect()
        })
    }

    /// Saves these songs' corrections; None removes the song's.
    pub fn set_song_corrections(&self, changes: &[(String, Option<SongCorrection>)]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for (path, correction) in changes {
                match correction {
                    Some(x) => {
                        tx.execute(
                            "INSERT INTO songCorrection (path, bpm, bpmLow, bpmHigh, keyPitchClass, keyMinor, beatsPerBar, \
                             correctedAt) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(path) DO UPDATE SET bpm = ?2, \
                             bpmLow = ?3, bpmHigh = ?4, keyPitchClass = ?5, keyMinor = ?6, beatsPerBar = ?7, correctedAt = ?8",
                            params![
                                x.path, x.bpm, x.bpm_low, x.bpm_high, x.key_pitch_class, x.key_minor, x.beats_per_bar,
                                x.corrected_at
                            ],
                        )?;
                    }
                    None => {
                        tx.execute("DELETE FROM songCorrection WHERE path = ?1", [path])?;
                    }
                }
            }
            tx.commit()
        })
    }
}
