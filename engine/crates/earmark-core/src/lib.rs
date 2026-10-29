//! Earmark's engine (docs/rust-engine-plan.md): everything that isn't UI. Each module is a port
//! of the Swift file named in its documentation and must give the same results.

pub mod bytes;
pub mod csv;
pub mod metadata;
pub mod music_key;
pub mod normalize;
pub mod phase0;
pub mod scan;
pub mod text;
pub mod twins;
pub mod ucs;
pub mod xml;
