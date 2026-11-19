//! A second opinion on each sound's category from the sounds most like it, and a category for one
//! sound: the owner's own choice, or Earmark's guess from how it sounds. Port of
//! `CategoryVotes.swift` and `SoundCategories.swift`.

use super::folder_rules::GUESS_SOURCE;
use super::sound_map;
use crate::records::SoundRecord;
use crate::ucs::UcsCatalog;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Vote {
    #[serde(rename = "catID")]
    pub cat_id: String,
    /// The share of the weighted vote, 0…1.
    pub share: f64,
}

/// Each row's top 3 categories by vote (empty if none of its nearest has one): its nearest sounds
/// in other folders vote for their categories, weighted by how alike they are. `x`: `n` unit rows
/// of `d`; `labels`: each row's category; `folders`: each row's folder (library id and path),
/// whose sounds don't vote for each other.
#[allow(clippy::too_many_arguments)]
pub fn votes(
    x: &[f32],
    n: usize,
    d: usize,
    labels: &[Option<String>],
    folders: &[String],
    voters: usize,
    candidates: usize,
    is_cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Vec<Vec<Vote>>> {
    if n <= 1 {
        return Some(vec![vec![]; n]);
    }
    let k = candidates.min(n);
    let (indices, distances) = sound_map::neighbours(x, n, d, k, &|_| {}, is_cancelled)?;
    Some(votes_from(&indices, &distances, k, labels, folders, voters))
}

/// The same from a neighbour search already made (n × k, each row's nearest first).
pub fn votes_from(
    indices: &[usize],
    distances: &[f32],
    k: usize,
    labels: &[Option<String>],
    folders: &[String],
    voters: usize,
) -> Vec<Vec<Vote>> {
    (0..labels.len())
        .map(|i| {
            let mut weights: HashMap<&str, f64> = HashMap::new();
            let (mut counted, mut total) = (0, 0.0);
            for c in 0..k {
                if counted >= voters {
                    break;
                }
                let j = indices[i * k + c];
                let Some(label) = labels[j].as_deref() else {
                    continue;
                };
                if j == i || folders[j] == folders[i] {
                    continue;
                }
                // Similarity, squared: the closest count most.
                let s = (1.0 - distances[i * k + c] as f64).max(0.0);
                *weights.entry(label).or_default() += s * s;
                total += s * s;
                counted += 1;
            }
            if total <= 0.0 {
                return vec![];
            }
            let mut sorted: Vec<(&str, f64)> = weights.into_iter().collect();
            sorted.sort_by(|a, b| {
                b.1.partial_cmp(&a.1)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then(a.0.cmp(b.0))
            });
            sorted
                .into_iter()
                .take(3)
                .map(|(c, w)| Vote {
                    cat_id: c.into(),
                    share: w / total,
                })
                .collect()
        })
        .collect()
}

/// Whether the vote says the sound is probably in the wrong category: another one has at least
/// `strong` of the vote and its own has under `weak`.
pub fn disagrees(votes: &[Vote], cat_id: Option<&str>, strong: f64, weak: f64) -> bool {
    let Some(top) = votes.first() else {
        return false;
    };
    if Some(top.cat_id.as_str()) == cat_id || top.share < strong {
        return false;
    }
    let own = votes
        .iter()
        .find(|v| Some(v.cat_id.as_str()) == cat_id)
        .map_or(0.0, |v| v.share);
    own < weak
}

pub const OWNER_SOURCE: &str = "your choice for this sound";
pub const SOUND_GUESS_SOURCE: &str = "Earmark's guess from the sound";
/// Bumped when Earmark's guesses change: they're made again.
pub const VERSION: i64 = 1;

/// A category for one sound.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SoundCategoryChoice {
    pub sound_id: i64,
    /// The file it was chosen for; a changed file loses it.
    pub fingerprint: Option<String>,
    #[serde(rename = "catID")]
    pub cat_id: String,
    pub by_owner: bool,
    /// Earmark's: its share of the vote of the sound's nearest, and the folder's guess it replaced.
    pub share: Option<f64>,
    pub replaced: Option<String>,
    pub version: i64,
    pub created_at: String,
}

/// Per-sound categories over the folder ones (after `folder_rules::apply`): the owner's replace any
/// category; Earmark's replace only a folder guess. Choices for a changed file are left out.
pub fn apply(
    choices: &HashMap<i64, SoundCategoryChoice>,
    sounds: &[SoundRecord],
    catalog: &UcsCatalog,
) -> Vec<SoundRecord> {
    if choices.is_empty() {
        return sounds.to_vec();
    }
    sounds
        .iter()
        .map(|s| {
            let Some(c) = s.id.and_then(|id| choices.get(&id)) else {
                return s.clone();
            };
            let Some(e) = catalog.entry_by_cat_id(Some(&c.cat_id)) else {
                return s.clone();
            };
            if c.fingerprint != s.fingerprint
                || !(c.by_owner || s.category_source.as_deref() == Some(GUESS_SOURCE))
            {
                return s.clone();
            }
            let mut out = s.clone();
            out.cat_id = Some(e.cat_id.clone());
            out.category = Some(e.category.clone());
            out.subcategory = Some(e.subcategory.clone());
            out.category_source = Some(
                if c.by_owner {
                    OWNER_SOURCE
                } else {
                    SOUND_GUESS_SOURCE
                }
                .into(),
            );
            out
        })
        .collect()
}

/// Earmark's guesses: for each sound whose category is its folder's guess, the category its
/// nearest sounds in other folders vote for, when that's one of the folder guess's runners-up and
/// the vote is clear (see the Swift file for how it fared on the owner's library).
pub fn guesses(
    sounds: &[SoundRecord],
    votes: &[Vec<Vote>],
    alternatives: &dyn Fn(&SoundRecord) -> HashSet<String>,
    strong: f64,
    weak: f64,
    created_at: &str,
) -> Vec<SoundCategoryChoice> {
    sounds
        .iter()
        .zip(votes)
        .filter_map(|(s, v)| {
            let id = s.id?;
            let top = v.first()?;
            if s.category_source.as_deref() != Some(GUESS_SOURCE)
                || !disagrees(v, s.cat_id.as_deref(), strong, weak)
                || !alternatives(s).contains(&top.cat_id)
            {
                return None;
            }
            Some(SoundCategoryChoice {
                sound_id: id,
                fingerprint: s.fingerprint.clone(),
                cat_id: top.cat_id.clone(),
                by_owner: false,
                share: Some(top.share),
                replaced: s.cat_id.clone(),
                version: VERSION,
                created_at: created_at.into(),
            })
        })
        .collect()
}
