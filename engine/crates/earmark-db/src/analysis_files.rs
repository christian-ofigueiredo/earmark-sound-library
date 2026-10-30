//! Exporting and importing analysis files (`AnalysisFiles.swift`). An import never overwrites:
//! current results, the owner's folder categories and corrections stay as they are.

use crate::categories::{save_choice, save_rule};
use crate::{DbError, LibraryDatabase, Result, save_embedding, save_fact};
use earmark_core::analysis::categories::{SoundCategoryChoice, VERSION as CATEGORY_VERSION};
use earmark_core::analysis::folder_rules::FolderRule;
use earmark_core::analysis_file::{
    AnalysisFile, Embedding, Facts, FolderCategory, ImportReport, Song, SongValues, Sound,
};
use earmark_core::dates;
use earmark_core::music_key::MusicKey;
use earmark_core::paths::canonical;
use earmark_core::phase0::SongAnalysis;
use earmark_core::records::{
    EMBEDDING_MODELS, EmbeddingStatus, Library, SongRecord, SoundEmbedding, SoundFacts, SoundRecord,
};
use earmark_core::song_corrections::SongCorrection;
use earmark_core::ucs::UcsCatalog;
use rusqlite::Row;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::Write;
use std::path::Path;

/// Reads a song's fingerprint (songs have none stored); None for a file it can't read.
pub type FingerprintReader<'a> = &'a dyn Fn(&Path) -> Option<String>;

/// A stored embedding's model, fingerprint, version, vector and error.
type StoredEmbedding = (String, Option<String>, i64, Option<Vec<u8>>, Option<String>);

/// How many sounds a written file gathers at a time.
const BATCH: usize = 2_000;

fn io_error(e: impl std::fmt::Display) -> DbError {
    DbError::File(e.to_string())
}

fn facts_row(r: &Row) -> rusqlite::Result<SoundFacts> {
    Ok(SoundFacts {
        sound_id: r.get(0)?,
        fingerprint: r.get(1)?,
        version: r.get(2)?,
        loudness: r.get(3)?,
        peak: r.get(4)?,
        error: r.get(5)?,
        analyzed_at: r.get(6)?,
    })
}

impl LibraryDatabase {
    // MARK: export

    /// Everything Earmark worked out for one library.
    pub fn analysis_file(
        &self,
        library: &Library,
        include_embeddings: bool,
        exported_at: &str,
        fingerprint: FingerprintReader,
    ) -> Result<AnalysisFile> {
        let mut file = AnalysisFile::new(exported_at, library);
        if library.kind == "music" {
            let corrections: HashMap<String, SongCorrection> = self
                .song_corrections()?
                .into_iter()
                .map(|c| (canonical(&c.path), c))
                .collect();
            let mut songs = Vec::new();
            for s in self.songs(Some(library.id))? {
                let c = corrections.get(&canonical(&s.path));
                if !s.is_analysed() && c.is_none() {
                    continue;
                }
                songs.push(Song {
                    path: s.path_in_library(),
                    size: s.file_size,
                    fingerprint: fingerprint(Path::new(&s.path)),
                    analysis: s.is_analysed().then(|| SongValues::from_song(&s)),
                    correction: c.map(SongValues::from_correction),
                });
            }
            file.songs = Some(songs);
        } else {
            let sounds = self.sounds(Some(library.id))?;
            file.sounds = Some(self.sound_entries(&sounds, include_embeddings)?);
            file.folder_categories = Some(self.folder_entries(library.id)?);
        }
        Ok(file)
    }

    /// Writes the library's analysis file to `path` (replacing one there), the sounds a batch at a
    /// time, as they can be hundreds of MB. Returns its size in bytes.
    pub fn write_analysis_file(
        &self,
        library: &Library,
        include_embeddings: bool,
        path: &Path,
        exported_at: &str,
        fingerprint: FingerprintReader,
    ) -> Result<usize> {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let partial = path.with_file_name(format!(".{name}.partial"));
        let written = self.write_partial(
            library,
            include_embeddings,
            &partial,
            exported_at,
            fingerprint,
        );
        let finished = written.and_then(|bytes| {
            std::fs::rename(&partial, path)
                .map(|_| bytes)
                .map_err(io_error)
        });
        if finished.is_err() {
            let _ = std::fs::remove_file(&partial);
        }
        finished
    }

