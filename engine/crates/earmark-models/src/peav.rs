//! Meta PE-AV large audio embeddings, the same vectors Phase 0 made: one per ≤10 s window
//! (reflect-padded to a multiple of 1920 samples), averaged over up to six windows and
//! L2-normalised. Port of `PeavEmbedder.swift`.
//!
//! The audio tower comes in five parts (models/convert_onnx.py), run part by part over a batch of
//! windows: only one part (≤ 1.1 GB) is loaded at a time. With the graphics card, full 10 s windows
//! run there and shorter ones on the processor, each length being a new graph to plan.

use crate::clap::normalised;
use crate::session::{self, Compute, ModelError};
use earmark_core::analysis::audio;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

pub const DIMENSIONS: usize = 1024;
pub const MODEL_NAME: &str = "pe-av-large";
pub const PARTS: [&str; 5] = [
    "PEAVEmbed",
    "PEAVLayers0",
    "PEAVLayers1",
    "PEAVLayers2",
    "PEAVLayers3",
];

/// What came out for one file.
#[derive(Clone, Debug, PartialEq)]
pub enum FileResult {
    Vector(Vec<f32>),
    /// No windows: silent or shorter than 20 ms.
    Silent,
    /// The model couldn't compute one of the file's windows; the rest of the batch goes on.
    Failed(String),
}

pub struct PeavEmbedder {
    folder: PathBuf,
    compute: Compute,
}

/// A part's output for one window.
type State = (Vec<i64>, Vec<f32>);

/// What one group (graphics card or processor) made of one part.
#[derive(Default)]
struct GroupOutput {
    states: HashMap<usize, State>,
    failures: BTreeMap<usize, String>,
    load_error: Option<ModelError>,
    cancelled: bool,
}

impl PeavEmbedder {
    /// `folder` holds the five parts; nothing is loaded yet.
    pub fn new(folder: PathBuf, compute: Compute) -> Result<PeavEmbedder, ModelError> {
        for part in PARTS {
            let path = part_path(&folder, part);
            if !path.is_file() {
                return Err(ModelError::NotInstalled(path.display().to_string()));
            }
        }
        Ok(PeavEmbedder { folder, compute })
    }

    /// Phase 0's windows for a file's mono 48 kHz audio (empty if silent or shorter than 20 ms).
    pub fn windows(audio48k: &[f32]) -> Vec<Vec<f32>> {
        audio::prepare(audio48k).map_or(Vec::new(), |p| audio::windows(&p))
    }

