//! The rows, as the Swift records (`Library`, `SoundRecord`, `SongRecord`, `SoundFacts`,
//! `SoundEmbedding`). Dates are kept as the text GRDB stores, so they round-trip exactly.

use earmark_core::music_key::MusicKey;
use earmark_core::phase0::SongAnalysis;
use earmark_core::scan::ScannedSound;
use earmark_core::{normalize::MetadataField, paths};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    pub id: i64,
    /// "sounds" or "music".
    pub kind: String,
    pub path: String,
    pub bookmark: Option<Vec<u8>>,
    pub added_at: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SoundRecord {
    pub id: Option<i64>,
    pub library_id: i64,
    pub path: String,
    pub file_name: String,
    /// The folder inside the library, e.g. "TSK-03/Footsteps/Gravel".
    pub folder: String,
    pub file_size: i64,
    pub modified_at: String,
    pub fingerprint: Option<String>,
    pub duration: Option<f64>,
    pub sample_rate: Option<f64>,
    pub channels: Option<i64>,
    pub bits_per_sample: Option<i64>,
    pub fx_name: Option<String>,
    pub details: Option<String>,
    pub keywords: Option<String>,
    pub vendor_library: Option<String>,
    pub manufacturer: Option<String>,
    pub designer: Option<String>,
    #[serde(rename = "catID")]
    pub cat_id: Option<String>,
    pub category: Option<String>,
    pub subcategory: Option<String>,
    pub category_source: Option<String>,
}

impl SoundRecord {
    pub fn from_scan(library_id: i64, root: &str, s: &ScannedSound) -> SoundRecord {
        let m = &s.metadata;
        let field = |f: MetadataField| m.get(f).map(str::to_string);
        SoundRecord {
            id: None,
            library_id,
            path: s.path.clone(),
            file_name: paths::file_name(&s.path),
            folder: paths::relative_folder(&s.path, root),
            file_size: s.file_size,
            modified_at: crate::dates::format(s.modified),
            fingerprint: s.fingerprint.clone(),
            duration: s.technical.duration,
            sample_rate: s.technical.sample_rate,
            channels: s.technical.channels,
            bits_per_sample: s.technical.bits_per_sample,
            fx_name: field(MetadataField::FxName),
            details: field(MetadataField::Description),
            keywords: field(MetadataField::Keywords),
            vendor_library: field(MetadataField::Library),
            manufacturer: field(MetadataField::Manufacturer),
            designer: field(MetadataField::Designer),
            cat_id: m.ucs.as_ref().map(|u| u.cat_id.clone()),
            category: m.ucs.as_ref().map(|u| u.category.clone()),
            subcategory: m.ucs.as_ref().map(|u| u.subcategory.clone()),
            category_source: m.ucs.as_ref().map(|u| u.source.clone()),
        }
    }
}

/// A song file with its tags, read by the app.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SongFile {
    pub path: String,
    pub file_size: i64,
    /// Seconds since 1970.
    pub modified: f64,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SongRecord {
    pub id: Option<i64>,
    pub library_id: i64,
    pub path: String,
    pub file_name: String,
    pub folder: String,
    pub file_size: i64,
    pub modified_at: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration: Option<f64>,
    pub bpm: Option<f64>,
    pub bpm_low: Option<f64>,
    pub bpm_high: Option<f64>,
    pub tempo_stability: Option<String>,
    pub beats_per_bar: Option<i64>,
    pub key_pitch_class: Option<i64>,
    pub key_minor: Option<bool>,
    pub key_confidence: Option<f64>,
    pub analysis_source: Option<String>,
}

impl SongRecord {
    pub fn key(&self) -> Option<MusicKey> {
        self.key_pitch_class
            .map(|pc| MusicKey::new(pc as i32, self.key_minor.unwrap_or(false)))
    }

    pub(crate) fn apply(&mut self, a: &SongAnalysis) {
        self.bpm = a.bpm;
        self.bpm_low = a.bpm_low;
        self.bpm_high = a.bpm_high;
        self.tempo_stability = a.tempo_stability.clone();
        self.beats_per_bar = a.beats_per_bar;
        self.key_pitch_class = a.key.map(|k| k.pitch_class as i64);
        self.key_minor = a.key.map(|k| k.minor);
        self.key_confidence = a.key_confidence;
        self.analysis_source = Some(a.source.clone());
    }
}

/// Analysis stage 1 for one sound: measured from the decoded audio.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SoundFacts {
    pub sound_id: i64,
    pub fingerprint: Option<String>,
    pub version: i64,
    /// Integrated loudness, LUFS.
    pub loudness: Option<f64>,
    /// Sample peak, dBFS.
    pub peak: Option<f64>,
    pub error: Option<String>,
    pub analyzed_at: String,
}

impl SoundFacts {
    /// Bump when the measurement changes, so every sound is measured again.
    pub const CURRENT_VERSION: i64 = 1;
}

/// Analysis stage 2 for one sound: its embedding from one model (float32, little-endian).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SoundEmbedding {
    pub sound_id: i64,
    pub model: String,
    pub fingerprint: Option<String>,
    pub version: i64,
    pub vector: Option<Vec<u8>>,
    pub error: Option<String>,
    pub analyzed_at: String,
}

impl SoundEmbedding {
    /// A model's pipeline version: bumped when it changes, so every sound is embedded again.
    pub fn version_of(model: &str) -> i64 {
        match model {
            "clap-general" | "pe-av-large" => 1,
            _ => 1,
        }
    }

    pub fn floats(bytes: &[u8]) -> Vec<f32> {
        bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect()
    }

    pub fn bytes(values: &[f32]) -> Vec<u8> {
        values.iter().flat_map(|v| v.to_le_bytes()).collect()
    }
}

/// What's stored for a sound and model, without the vector.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EmbeddingStatus {
    pub fingerprint: Option<String>,
    pub version: i64,
}
