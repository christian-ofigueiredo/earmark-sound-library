//! What Earmark worked out for one library or music folder, in a file, to take it to another
//! machine without analysing again (docs/analysis-file-format.md). Items are matched by content,
//! not by path, and an import only fills gaps. Written outside the libraries only. Port of
//! `AnalysisFiles.swift`; the export and import themselves are in earmark-db.

use crate::records::{Library, SongRecord};
use crate::song_corrections::SongCorrection;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub const FORMAT_NAME: &str = "earmark-analysis";
pub const CURRENT_VERSION: i64 = 1;
pub const FILE_EXTENSION: &str = "earmark-analysis.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisFile {
    pub format: String,
    pub version: i64,
    /// ISO 8601, kept as written.
    pub exported_at: String,
    pub library: LibraryInfo,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sounds: Option<Vec<Sound>>,
    /// The owner's categories for folders of sounds without one of their own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder_categories: Option<Vec<FolderCategory>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub songs: Option<Vec<Song>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LibraryKind {
    Sounds,
    Music,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LibraryInfo {
    pub kind: LibraryKind,
    pub name: String,
    /// Where it was on the machine it came from (for people; matching doesn't use it).
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Sound {
    /// Inside the library.
    pub path: String,
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub facts: Option<Facts>,
    /// By model ("clap-general", "pe-av-large").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embeddings: Option<BTreeMap<String, Embedding>>,
    /// The owner's category for this sound (a UCS CatID), chosen one by one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Facts {
    pub version: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loudness: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peak: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Embedding {
    pub version: i64,
    /// float32, little-endian, base64 in the file; none for a silent sound.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_bytes"
    )]
    pub vector: Option<Vec<u8>>,
}