    /// One result per file from each file's windows. A window the model can't compute fails only
    /// its own file. `cancelled` is checked between windows; returns none if it says so.
    pub fn embed(
        &self,
        files_windows: &[Vec<Vec<f32>>],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Option<Vec<FileResult>>, ModelError> {
        let owner: Vec<usize> = files_windows
            .iter()
            .enumerate()
            .flat_map(|(file, windows)| windows.iter().map(move |_| file))
            .collect();
        let flat: Vec<&Vec<f32>> = files_windows.iter().flatten().collect();
        let mut failures: BTreeMap<usize, String> = BTreeMap::new();
        let mut states: Vec<Option<State>> = vec![None; flat.len()];
        let is_full = |w: &usize| flat[*w].len() == audio::WINDOW_SAMPLES;
        let all: Vec<usize> = (0..flat.len()).collect();
        let full: Vec<usize> = all.iter().copied().filter(is_full).collect();
        let short: Vec<usize> = all.iter().copied().filter(|w| !is_full(w)).collect();
        let groups: Vec<(Vec<usize>, Compute)> = [(full, self.compute), (short, Compute::Cpu)]
            .into_iter()
            .filter(|g| !g.0.is_empty())
            .collect();
        for (index, part) in PARTS.iter().enumerate() {
            if flat.is_empty() {
                break;
            }
            let path = part_path(&self.folder, part);
            let skip: HashSet<usize> = failures.keys().copied().collect();
            let last = index == PARTS.len() - 1;
            let (flat_ref, owner_ref, states_ref, skip_ref) = (&flat, &owner, &states, &skip);
            let outputs: Vec<GroupOutput> = std::thread::scope(|scope| {
                let path = &path;
                let handles: Vec<_> = groups
                    .iter()
                    .map(|(windows, compute)| {
                        scope.spawn(move || {
                            run_part(
                                path,
                                part,
                                last,
                                windows,
                                *compute,
                                flat_ref,
                                owner_ref,
                                skip_ref,
                                states_ref,
                                index == 0,
                                cancelled,
                            )
                        })
                    })
                    .collect();
                handles
                    .into_iter()
                    .map(|h| h.join().unwrap_or_default())
                    .collect()
            });
            if outputs.iter().any(|o| o.cancelled) {
                return Ok(None);
            }
            let mut next: Vec<Option<State>> = vec![None; flat.len()];
            for out in outputs {
                if let Some(error) = out.load_error {
                    return Err(error);
                }
                for (w, state) in out.states {
                    next[w] = Some(state);
                }
                for (file, why) in out.failures {
                    failures.entry(file).or_insert(why);
                }
            }
            states = next;
        }
        let mut results = Vec::with_capacity(files_windows.len());
        let mut w = 0;
        for (file, windows) in files_windows.iter().enumerate() {
            let range = w..w + windows.len();
            w += windows.len();
            if windows.is_empty() {
                results.push(FileResult::Silent);
                continue;
            }
            if let Some(why) = failures.get(&file) {
                results.push(FileResult::Failed(why.clone()));
                continue;
            }
            let mut sum = vec![0f32; DIMENSIONS];
            for k in range {
                if let Some((_, e)) = &states[k] {
                    for (s, x) in sum.iter_mut().zip(e) {
                        *s += x;
                    }
                }
            }
            results.push(FileResult::Vector(normalised(&sum)));
        }
        Ok(Some(results))
    }
}

fn part_path(folder: &Path, part: &str) -> PathBuf {
    folder.join(format!("{part}.onnx"))
}

/// Runs one part over one group of windows with its own model instance.
#[allow(clippy::too_many_arguments)]
fn run_part(
    path: &Path,
    part: &str,
    last: bool,
    windows: &[usize],
    compute: Compute,
    flat: &[&Vec<f32>],
    owner: &[usize],
    skip: &HashSet<usize>,
    states: &[Option<State>],
    first: bool,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> GroupOutput {
    let mut out = GroupOutput::default();
    let mut model = match session::open(path, compute) {
        Ok(m) => m,
        Err(e) => {
            out.load_error = Some(e);
            return out;
        }
    };
    // Loaded only if the graphics card fails a window.
    let mut cpu_model = None;
    let output_name = if last { "embedding" } else { "hidden_out" };
    for &w in windows {
        if cancelled() {
            out.cancelled = true;
            return out;
        }
        if skip.contains(&owner[w]) || out.failures.contains_key(&owner[w]) {
            continue;
        }
        let padded;
        let (name, shape, data): (&str, Vec<i64>, &[f32]) = if first {
            padded = audio::peav_input(flat[w]);
            ("input_values", vec![1, 1, padded.len() as i64], &padded)
        } else {
            let Some((shape, data)) = &states[w] else {
                continue;
            };
            ("hidden", shape.clone(), data)
        };
        let mut result = session::run(&mut model, name, &shape, data, &[output_name]);
        if result.is_err() && compute != Compute::Cpu {
            if cpu_model.is_none() {
                cpu_model = session::open(path, Compute::Cpu).ok();
            }
            if let Some(cpu) = cpu_model.as_mut() {
                result = session::run(cpu, name, &shape, data, &[output_name]);
            }
        }
        match result {
            Ok(mut values) => {
                out.states.insert(w, values.pop().expect("one output"));
            }
            Err(e) => {
                out.failures.insert(
                    owner[w],
                    format!("{part}, window of {} values: {e}", data.len()),
                );
            }
        }
    }
    out
}
