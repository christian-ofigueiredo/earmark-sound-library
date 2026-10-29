//! The Swift ScannerTests (app/Tests/EarmarkCoreTests/CoreTests.swift).

mod common;

use common::*;
use earmark_core::scan::{fingerprint, list_audio_files, scan};
use earmark_core::ucs::UcsCatalog;
use std::collections::BTreeMap;
use std::path::Path;
use std::time::SystemTime;

fn snapshot(root: &Path) -> BTreeMap<String, SystemTime> {
    fn walk(dir: &Path, out: &mut BTreeMap<String, SystemTime>) {
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            let m = e.metadata().unwrap();
            out.insert(
                e.path().to_string_lossy().into_owned(),
                m.modified().unwrap(),
            );
            if m.is_dir() {
                walk(&e.path(), out);
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, &mut out);
    out
}

#[test]
fn scans_read_only_and_skips_hidden_files() {
    let root = temp_dir("scan");
    for f in ["A/WHSH_One_X_Y.wav", "A/B/plain.wav", "C/song.aif"] {
        let data = if f.ends_with(".aif") {
            aiff(0.2, 44100.0, "x")
        } else {
            wav(0.2, 48000, &[])
        };
        write(&root, f, &data);
    }
    write(&root, "A/._WHSH_One_X_Y.wav", b"junk");
    write(&root, ".hidden/skip.wav", &wav(0.5, 48000, &[]));
    write(&root, "A/readme.txt", b"notes");

    let before = snapshot(&root);
    let sounds = scan(&root, UcsCatalog::shared(), 4, None, &|_, _| {});
    assert_eq!(sounds.len(), 3);
    let whsh = sounds
        .iter()
        .find(|s| s.path.ends_with("WHSH_One_X_Y.wav"))
        .unwrap();
    assert_eq!(whsh.metadata.ucs.as_ref().unwrap().cat_id, "WHSH");
    assert!(sounds.iter().all(|s| s.fingerprint.is_some()));
    assert!(sounds.windows(2).all(|w| w[0].path < w[1].path));
    assert_eq!(snapshot(&root), before); // nothing added, nothing touched
    assert_eq!(list_audio_files(&root).len(), 3);
}

#[test]
fn fingerprint_follows_content_not_name() {
    let root = temp_dir("fingerprint");
    let a = write(&root, "a.wav", &wav(2.0, 48000, &[]));
    let b = write(&root, "renamed.wav", &wav(2.0, 48000, &[]));
    let other = write(&root, "other.wav", &wav(3.0, 48000, &[]));
    assert_eq!(fingerprint(&a), fingerprint(&b));
    assert_ne!(fingerprint(&a), fingerprint(&other));
}