    fn write_partial(
        &self,
        library: &Library,
        include_embeddings: bool,
        partial: &Path,
        exported_at: &str,
        fingerprint: FingerprintReader,
    ) -> Result<usize> {
        let mut out = std::io::BufWriter::new(std::fs::File::create(partial).map_err(io_error)?);
        let mut bytes = 0;
        let mut write = |d: &[u8]| -> Result<()> {
            out.write_all(d).map_err(io_error)?;
            bytes += d.len();
            Ok(())
        };
        if library.kind == "music" {
            let file = self.analysis_file(library, include_embeddings, exported_at, fingerprint)?;
            write(&file.encoded().map_err(io_error)?)?;
        } else {
            // The rest of the file, then the sounds spliced in before its closing brace.
            let mut head = AnalysisFile::new(exported_at, library);
            head.folder_categories = Some(self.folder_entries(library.id)?);
            let encoded = head.encoded().map_err(io_error)?;
            write(&encoded[..encoded.len() - 1])?;
            write(br#","sounds":["#)?;
            let sounds = self.sounds(Some(library.id))?;
            let mut first = true;
            for batch in sounds.chunks(BATCH) {
                for entry in self.sound_entries(batch, include_embeddings)? {
                    if !first {
                        write(b",")?;
                    }
                    first = false;
                    write(&serde_json::to_vec(&entry).map_err(io_error)?)?;
                }
            }
            write(b"]}")?;
        }
        out.flush().map_err(io_error)?;
        Ok(bytes)
    }

    fn folder_entries(&self, library_id: i64) -> Result<Vec<FolderCategory>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT folder, catID FROM folderRule WHERE libraryId = ?1 ORDER BY folder",
            )?;
            st.query_map([library_id], |r| {
                Ok(FolderCategory {
                    folder: r.get(0)?,
                    cat_id: r.get(1)?,
                })
            })?
            .collect()
        })
    }

    /// The file's entries for these sounds: results that hold for their content (a file that
    /// couldn't be read here may be read on the other machine).
    fn sound_entries(
        &self,
        sounds: &[SoundRecord],
        include_embeddings: bool,
    ) -> Result<Vec<Sound>> {
        let ids = sounds
            .iter()
            .filter_map(|s| s.id)
            .map(|i| i.to_string())
            .collect::<Vec<_>>()
            .join(",");
        let (facts, embeddings, choices) = self.with(|c| {
            let mut st = c.prepare(&format!(
                "SELECT soundId, fingerprint, version, loudness, peak, error, analyzedAt FROM soundFacts WHERE soundId IN ({ids})"
            ))?;
            let facts: HashMap<i64, SoundFacts> =
                st.query_map([], facts_row)?.map(|f| f.map(|f| (f.sound_id, f))).collect::<rusqlite::Result<_>>()?;
            let mut embeddings: HashMap<i64, Vec<StoredEmbedding>> = HashMap::new();
            if include_embeddings {
                let mut st = c.prepare(&format!(
                    "SELECT soundId, model, fingerprint, version, vector, error FROM soundEmbedding WHERE soundId IN ({ids})"
                ))?;
                let mut rows = st.query([])?;
                while let Some(r) = rows.next()? {
                    embeddings.entry(r.get(0)?).or_default().push((r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?));
                }
            }
            let mut st = c.prepare(&format!(
                "SELECT soundId, fingerprint, catID FROM soundCategory WHERE byOwner = 1 AND soundId IN ({ids})"
            ))?;
            let choices: HashMap<i64, (Option<String>, String)> = st
                .query_map([], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?))))?
                .collect::<rusqlite::Result<_>>()?;
            Ok((facts, embeddings, choices))
        })?;
        let mut out = Vec::new();
        for s in sounds {
            let (Some(id), Some(fp)) = (s.id, s.fingerprint.as_ref()) else {
                continue;
            };
            let f = facts
                .get(&id)
                .filter(|f| f.fingerprint.as_ref() == Some(fp) && f.error.is_none());
            let mut vectors: BTreeMap<String, Embedding> = BTreeMap::new();
            for (model, efp, version, vector, error) in
                embeddings.get(&id).map(Vec::as_slice).unwrap_or(&[])
            {
                if efp.as_ref() == Some(fp) && error.is_none() {
                    vectors.insert(
                        model.clone(),
                        Embedding {
                            version: *version,
                            vector: vector.clone(),
                        },
                    );
                }
            }
            let category = choices
                .get(&id)
                .filter(|c| c.0.as_ref() == Some(fp))
                .map(|c| c.1.clone());
            if f.is_none() && vectors.is_empty() && category.is_none() {
                continue;
            }
            out.push(Sound {
                path: s.path_in_library(),
                fingerprint: fp.clone(),
                facts: f.map(|f| Facts {
                    version: f.version,
                    loudness: f.loudness,
                    peak: f.peak,
                }),
                embeddings: (!vectors.is_empty()).then_some(vectors),
                category,
            });
        }
        Ok(out)
    }

    // MARK: import

    /// Adds what the file has and this database doesn't, for files in any library of the same
    /// kind whose content matches.
    pub fn import_analysis(
        &self,
        file: &AnalysisFile,
        fingerprint: FingerprintReader,
    ) -> Result<ImportReport> {
        let mut report = ImportReport::default();
        if let Some(sounds) = &file.sounds {
            self.import_sounds(
                sounds,
                file.folder_categories.as_deref().unwrap_or(&[]),
                &mut report,
            )?;
        }
        if let Some(songs) = &file.songs {
            self.import_songs(songs, fingerprint, &mut report)?;
        }
        Ok(report)
    }

    fn import_sounds(
        &self,
        entries: &[Sound],
        folders: &[FolderCategory],
        report: &mut ImportReport,
    ) -> Result<()> {
        let catalog = UcsCatalog::shared();
        let local = self.sounds(None)?;
        let mut by_fingerprint: HashMap<&str, Vec<&SoundRecord>> = HashMap::new();
        for s in &local {
            if let Some(f) = &s.fingerprint {
                by_fingerprint.entry(f).or_default().push(s);
            }
        }
        let facts = self.sound_facts()?;
        let mut status: HashMap<&str, HashMap<i64, EmbeddingStatus>> = HashMap::new();
        for model in EMBEDDING_MODELS {
            status.insert(model, self.embedding_status(model)?);
        }
        let owners: HashSet<i64> = self
            .sound_category_choices()?
            .into_iter()
            .filter(|(_, c)| c.by_owner)
            .map(|(id, _)| id)
            .collect();
        let now = dates::now();
        let mut new_facts: HashMap<i64, SoundFacts> = HashMap::new();
        let mut new_embeddings: HashMap<(i64, String), SoundEmbedding> = HashMap::new();
        let mut new_categories: HashMap<i64, SoundCategoryChoice> = HashMap::new();
        let mut matched_libraries: BTreeMap<i64, usize> = BTreeMap::new();
        report.sounds = entries.len();
        for entry in entries {
            let Some(matches) = by_fingerprint.get(entry.fingerprint.as_str()) else {
                continue;
            };
            report.sounds_matched += 1;
            for s in matches {
                let Some(id) = s.id else { continue };
                *matched_libraries.entry(s.library_id).or_default() += 1;
                if let Some(f) = &entry.facts
                    && f.version >= SoundFacts::CURRENT_VERSION
                    && !facts.get(&id).is_some_and(|x| x.is_current(s))
                {
                    new_facts.insert(
                        id,
                        SoundFacts {
                            sound_id: id,
                            fingerprint: s.fingerprint.clone(),
                            version: f.version,
                            loudness: f.loudness,
                            peak: f.peak,
                            error: None,
                            analyzed_at: now.clone(),
                        },
                    );
                }
                // The owner's category for the sound, unless they chose one here.
                if let Some(c) = &entry.category
                    && !owners.contains(&id)
                    && catalog.entry_by_cat_id(Some(c)).is_some()
                {
                    new_categories.insert(
                        id,
                        SoundCategoryChoice {
                            sound_id: id,
                            fingerprint: s.fingerprint.clone(),
                            cat_id: c.clone(),
                            by_owner: true,
                            share: None,
                            replaced: None,
                            version: CATEGORY_VERSION,
                            created_at: now.clone(),
                        },
                    );
                }
                for (model, e) in entry.embeddings.iter().flatten() {
                    // Only models this Earmark knows, at its version or newer.
                    if !EMBEDDING_MODELS.contains(&model.as_str())
                        || e.version < SoundEmbedding::version_of(model)
                        || EmbeddingStatus::is_current(
                            status.get(model.as_str()).and_then(|m| m.get(&id)),
                            model,
                            s,
                        )
                    {
                        continue;
                    }
                    new_embeddings.insert(
                        (id, model.clone()),
                        SoundEmbedding {
                            sound_id: id,
                            model: model.clone(),
                            fingerprint: s.fingerprint.clone(),
                            version: e.version,
                            vector: e.vector.clone(),
                            error: None,
                            analyzed_at: now.clone(),
                        },
                    );
                }
            }
        }
        report.facts = new_facts.len();
        report.embeddings = new_embeddings.len();
        // Folder categories go to the library most of the file's sounds were found in (the lowest
        // id on a tie), for folders it has and the owner hasn't chosen a category for.
        let mut new_rules: Vec<FolderRule> = Vec::new();
        let top = matched_libraries
            .iter()
            .rev()
            .max_by_key(|(_, n)| **n)
            .map(|(id, _)| *id);
        if let Some(library_id) = top {
            let existing: HashSet<String> = self
                .folder_rules()?
                .into_iter()
                .filter(|r| r.library_id == library_id)
                .map(|r| canonical(&r.folder))
                .collect();
            let present: HashSet<String> = local
                .iter()
                .filter(|s| s.library_id == library_id)
                .map(|s| canonical(&s.folder))
                .collect();
            for f in folders {
                let folder = canonical(&f.folder);
                let inside = format!("{folder}/");
                if !existing.contains(&folder)
                    && catalog.entry_by_cat_id(Some(&f.cat_id)).is_some()
                    && (present.contains(&folder) || present.iter().any(|p| p.starts_with(&inside)))
                {
                    new_rules.push(FolderRule {
                        library_id,
                        folder: f.folder.clone(),
                        cat_id: f.cat_id.clone(),
                        created_at: now.clone(),
                    });
                }
            }
        }
        report.folder_categories = new_rules.len();
        report.sound_categories = new_categories.len();
        self.with(|c| {
            let tx = c.transaction()?;
            for f in new_facts.values() {
                save_fact(&tx, f)?;
            }
            for e in new_embeddings.values() {
                save_embedding(&tx, e)?;
            }
            for r in &new_rules {
                save_rule(&tx, r)?;
            }
            for x in new_categories.values() {
                save_choice(&tx, x)?;
            }
            tx.commit()
        })
    }

    fn import_songs(
        &self,
        entries: &[Song],
        fingerprint: FingerprintReader,
        report: &mut ImportReport,
    ) -> Result<()> {
        let local = self.songs(None)?;
        let corrections: HashSet<String> = self
            .song_corrections()?
            .iter()
            .map(|c| canonical(&c.path))
            .collect();
        let mut by_size: HashMap<i64, Vec<&SongRecord>> = HashMap::new();
        for s in &local {
            by_size.entry(s.file_size).or_default().push(s);
        }
        // Read once, only for songs of a size in the file.
        let mut fingerprints: HashMap<i64, Option<String>> = HashMap::new();
        let mut analyses: Vec<(i64, SongAnalysis)> = Vec::new();
        let mut analysed_here: HashSet<i64> = HashSet::new();
        let mut new_corrections: Vec<(String, Option<SongCorrection>)> = Vec::new();
        let mut corrected_here: HashSet<String> = HashSet::new();
        let now = dates::now();
        report.songs = entries.len();
        for entry in entries {
            let same_size = by_size.get(&entry.size).map(Vec::as_slice).unwrap_or(&[]);
            let entry_path = canonical(&entry.path);
            let in_place = |s: &SongRecord| canonical(&s.path_in_library()) == entry_path;
            // The same content (or, without a fingerprint, the same place and size); the same place first.
            let mut matches: Vec<&SongRecord> = match &entry.fingerprint {
                Some(fp) => same_size
                    .iter()
                    .copied()
                    .filter(|s| {
                        let id = s.id.unwrap_or(-1);
                        fingerprints
                            .entry(id)
                            .or_insert_with(|| fingerprint(Path::new(&s.path)))
                            .as_ref()
                            == Some(fp)
                    })
                    .collect(),
                None => same_size.iter().copied().filter(|s| in_place(s)).collect(),
            };
            if matches.is_empty() {
                continue;
            }
            report.songs_matched += 1;
            matches.sort_by_key(|s| !in_place(s));
            for s in matches {
                let Some(id) = s.id else { continue };
                if let Some(a) = &entry.analysis
                    && !s.is_analysed()
                    && analysed_here.insert(id)
                {
                    analyses.push((id, song_analysis(a)));
                }
                if let Some(c) = &entry.correction {
                    let key = canonical(&s.path);
                    if !corrections.contains(&key) && corrected_here.insert(key) {
                        new_corrections.push((s.path.clone(), Some(correction(c, &s.path, &now))));
                    }
                }
            }
        }
        report.song_analyses = self.save_song_analysis(&analyses)?.len();
        self.set_song_corrections(&new_corrections)?;
        report.corrections = new_corrections.len();
        Ok(())
    }
}

fn key_of(v: &SongValues) -> Option<MusicKey> {
    v.key_pitch_class
        .map(|pc| MusicKey::new(pc as i32, v.key_minor.unwrap_or(false)))
}

fn song_analysis(v: &SongValues) -> SongAnalysis {
    SongAnalysis {
        bpm: v.bpm,
        bpm_low: v.bpm_low,
        bpm_high: v.bpm_high,
        tempo_stability: v.stability.clone(),
        beats_per_bar: v.beats_per_bar,
        key: key_of(v),
        key_confidence: v.key_confidence,
        key_second_opinion: None,
        source: v
            .source
            .clone()
            .unwrap_or_else(|| SongAnalysis::EARMARK_SOURCE.into()),
    }
}

fn correction(v: &SongValues, path: &str, at: &str) -> SongCorrection {
    let key = key_of(v);
    SongCorrection {
        path: path.into(),
        bpm: v.bpm,
        bpm_low: v.bpm_low,
        bpm_high: v.bpm_high,
        key_pitch_class: key.map(|k| k.pitch_class as i64),
        key_minor: key.map(|k| k.minor),
        beats_per_bar: v.beats_per_bar,
        corrected_at: at.into(),
    }
}
