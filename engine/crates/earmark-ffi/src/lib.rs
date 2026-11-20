//! The engine as the Mac app calls it (docs/rust-engine-plan.md, step 8). UniFFI writes the
//! Swift side from these declarations (scripts/build-engine.sh), so the two can't drift apart.
//!
//! Records with many fields cross as JSON in the shape Swift's `Codable` types already read
//! (the parity checks compare exactly that JSON), so the app keeps its own types.

use earmark_core::metadata::AudioTechnical;
use earmark_core::scan;
use earmark_core::ucs::UcsCatalog;
use std::path::Path;
use std::sync::Arc;

uniffi::setup_scaffolding!();

/// A file's length and format, for the files the engine's reader can't parse (MP3, AAC…).
#[derive(uniffi::Record)]
pub struct Technical {
    pub sample_rate: Option<f64>,
    pub channels: Option<i64>,
    pub bits_per_sample: Option<i64>,
    pub duration: Option<f64>,
}

impl From<Technical> for AudioTechnical {
    fn from(t: Technical) -> AudioTechnical {
        AudioTechnical {
            sample_rate: t.sample_rate,
            channels: t.channels,
            bits_per_sample: t.bits_per_sample,
            duration: t.duration,
        }
    }
}

/// What the app gives a scan: progress as files complete, and its own reader (AVFoundation)
/// for the files the engine can't read the length of.
#[uniffi::export(with_foreign)]
pub trait ScanListener: Send + Sync {
    fn progress(&self, done: u64, total: u64);
    fn technical(&self, path: String) -> Option<Technical>;
}

/// Reads every sound file under `root`, on `parallelism` threads, and never writes. The
/// answer is a JSON array of Swift's `ScannedSound`, sorted by path, with `modified` in seconds
/// since 1970 and, when known, the same time as `modifiedSeconds` and `modifiedNanos`.
#[uniffi::export]
pub fn scan_sounds(root: String, parallelism: u32, listener: Arc<dyn ScanListener>) -> String {
    // The engine's reader type wants a closure that owns what it uses.
    let reader = listener.clone();
    let fallback = move |path: &Path| {
        reader
            .technical(path.to_string_lossy().into_owned())
            .map(AudioTechnical::from)
    };
    let progress = |done: usize, total: usize| listener.progress(done as u64, total as u64);
    let found = scan::scan(
        Path::new(&root),
        UcsCatalog::shared(),
        parallelism as usize,
        Some(&fallback),
        &progress,
    );
    let rows: Vec<serde_json::Value> = found
        .iter()
        .map(|sound| {
            let mut row = serde_json::to_value(sound).unwrap_or_default();
            if let (Some((seconds, nanos)), Some(fields)) =
                (sound.modified_parts, row.as_object_mut())
            {
                fields.insert("modifiedSeconds".into(), seconds.into());
                fields.insert("modifiedNanos".into(), nanos.into());
            }
            row
        })
        .collect();
    serde_json::to_string(&rows).unwrap_or_else(|_| "[]".into())
}

/// The engine's version, so the app can say which engine it runs.
#[uniffi::export]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").into()
}
