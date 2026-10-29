//! Listing a library's audio files, fingerprints, and reading each file's header. Port of
//! `LibraryScanner.swift`. Only reads: nothing is written next to the files.

use crate::bytes::ReadOnlyFile;
use crate::metadata::{self, AudioTechnical};
use crate::normalize::{NormalizedMetadata, normalize};
use crate::ucs::UcsCatalog;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::UNIX_EPOCH;

pub const EXTENSIONS: &[&str] = &[
    "wav", "wave", "bwf", "rf64", "w64", "aif", "aiff", "aifc", "flac", "ogg", "oga", "opus",
    "mp3", "m4a", "aac", "alac", "caf", "mp4",
];

/// The file's extension, lowercased, as `URL.pathExtension` gives it ("" for none, and for
/// names that only start with a dot).
pub fn extension(path: &Path) -> String {
    path.extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

/// Hidden as Finder hides it: a name starting with a dot, or (on macOS) the hidden flag.
fn is_hidden(path: &Path, meta: &std::fs::Metadata) -> bool {
    if path
        .file_name()
        .is_some_and(|n| n.to_string_lossy().starts_with('.'))
    {
        return true;
    }
    #[cfg(target_os = "macos")]
    {
        use std::os::macos::fs::MetadataExt;
        const UF_HIDDEN: u32 = 0x8000;
        if meta.st_flags() & UF_HIDDEN != 0 {
            return true;
        }
    }
    let _ = meta;
    false
}

/// Every audio file under `root`, skipping hidden files and folders (and so macOS's "._name"
/// files) and package contents, without following symbolic links. Sorted by path.
pub fn list_audio_files(root: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            if is_hidden(&path, &meta) {
                continue;
            }
            if meta.is_dir() {
                if !is_package(&path) {
                    walk(&path, out);
                }
            } else if meta.is_file() && EXTENSIONS.contains(&extension(&path).as_str()) {
                out.push(path);
            }
        }
    }
    let mut out = Vec::new();
    walk(root, &mut out);
    out.sort_by(|a, b| a.as_os_str().cmp(b.as_os_str()));
    out
}

/// Folders macOS shows as one file (FileManager's `.skipsPackageDescendants`).
fn is_package(path: &Path) -> bool {
    cfg!(target_os = "macos")
        && [
            "app",
            "bundle",
            "framework",
            "plugin",
            "kext",
            "component",
            "vst",
            "vst3",
            "aaxplugin",
            "logicx",
            "band",
            "rtfd",
            "pages",
            "numbers",
            "key",
            "photoslibrary",
            "fcpbundle",
            "dspreset",
        ]
        .contains(&extension(path).as_str())
}

/// Identity of a file's content, so renamed or moved files keep their data: its size and an
/// FNV-1a (64-bit) hash of its first and last 64 KB.
pub fn fingerprint(path: &Path) -> Option<String> {
    let mut file = ReadOnlyFile::open(path).ok()?;
    const CHUNK: u64 = 65_536;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut mix = |d: &[u8]| {
        for &b in d {
            hash = (hash ^ b as u64).wrapping_mul(0x100_0000_01b3);
        }
    };
    mix(&file.read(0, CHUNK as usize));
    if file.size > CHUNK {
        mix(&file.read(CHUNK.max(file.size - CHUNK), CHUNK as usize));
    }
    Some(format!("{:x}-{:016x}", file.size, hash))
}

/// A sound effect file as found on disk (never changed).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScannedSound {
    pub path: String,
    pub file_size: i64,
    /// Last modified, in seconds since 1970 (0 when unknown).
    pub modified: f64,
    pub fingerprint: Option<String>,
    pub technical: AudioTechnical,
    pub metadata: NormalizedMetadata,
    pub warnings: Vec<String>,
}

/// Reads length and format of files the metadata reader can't parse (MP3, AAC, FLAC…).
pub type TechnicalReader = dyn Fn(&Path) -> Option<AudioTechnical> + Sync;

pub fn inspect(
    path: &Path,
    catalog: &UcsCatalog,
    fallback: Option<&TechnicalReader>,
) -> ScannedSound {
    let meta = std::fs::metadata(path).ok();
    let mut raw = metadata::read(path);
    if raw.technical.duration.is_none()
        && let Some(tech) = fallback.and_then(|f| f(path))
    {
        raw.technical = tech;
    }
    let modified = meta
        .as_ref()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64());
    ScannedSound {
        path: path.to_string_lossy().into_owned(),
        file_size: meta.map_or(0, |m| m.len() as i64),
        modified,
        fingerprint: fingerprint(path),
        metadata: normalize(&raw, path, catalog),
        technical: raw.technical,
        warnings: raw.warnings,
    }
}

/// Reads every file's header on `parallelism` threads. `progress(done, total)` is called as
/// files complete. Results are sorted by path.
pub fn scan(
    root: &Path,
    catalog: &UcsCatalog,
    parallelism: usize,
    fallback: Option<&TechnicalReader>,
    progress: &(dyn Fn(usize, usize) + Sync),
) -> Vec<ScannedSound> {
    let files = list_audio_files(root);
    let next = AtomicUsize::new(0);
    let results = Mutex::new(Vec::with_capacity(files.len()));
    std::thread::scope(|s| {
        for _ in 0..parallelism.max(1).min(files.len().max(1)) {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(path) = files.get(i) else { break };
                    let sound = inspect(path, catalog, fallback);
                    let done = {
                        let mut r = results.lock().unwrap();
                        r.push(sound);
                        r.len()
                    };
                    progress(done, files.len());
                }
            });
        }
    });
    let mut out = results.into_inner().unwrap();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_format() {
        let dir = std::env::temp_dir().join(format!("earmark-fp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("x.bin");
        std::fs::write(&p, b"abc").unwrap();
        // FNV-1a of "abc".
        assert_eq!(fingerprint(&p).unwrap(), "3-e71fa2190541574b");
        let big: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(&p, &big).unwrap();
        assert!(fingerprint(&p).unwrap().starts_with("30d40-"));
    }

    #[test]
    fn extensions() {
        assert_eq!(extension(Path::new("/a/B.WAV")), "wav");
        assert_eq!(extension(Path::new("/a/.wav")), "");
        assert_eq!(extension(Path::new("/a/file.")), "");
    }
}
