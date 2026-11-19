//! The sound libraries as Earmark shows them, read in one go: each sound with its category by
//! Earmark's rules, format twins hidden, similarity groups and duplicates. What the MCP server
//! answers from. Port of `SoundCatalog.swift`.

use crate::groups::{GroupRecord, GroupSnapshot};
use crate::{EmbeddingStatus, Library, LibraryDatabase, Result, SoundFacts, SoundRecord};
use earmark_core::analysis::{categories, duplicates, folder_rules};
use earmark_core::paths::canonical;
use earmark_core::text::{StandardKey, trim_spaces};
use earmark_core::twins::{self, TwinCandidate};
use earmark_core::ucs::UcsCatalog;
use std::collections::{HashMap, HashSet};

pub struct SoundCatalog {
    pub libraries: Vec<Library>,
    /// Every sound, categories applied, hidden twins too (`is_shown`).
    pub sounds: Vec<SoundRecord>,
    pub song_count: usize,
    pub twins: twins::Groups,
    pub groups: GroupSnapshot,
    pub duplicates: duplicates::Sets,
    pub facts: HashMap<i64, SoundFacts>,
    /// Sounds with both models' embeddings (on the map, in groups, in duplicates by sound).
    pub analysed: HashSet<i64>,
    group_by_id: HashMap<i64, GroupRecord>,
    position: HashMap<i64, usize>,
    haystacks: Vec<String>,
    names: Vec<String>,
    order: Vec<StandardKey>,
}

/// What to find.
#[derive(Clone, Debug, Default)]
pub struct Filter {
    /// Words the sound's name, description, keywords, category, library or folder all contain.
    pub query: Option<String>,
    /// A category ("FOOTSTEPS"), a subcategory ("Footsteps / Human") or a CatID ("FEETHmn").
    pub category: Option<String>,
    pub group_id: Option<i64>,
    pub library_id: Option<i64>,
    pub min_length: Option<f64>,
    pub max_length: Option<f64>,
    /// "file", "folder", "guess" (Earmark's, from the folder or the sound), "owner", "none".
    pub source: Option<String>,
}

/// Lowercased, so that composed and decomposed accents match as they do in Swift.
fn folded(s: &str) -> String {
    canonical(&s.to_lowercase())
}

impl SoundCatalog {
    pub fn new(db: &LibraryDatabase) -> Result<SoundCatalog> {
        let catalog = UcsCatalog::shared();
        let libraries = db.libraries(None)?;
        let rules = db.folder_rules()?;
        let guesses = db.folder_guesses()?;
        let choices = db.sound_category_choices()?;
        let sounds = categories::apply(
            &choices,
            &folder_rules::apply(&rules, &guesses, &db.sounds(None)?, catalog),
            catalog,
        );
        let song_count = db.songs(None)?.len();
        let candidates: Vec<TwinCandidate> = sounds
            .iter()
            .filter_map(|s| {
                Some(TwinCandidate {
                    id: s.id?,
                    library_id: s.library_id,
                    file_name: s.file_name.clone(),
                    folder: s.folder.clone(),
                    path: s.path.clone(),
                    duration: s.duration,
                    sample_rate: s.sample_rate,
                    bits_per_sample: s.bits_per_sample,
                })
            })
            .collect();
        let twins = twins::group(&candidates);
        let groups = db.group_snapshot()?;
        let group_by_id = groups
            .groups
            .values()
            .flatten()
            .map(|g| (g.id, g.clone()))
            .collect();
        let hidden: HashSet<i64> = twins.hidden.iter().copied().collect();
        let prints: Vec<(i64, Option<String>)> = sounds
            .iter()
            .filter_map(|s| Some((s.id?, s.fingerprint.clone())))
            .collect();
        let mut pairs = duplicates::identical_pairs(&prints, &hidden);
        pairs.extend(db.near_duplicates()?);
        let duplicates = duplicates::sets(&pairs);
        let facts = db.sound_facts()?;
        let position = sounds
            .iter()
            .enumerate()
            .filter_map(|(i, s)| Some((s.id?, i)))
            .collect();
        let haystacks = sounds.iter().map(|s| canonical(&s.search_text())).collect();
        let shown_names: Vec<String> = sounds.iter().map(SoundRecord::display_name).collect();
        let names = shown_names.iter().map(|n| folded(n)).collect();
        let order = shown_names.iter().map(|n| StandardKey::new(n)).collect();
        let clap = db.embedding_status("clap-general")?;
        let peav = db.embedding_status("pe-av-large")?;
        let analysed = sounds
            .iter()
            .filter_map(|s| {
                let id = s.id?;
                (EmbeddingStatus::is_current(clap.get(&id), "clap-general", s)
                    && EmbeddingStatus::is_current(peav.get(&id), "pe-av-large", s))
                .then_some(id)
            })
            .collect();
        Ok(SoundCatalog {
            libraries,
            sounds,
            song_count,
            twins,
            groups,
            duplicates,
            facts,
            analysed,
            group_by_id,
            position,
            haystacks,
            names,
            order,
        })
    }

