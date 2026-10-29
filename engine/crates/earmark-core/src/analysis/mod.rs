//! Analysis maths (docs/rust-engine-plan.md, step 4): everything between decoded audio or stored
//! embeddings and what Earmark shows. No I/O.

pub mod audio;
pub mod duplicates;
pub mod loudness;
pub mod similarity;
