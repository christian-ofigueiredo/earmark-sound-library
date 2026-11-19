//! Analysis maths (docs/rust-engine-plan.md, step 4): everything between decoded audio or stored
//! embeddings and what Earmark shows. No I/O.

pub mod audio;
pub mod categories;
pub mod duplicates;
pub mod folder_rules;
pub mod groups;
pub mod hdbscan;
pub mod linalg;
pub mod loudness;
pub mod music;
pub mod similarity;
pub mod sound_map;
