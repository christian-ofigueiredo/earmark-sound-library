//! Earmark's engine (docs/rust-engine-plan.md): everything that isn't UI. Each module is a port
//! of the Swift file named in its documentation and must give the same results.

// Index loops and counters are kept where the Swift code has them, so a port reads line for line
// against the code it must match.
#![allow(
    clippy::needless_range_loop,
    clippy::explicit_counter_loop,
    clippy::type_complexity
)]

pub mod analysis;
pub mod bytes;
pub mod csv;
pub mod dates;
pub mod metadata;
pub mod music_key;
pub mod normalize;
pub mod paths;
pub mod phase0;
pub mod records;
pub mod scan;
pub mod song_corrections;
pub mod text;
pub mod twins;
pub mod ucs;
pub mod xml;