    pub fn sound(&self, id: i64) -> Option<&SoundRecord> {
        self.position.get(&id).map(|&i| &self.sounds[i])
    }

    /// Listed (not a hidden format twin).
    pub fn is_shown(&self, s: &SoundRecord) -> bool {
        s.id.is_some_and(|id| !self.twins.hidden.contains(&id))
    }

    /// The sound's similarity group, if its file is the one grouped.
    pub fn group_of(&self, s: &SoundRecord) -> Option<&GroupRecord> {
        let id = s.id?;
        let plan = &self.groups.plan;
        let group = plan.membership.get(&id)?;
        if plan.member_fingerprints.get(&id) != Some(&s.fingerprint) {
            return None;
        }
        self.group_by_id.get(group)
    }

    pub fn library(&self, id: i64) -> Option<&Library> {
        self.libraries.iter().find(|l| l.id == id)
    }

    /// Where a sound's category came from, in words agents and people read.
    pub fn source_text(s: &SoundRecord) -> String {
        match s.category_source.as_deref() {
            None if s.cat_id.is_none() => "none yet".into(),
            None => "its file".into(),
            Some(folder_rules::SOURCE) => "the owner's choice for its folder".into(),
            Some(folder_rules::GUESS_SOURCE) => "Earmark's guess for its folder".into(),
            Some(categories::SOUND_GUESS_SOURCE) => "Earmark's guess from how it sounds".into(),
            Some(categories::OWNER_SOURCE) => "the owner's choice for this sound".into(),
            Some(other) => format!("its file ({other})"),
        }
    }

    /// Listed sounds matching the filter: with a query, those with the words in their name first.
    pub fn search(&self, f: &Filter) -> Vec<&SoundRecord> {
        let query = folded(f.query.as_deref().unwrap_or(""));
        let terms: Vec<&str> = query.split_whitespace().collect();
        let category = f.category.as_deref().map(|c| trim_spaces(c).to_lowercase());
        let mut found: Vec<(usize, usize)> = Vec::new();
        for (i, s) in self.sounds.iter().enumerate() {
            if !self.is_shown(s) || !terms.iter().all(|t| self.haystacks[i].contains(t)) {
                continue;
            }
            if let Some(category) = category.as_deref().filter(|c| !c.is_empty()) {
                let label = s.ucs_label();
                let labels = [s.cat_id.as_deref(), s.category.as_deref(), label.as_deref()];
                if !labels
                    .into_iter()
                    .flatten()
                    .any(|l| l.to_lowercase() == category)
                {
                    continue;
                }
            }
            if f.group_id.is_some() && self.group_of(s).map(|g| g.id) != f.group_id {
                continue;
            }
            if f.library_id.is_some_and(|l| s.library_id != l) {
                continue;
            }
            if f.min_length
                .is_some_and(|lo| s.duration.unwrap_or(0.0) < lo)
            {
                continue;
            }
            if f.max_length
                .is_some_and(|hi| s.duration.unwrap_or(f64::INFINITY) > hi)
            {
                continue;
            }
            if f.source
                .as_deref()
                .is_some_and(|src| !matches_source(s, src))
            {
                continue;
            }
            let in_name = terms.iter().filter(|t| self.names[i].contains(**t)).count();
            found.push((i, in_name));
        }
        found.sort_by(|a, b| {
            b.1.cmp(&a.1)
                .then_with(|| self.order[a.0].cmp(&self.order[b.0]))
        });
        found.into_iter().map(|(i, _)| &self.sounds[i]).collect()
    }
}

fn matches_source(s: &SoundRecord, source: &str) -> bool {
    let from = s.category_source.as_deref();
    let folder = from == Some(folder_rules::SOURCE);
    let folder_guess = from == Some(folder_rules::GUESS_SOURCE);
    let sound_guess = from == Some(categories::SOUND_GUESS_SOURCE);
    let owner = from == Some(categories::OWNER_SOURCE);
    match source.to_lowercase().as_str() {
        "file" => s.cat_id.is_some() && !folder && !folder_guess && !sound_guess && !owner,
        "folder" => folder,
        "guess" => folder_guess || sound_guess,
        "owner" => owner || folder,
        "none" => s.cat_id.is_none(),
        _ => true,
    }
}
