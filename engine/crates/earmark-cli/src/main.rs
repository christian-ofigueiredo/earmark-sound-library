//! `earmark-engine metadata`: reads the files whose paths come on stdin (one per line) and
//! writes, for each, a JSON line with what the engine read and normalised. `earmark-parity
//! metadata` does the same with the Swift code; `engine/parity/compare_metadata.py` compares them.
//! Files are only read.

use earmark_core::{metadata, normalize, ucs::UcsCatalog};
use std::io::{BufRead, Write};
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("metadata") => dump_metadata(),
        Some("--version") => println!("earmark-engine {}", env!("CARGO_PKG_VERSION")),
        _ => {
            eprintln!("usage: earmark-engine metadata < paths.txt");
            std::process::exit(2);
        }
    }
}

fn dump_metadata() {
    let catalog = UcsCatalog::shared();
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    for line in std::io::stdin().lock().lines() {
        let Ok(path) = line else { break };
        if path.is_empty() {
            continue;
        }
        let p = Path::new(&path);
        let raw = metadata::read(p);
        let normalized = normalize::normalize(&raw, p, catalog);
        let row = serde_json::json!({
            "path": path,
            "raw": raw,
            "normalized": normalized,
            "timeReference": metadata::time_reference(p),
        });
        writeln!(out, "{row}").unwrap();
    }
}
