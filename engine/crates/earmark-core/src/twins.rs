//! Packs often ship the same sounds twice, e.g. "Pack - WAV/Hits/01 Hit.wav" and
//! "Pack - MP3/Hits/01 Hit.mp3". Twins are files in the same library with the same name apart
//! from the extension, in folders that only differ by format words, and with lengths within
//! half a second. The list shows the best copy. Port of `FormatTwins.swift`.

use crate::scan::extension;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;

/// What grouping needs to know about a sound (fields of the database's sound record).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TwinCandidate {
    pub id: i64,
    pub library_id: i64,
    pub file_name: String,
    /// Folder inside the library.
    pub folder: String,
    pub path: String,
    pub duration: Option<f64>,
    pub sample_rate: Option<f64>,
    pub bits_per_sample: Option<i64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Groups {
    /// Shown sound id → its other copies, best first.
    pub alternates: BTreeMap<i64, Vec<i64>>,
    /// Ids hidden from the list because a better copy is shown.
    pub hidden: BTreeSet<i64>,
}

/// Lower is better: lossless first, then lossy.
fn rank(ext: &str) -> i32 {
    match ext {
        "wav" | "wave" | "bwf" | "rf64" | "w64" => 0,
        "aif" | "aiff" | "aifc" | "caf" => 1,
        "flac" | "alac" => 2,
        "m4a" | "mp4" | "aac" => 3,
        "ogg" | "oga" | "opus" => 4,
        "mp3" => 5,
        _ => 9,
    }
}

fn is_format_word(w: &str) -> bool {
    rank(w) != 9 || matches!(w, "lossless" | "lossy" | "hq" | "hd")
}

fn ext(s: &TwinCandidate) -> String {
    extension(Path::new(&s.file_name))
}

fn stem(file_name: &str) -> String {
    Path::new(file_name)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn same_length(a: &TwinCandidate, b: &TwinCandidate) -> bool {
    match (a.duration, b.duration) {
        (Some(x), Some(y)) => (x - y).abs() <= 0.5,
        _ => true,
    }
}

/// The folder with format words ("MP3", "WAV", "(MP3,WAV)") blanked out, lowercased.
pub fn normalized_folder(folder: &str) -> String {
    folder
        .to_lowercase()
        .split('/')
        .map(|part| {
            // Words of letters and digits, as Swift's characters.
            let mut words: Vec<String> = Vec::new();
            let mut word = String::new();
            for c in crate::text::characters(part) {
                if crate::text::is_letter(c) || crate::text::is_number(c) {
                    word.push_str(c);
                } else if !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
            }
            if !word.is_empty() {
                words.push(word);
            }
            words
                .into_iter()
                .filter(|w| !is_format_word(w))
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect::<Vec<_>>()
        .join("/")
}

pub fn group(sounds: &[TwinCandidate]) -> Groups {
    let mut buckets: HashMap<String, Vec<&TwinCandidate>> = HashMap::new();
    for s in sounds {
        let key = format!(
            "{}|{}|{}",
            s.library_id,
            normalized_folder(&s.folder),
            stem(&s.file_name).to_lowercase()
        );
        buckets.entry(key).or_default().push(s);
    }
    let mut out = Groups::default();
    for mut bucket in buckets.into_values().filter(|b| b.len() > 1) {
        bucket.sort_by(|a, b| {
            (rank(&ext(a)), -a.bits_per_sample.unwrap_or(0))
                .cmp(&(rank(&ext(b)), -b.bits_per_sample.unwrap_or(0)))
                .then((-a.sample_rate.unwrap_or(0.0)).total_cmp(&-b.sample_rate.unwrap_or(0.0)))
                .then(a.path.cmp(&b.path))
        });
        let mut pending: Vec<&TwinCandidate> = bucket;
        while !pending.is_empty() {
            let best = pending.remove(0);
            // The same name and folder but a clearly different length is a different sound.
            let twins: Vec<i64> = pending
                .iter()
                .filter(|s| same_length(best, s) && ext(best) != ext(s))
                .map(|s| s.id)
                .collect();
            if twins.is_empty() {
                continue;
            }
            out.hidden.extend(&twins);
            pending.retain(|s| !twins.contains(&s.id));
            out.alternates.insert(best.id, twins);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sound(id: i64, path: &str, duration: f64) -> TwinCandidate {
        let (folder, name) = path.rsplit_once('/').unwrap();
        TwinCandidate {
            id,
            library_id: 1,
            file_name: name.into(),
            folder: folder.into(),
            path: format!("/lib/{path}"),
            duration: Some(duration),
            sample_rate: Some(48000.0),
            bits_per_sample: if name.ends_with(".mp3") {
                None
            } else {
                Some(16)
            },
        }
    }

    #[test]
    fn the_best_copy_is_shown() {
        let sounds = [
            sound(1, "Pack (MP3,WAV)/Pack - WAV/Hits/01 Hit.wav", 1.0),
            sound(2, "Pack (MP3,WAV)/Pack - MP3/Hits/01 Hit.mp3", 1.03),
            sound(3, "Other/Long.wav", 1.0),
            sound(4, "Other/long.aif", 3.0),
            sound(5, "Elsewhere/01 Hit.mp3", 1.0),
        ];
        let g = group(&sounds);
        assert_eq!(g.hidden, BTreeSet::from([2]));
        assert_eq!(g.alternates, BTreeMap::from([(1, vec![2])]));
        assert_eq!(
            normalized_folder("Pack (MP3,WAV)/Pack - WAV/Hits"),
            "pack/pack/hits"
        );
    }
}