mod base64_bytes {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(v: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            Some(b) => s.serialize_str(&STANDARD.encode(b)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
        // Owned: Swift's JSON writes "/" as "\/", so the text can't always be borrowed.
        Option::<String>::deserialize(d)?
            .map(|t| STANDARD.decode(t).map_err(serde::de::Error::custom))
            .transpose()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FolderCategory {
    /// Inside the library.
    pub folder: String,
    #[serde(rename = "catID")]
    pub cat_id: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Song {
    /// Inside the music folder.
    pub path: String,
    pub size: i64,
    /// None when the file couldn't be read at export (it's then matched by path and size).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fingerprint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analysis: Option<SongValues>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub correction: Option<SongValues>,
}

/// Tempo and key: what was analysed (with `source`), or what the owner set by hand.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SongValues {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bpm: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bpm_low: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bpm_high: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stability: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub beats_per_bar: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_pitch_class: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_minor: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_confidence: Option<f64>,
    /// "Phase 0" or "Earmark".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

impl SongValues {
    pub fn from_song(s: &SongRecord) -> SongValues {
        SongValues {
            bpm: s.bpm,
            bpm_low: s.bpm_low,
            bpm_high: s.bpm_high,
            stability: s.tempo_stability.clone(),
            beats_per_bar: s.beats_per_bar,
            key_pitch_class: s.key_pitch_class,
            key_minor: s.key_minor,
            key_confidence: s.key_confidence,
            source: s.analysis_source.clone(),
        }
    }

    pub fn from_correction(c: &SongCorrection) -> SongValues {
        SongValues {
            bpm: c.bpm,
            bpm_low: c.bpm_low,
            bpm_high: c.bpm_high,
            beats_per_bar: c.beats_per_bar,
            key_pitch_class: c.key_pitch_class,
            key_minor: c.key_minor,
            ..SongValues::default()
        }
    }
}

#[derive(Debug)]
pub enum ReadError {
    NotAnalysisFile,
    NewerVersion(i64),
    BadDate(String),
    Json(serde_json::Error),
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReadError::NotAnalysisFile => f.write_str("This isn't an Earmark analysis file."),
            ReadError::NewerVersion(v) => {
                write!(
                    f,
                    "This analysis file is from a newer Earmark (format {v}). Update Earmark to import it."
                )
            }
            ReadError::BadDate(d) => write!(f, "“{d}” isn't a date in ISO 8601."),
            ReadError::Json(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for ReadError {}

/// The format a JSON file says it's in ("earmark-analysis", "soundlab-music-analysis"), if any.
pub fn format_of(data: &[u8]) -> Option<String> {
    #[derive(Deserialize)]
    struct Peek {
        format: Option<String>,
    }
    serde_json::from_slice::<Peek>(data).ok()?.format
}

impl AnalysisFile {
    pub fn new(exported_at: &str, library: &Library) -> AnalysisFile {
        AnalysisFile {
            format: FORMAT_NAME.into(),
            version: CURRENT_VERSION,
            exported_at: exported_at.into(),
            library: LibraryInfo {
                kind: if library.kind == "music" {
                    LibraryKind::Music
                } else {
                    LibraryKind::Sounds
                },
                name: library.name(),
                path: library.path.clone(),
            },
            sounds: None,
            folder_categories: None,
            songs: None,
        }
    }

    pub fn read(data: &[u8]) -> Result<AnalysisFile, ReadError> {
        if format_of(data).as_deref() != Some(FORMAT_NAME) {
            return Err(ReadError::NotAnalysisFile);
        }
        let file: AnalysisFile = serde_json::from_slice(data).map_err(ReadError::Json)?;
        static DATE: OnceLock<Regex> = OnceLock::new();
        let date = DATE.get_or_init(|| {
            Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:?\d{2})$").unwrap()
        });
        if !date.is_match(&file.exported_at) {
            return Err(ReadError::BadDate(file.exported_at));
        }
        if file.version > CURRENT_VERSION {
            return Err(ReadError::NewerVersion(file.version));
        }
        Ok(file)
    }

    pub fn encoded(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(self)
    }
}

/// "SoundFX.earmark-analysis.json".
pub fn file_name(library: &Library) -> String {
    format!("{}.{FILE_EXTENSION}", library.name())
}

/// The path with symbolic links resolved as far as it exists, "/" between folders. On Windows
/// names compare without case, as its file systems do.
fn resolved(path: &Path) -> String {
    let (mut existing, mut rest): (PathBuf, Vec<std::ffi::OsString>) =
        (path.to_path_buf(), Vec::new());
    let found = loop {
        if let Ok(p) = std::fs::canonicalize(&existing) {
            break p;
        }
        let Some(name) = existing.file_name().map(|n| n.to_os_string()) else {
            break existing;
        };
        rest.push(name);
        existing.pop();
    };
    let full = rest.iter().rev().fold(found, |p, n| p.join(n));
    let text = crate::paths::standardized(&full.to_string_lossy());
    if cfg!(windows) {
        text.to_lowercase()
    } else {
        text
    }
}

/// The library `path` is inside, if any: analysis and timeline files are never written there.
pub fn library_containing<'a>(path: &Path, libraries: &'a [Library]) -> Option<&'a Library> {
    let target = resolved(path);
    libraries.iter().find(|lib| {
        let root = resolved(Path::new(&lib.path));
        target == root
            || target.starts_with(&if root.ends_with('/') {
                root.clone()
            } else {
                format!("{root}/")
            })
    })
}

/// What an import found and added.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportReport {
    pub sounds: usize,
    pub sounds_matched: usize,
    pub facts: usize,
    pub embeddings: usize,
    pub folder_categories: usize,
    pub sound_categories: usize,
    pub songs: usize,
    pub songs_matched: usize,
    pub song_analyses: usize,
    pub corrections: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_only_analysis_files_and_refuses_library_folders() {
        assert!(matches!(
            AnalysisFile::read(br#"{"format": "soundlab-music-analysis", "tracks": []}"#),
            Err(ReadError::NotAnalysisFile)
        ));
        let newer = br#"{"format": "earmark-analysis", "version": 2, "exportedAt": "2026-10-26T00:00:00Z", "library": {"kind": "music", "name": "x", "path": "/x"}}"#;
        assert!(matches!(
            AnalysisFile::read(newer),
            Err(ReadError::NewerVersion(2))
        ));
        assert_eq!(
            format_of(br#"{"format": "soundlab-music-analysis"}"#).as_deref(),
            Some("soundlab-music-analysis")
        );
        let lib = Library {
            id: 1,
            kind: "sounds".into(),
            path: "/Volumes/Banana 01/SoundFX".into(),
            bookmark: None,
            added_at: String::new(),
        };
        let libs = [lib.clone()];
        assert!(
            library_containing(Path::new("/Volumes/Banana 01/SoundFX/Exports"), &libs).is_some()
        );
        assert!(library_containing(Path::new("/Volumes/Banana 01/SoundFX"), &libs).is_some());
        assert!(
            library_containing(Path::new("/Volumes/Banana 01/SoundFX Exports"), &libs).is_none()
        );
        assert_eq!(file_name(&lib), "SoundFX.earmark-analysis.json");
    }

    #[test]
    fn a_silent_sounds_vector_stays_out() {
        let s = Embedding {
            version: 1,
            vector: None,
        };
        assert_eq!(serde_json::to_string(&s).unwrap(), r#"{"version":1}"#);
        let v: Embedding = serde_json::from_str(r#"{"version":1,"vector":null}"#).unwrap();
        assert_eq!(v, s);
        let bytes: Embedding =
            serde_json::from_str(r#"{"version":1,"vector":"AAAAPw=="}"#).unwrap();
        assert_eq!(bytes.vector, Some(0.5f32.to_le_bytes().to_vec()));
        // Swift's JSON escapes "/".
        let escaped: Embedding = serde_json::from_str(r#"{"version":1,"vector":"A\/8="}"#).unwrap();
        assert_eq!(escaped.vector, Some(vec![3, 255]));
    }
}
