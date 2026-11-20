//! Tempo and key, worked out as Phase 0 did: Beat This! (final0) over 30 s chunks of the song's
//! log-mel spectrogram, then Phase 0's tempo summary; S-KEY over the whole song, peak-normalised.
//! Takes the song's first 20 minutes, mono 22.05 kHz. Port of `MusicAnalyzer.swift`.

use crate::session::{self, Compute, ModelError};
use earmark_core::analysis::music::{self, KeyEstimate, Summary};
use ort::session::Session;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub const FILES: [&str; 2] = ["BeatThis.onnx", "SKey.onnx"];

pub struct MusicResult {
    pub tempo: Summary,
    pub key: Option<KeyEstimate>,
    pub seconds: f64,
}

pub struct MusicAnalyzer {
    /// Workers share the models; predictions are serialised.
    beat: Mutex<Session>,
    key: Mutex<Session>,
}

fn locked(m: &Mutex<Session>) -> Result<std::sync::MutexGuard<'_, Session>, ModelError> {
    m.lock()
        .map_err(|_| ModelError::Runtime("a worker failed".into()))
}

impl MusicAnalyzer {
    /// `folder` holds the two models.
    pub fn open(folder: &Path, compute: Compute) -> Result<MusicAnalyzer, ModelError> {
        Ok(MusicAnalyzer {
            beat: Mutex::new(session::open(&folder.join(FILES[0]), compute)?),
            key: Mutex::new(session::open(&folder.join(FILES[1]), compute)?),
        })
    }

    /// A song decoded as Phase 0 did it: mono, the first 20 minutes, at 44.1 kHz, then halved with
    /// a filter shaped like Phase 0's. The file is only read.
    pub fn decode(path: &Path) -> Result<Vec<f32>, ModelError> {
        let audio = earmark_audio::mono(path, 44_100, music::MAX_SECONDS)
            .map_err(|e| ModelError::Audio(e.to_string()))?;
        Ok(music::decimate(&audio))
    }

    /// None for audio shorter than 2 s or silent (Phase 0 skipped those), or when `cancelled` says
    /// so (checked between chunks).
    pub fn analyse(
        &self,
        audio22k: &[f32],
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Option<MusicResult>, ModelError> {
        let sr = music::SAMPLE_RATE;
        let limit = music::MAX_SECONDS as usize * sr;
        let x = &audio22k[..audio22k.len().min(limit)];
        let peak = x.iter().fold(0f32, |m, v| m.max(v.abs()));
        if x.len() < 2 * sr || peak < 1e-5 {
            return Ok(None);
        }
        let spect = music::spectrogram(x);
        let frames = music::frame_count(x.len());
        let starts = music::chunk_starts(frames);
        let (mut beats, mut downbeats) = (Vec::new(), Vec::new());
        for &start in &starts {
            if cancelled() {
                return Ok(None);
            }
            let (b, d) = self.logits(&music::chunk(&spect, frames, start))?;
            beats.push(b);
            downbeats.push(d);
        }
        let beat_logits = music::aggregate(&beats, &starts, frames);
        let downbeat_logits = music::aggregate(&downbeats, &starts, frames);
        let (peak_beats, peak_downbeats) = music::peaks(&beat_logits, &downbeat_logits);
        let probability: Vec<f32> = beat_logits.iter().map(|&l| music::sigmoid(l)).collect();
        let tempo = music::summarize(&peak_beats, &peak_downbeats, &probability);
        if cancelled() {
            return Ok(None);
        }
        let normalised: Vec<f32> = x.iter().map(|v| v / peak).collect();
        let key = music::estimate_key(&self.key_probabilities(&normalised)?);
        Ok(Some(MusicResult {
            tempo,
            key,
            seconds: x.len() as f64 / sr as f64,
        }))
    }

    /// Beat and downbeat logits for one chunk.
    pub fn logits(&self, chunk: &[f32]) -> Result<(Vec<f32>, Vec<f32>), ModelError> {
        let shape = [1, music::CHUNK as i64, music::MELS as i64];
        let mut session = locked(&self.beat)?;
        let mut out = session::run(&mut session, "spect", &shape, chunk, &["beat", "downbeat"])?;
        let (_, downbeat) = out.pop().expect("two outputs");
        let (_, beat) = out.pop().expect("two outputs");
        Ok((beat, downbeat))
    }

    /// S-KEY's 24 probabilities for the whole (peak-normalised) song.
    pub fn key_probabilities(&self, x: &[f32]) -> Result<Vec<f32>, ModelError> {
        let shape = [1, x.len() as i64];
        let mut session = locked(&self.key)?;
        let mut out = session::run(&mut session, "audio", &shape, x, &["probs"])?;
        Ok(out.pop().expect("one output").1)
    }
}

/// Finds and loads the tempo and key models from a folder on demand, for the compute asked for,
/// and lets go of them when analysis pauses.
pub struct MusicModelStore {
    pub folder: PathBuf,
    loaded: Mutex<Option<(Compute, Arc<MusicAnalyzer>)>>,
}

impl MusicModelStore {
    pub fn new(folder: PathBuf) -> MusicModelStore {
        MusicModelStore {
            folder,
            loaded: Mutex::new(None),
        }
    }

    pub fn is_installed(&self) -> bool {
        FILES.iter().all(|f| self.folder.join(f).is_file())
    }

    /// The models for this compute; loads them if needed. Thread-safe.
    pub fn get(&self, compute: Compute) -> Result<Arc<MusicAnalyzer>, ModelError> {
        let mut loaded = self
            .loaded
            .lock()
            .map_err(|_| ModelError::Runtime("a worker failed".into()))?;
        if let Some((c, analyzer)) = loaded.as_ref()
            && *c == compute
        {
            return Ok(analyzer.clone());
        }
        *loaded = None;
        let analyzer = Arc::new(MusicAnalyzer::open(&self.folder, compute)?);
        *loaded = Some((compute, analyzer.clone()));
        Ok(analyzer)
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
