//! Audio decoding for the systems without Apple's (docs/rust-engine-plan.md, step 7): files opened
//! read-only, decoded with Symphonia, mixed to mono and resampled as `AudioDecoder.swift` does.

pub mod decode;
pub mod resample;

pub use decode::{AudioError, Decoded, Reader, mono, technical};
pub use resample::Resampler;
