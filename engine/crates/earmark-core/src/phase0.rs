//! Song analysis results, and reading the `music_analysis.json` Phase 0's analyze_music.py
//! wrote, so songs analysed there aren't analysed again. Port of `Phase0Import.swift`.

use crate::music_key::MusicKey;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Tempo and key results for one song, as Earmark stores them.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SongAnalysis {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bpm: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bpm_low: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bpm_high: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tempo_stability: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub beats_per_bar: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<MusicKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_confidence: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_second_opinion: Option<MusicKey>,
    pub source: String,
}

impl SongAnalysis {
    pub const EARMARK_SOURCE: &str = "Earmark";

    /// None for an impossible tempo (outside 20–400 BPM).
    pub fn plausible_bpm(bpm: Option<f64>) -> Option<f64> {
        bpm.filter(|b| (20.0..=400.0).contains(b))
    }

    /// None for anything but 2, 3, 4 or 6 beats per bar.
    pub fn plausible_beats_per_bar(beats: Option<i64>) -> Option<i64> {
        beats.filter(|b| [2, 3, 4, 6].contains(b))
    }
}

#[derive(Deserialize)]
struct File {
    format: Option<String>,
    tracks: Vec<Track>,
}

#[derive(Deserialize)]
struct Track {
    file: Option<String>,
    path: Option<String>,
    size: Option<i64>,
    bpm: Option<f64>,
    bpm_range: Option<Vec<f64>>,
    tempo_stability: Option<String>,
    beats_per_bar: Option<i64>,
    key_pc: Option<i32>,
    key_minor: Option<bool>,
    key_confidence: Option<f64>,
    key_second_opinion: Option<String>,
    title: Option<String>,
    artist: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub path: Option<String>,
    pub file_name: String,
    pub size: Option<i64>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub analysis: SongAnalysis,
}

#[derive(Debug)]
pub enum ImportError {
    NotPhase0Music,
    Json(serde_json::Error),
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImportError::NotPhase0Music => {
                f.write_str("This isn't a music_analysis.json file from Phase 0.")
            }
            ImportError::Json(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for ImportError {}

pub fn read(data: &[u8]) -> Result<Vec<Entry>, ImportError> {
    let file: File = serde_json::from_slice(data).map_err(ImportError::Json)?;
    if file
        .format
        .as_deref()
        .is_some_and(|f| f != "soundlab-music-analysis")
    {
        return Err(ImportError::NotPhase0Music);
    }
    Ok(file
        .tracks
        .into_iter()
        .map(|t| {
            let analysis = SongAnalysis {
                bpm: SongAnalysis::plausible_bpm(t.bpm),
                bpm_low: t.bpm_range.as_ref().and_then(|r| r.first().copied()),
                bpm_high: t.bpm_range.as_ref().and_then(|r| r.last().copied()),
                tempo_stability: t.tempo_stability,
                beats_per_bar: SongAnalysis::plausible_beats_per_bar(t.beats_per_bar),
                key: t
                    .key_pc
                    .map(|pc| MusicKey::new(pc, t.key_minor.unwrap_or(false))),
                key_confidence: t.key_confidence,
                key_second_opinion: t.key_second_opinion.as_deref().and_then(MusicKey::parse),
                source: "Phase 0".into(),
            };
            let file_name = t
                .path
                .as_ref()
                .or(t.file.as_ref())
                .and_then(|p| Path::new(p).file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            Entry {
                path: t.path,
                file_name,
                size: t.size,
                title: t.title,
                artist: t.artist,
                analysis,
            }
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::read;

    #[test]
    fn imports_and_drops_impossible_readings() {
        let json = br#"{"format": "soundlab-music-analysis", "version": 1, "tracks": [
          {"file": "01 Loser.mp3", "path": "/Volumes/Old/Liked/01 Loser.mp3", "size": 1000, "bpm": 83.0,
           "bpm_range": [82.9, 83.1], "tempo_stability": "steady", "beats_per_bar": 4, "key_pc": 5, "key_minor": true,
           "key_confidence": 0.84, "key_second_opinion": "F minor"},
          {"file": "sub/02 Dragonborn.mp3", "size": 2000, "bpm": 2.63,
           "beats_per_bar": 1, "key_pc": 11, "key_minor": true, "key_confidence": 0.51}
        ]}"#;
        let e = read(json).unwrap();
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].file_name, "01 Loser.mp3");
        assert_eq!(e[0].analysis.key.unwrap().camelot(), "4A");
        assert_eq!(e[0].analysis.key_second_opinion.unwrap().name(), "F minor");
        assert_eq!(
            (e[0].analysis.bpm_low, e[0].analysis.bpm_high),
            (Some(82.9), Some(83.1))
        );
        assert_eq!(e[1].file_name, "02 Dragonborn.mp3");
        assert_eq!(e[1].analysis.bpm, None);
        assert_eq!(e[1].analysis.beats_per_bar, None);
        assert!(read(br#"{"format": "something-else", "tracks": []}"#).is_err());
        assert!(read(b"[]").is_err());
    }
}
