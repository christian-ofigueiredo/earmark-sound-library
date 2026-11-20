//! The models through ONNX Runtime (docs/rust-engine-plan.md, step 7), the same vectors and
//! results as `EarmarkML` gets from Core ML: models/convert_onnx.py makes the files from the same
//! PyTorch modules, with the same inputs and outputs. DirectML on Windows; the Mac stays on Core ML.

pub mod clap;
pub mod music;
pub mod peav;
pub mod session;

pub use clap::{ClapEmbedder, ClapModelStore};
pub use music::{MusicAnalyzer, MusicModelStore, MusicResult};
pub use peav::{FileResult, PeavEmbedder};
pub use session::{Compute, ModelError};
