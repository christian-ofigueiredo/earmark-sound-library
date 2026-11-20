//! LAION CLAP (larger_clap_general) audio embeddings, the same vectors Phase 0 made: one per ≤10 s
//! window, averaged over up to six windows and L2-normalised. Port of `ClapEmbedder.swift`.

use crate::session::{self, Compute, ModelError};
use earmark_core::analysis::audio;
use ort::session::Session;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub const DIMENSIONS: usize = 512;
pub const MODEL_NAME: &str = "clap-general";
pub const FILE_NAME: &str = "CLAPAudio.onnx";

pub struct ClapEmbedder {
    /// Workers share one model; predictions are serialised.
    session: Mutex<Session>,
}

pub(crate) fn normalised(v: &[f32]) -> Vec<f32> {
    let norm = v.iter().fold(0f32, |s, x| s + x * x).sqrt().max(1e-12);
    v.iter().map(|x| x / norm).collect()
}

impl ClapEmbedder {
    pub fn open(path: &Path) -> Result<ClapEmbedder, ModelError> {
        Ok(ClapEmbedder {
            session: Mutex::new(session::open(path, Compute::Cpu)?),
        })
    }

    /// The file's vector from mono 48 kHz audio, or none if it's silent or shorter than 20 ms.
    pub fn embed(&self, audio48k: &[f32]) -> Result<Option<Vec<f32>>, ModelError> {
        match audio::prepare(audio48k) {
            Some(prepared) => self.embed_windows(&audio::windows(&prepared)),
            None => Ok(None),
        }
    }

    /// The file's vector from its Phase 0 windows, or none if there are none.
    pub fn embed_windows(&self, windows: &[Vec<f32>]) -> Result<Option<Vec<f32>>, ModelError> {
        if windows.is_empty() {
            return Ok(None);
        }
        let mut sum = vec![0f32; DIMENSIONS];
        for window in windows {
            let e = self.embed_features(&audio::clap_features(window))?;
            for (s, x) in sum.iter_mut().zip(&e) {
                *s += x;
            }
        }
        Ok(Some(normalised(&sum)))
    }

    /// One window's (already normalised) vector from its log-mel features.
    pub fn embed_features(&self, features: &[f32]) -> Result<Vec<f32>, ModelError> {
        let shape = [1, 1, audio::CLAP_FRAMES as i64, audio::CLAP_MELS as i64];
        let mut session = self
            .session
            .lock()
            .map_err(|_| ModelError::Runtime("a worker failed".into()))?;
        let mut out = session::run(&mut session, "melspec", &shape, features, &["embedding"])?;
        let (_, values) = out.pop().expect("one output");
        if values.len() != DIMENSIONS {
            return Err(ModelError::Runtime(format!(
                "expected {DIMENSIONS} values, got {}",
                values.len()
            )));
        }
        Ok(values)
    }
}

/// Finds and loads the CLAP model from a folder on demand, and lets go of it when analysis pauses
/// so its memory goes back to other apps.
pub struct ClapModelStore {
    pub folder: PathBuf,
    loaded: Mutex<Option<Arc<ClapEmbedder>>>,
}

impl ClapModelStore {
    pub fn new(folder: PathBuf) -> ClapModelStore {
        ClapModelStore {
            folder,
            loaded: Mutex::new(None),
        }
    }

    pub fn is_installed(&self) -> bool {
        self.folder.join(FILE_NAME).is_file()
    }

    /// The loaded model; loads it if needed. Thread-safe.
    pub fn get(&self) -> Result<Arc<ClapEmbedder>, ModelError> {
        let mut loaded = self
            .loaded
            .lock()
            .map_err(|_| ModelError::Runtime("a worker failed".into()))?;
        if let Some(embedder) = loaded.as_ref() {
            return Ok(embedder.clone());
        }
        let embedder = Arc::new(ClapEmbedder::open(&self.folder.join(FILE_NAME))?);
        *loaded = Some(embedder.clone());
        Ok(embedder)
    }

    pub fn unload(&self) {
        if let Ok(mut loaded) = self.loaded.lock() {
            *loaded = None;
        }
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded.lock().is_ok_and(|l| l.is_some())
    }
}
