//! The Swift AnalysisFileTests: what Earmark worked out, taken to "another machine" (a second
//! database whose libraries are elsewhere, with files moved, renamed and changed).

#[path = "../../earmark-core/tests/common/mod.rs"]
mod common;

use common::*;
use earmark_core::analysis::folder_rules::FolderRule;
use earmark_core::analysis_file::{self, AnalysisFile, Song, SongValues};
use earmark_core::music_key::MusicKey;
use earmark_core::phase0::SongAnalysis;
use earmark_core::records::{Library, SoundEmbedding, SoundFacts, SoundRecord};
use earmark_core::scan::{fingerprint, scan};
use earmark_core::song_corrections::SongEdit;
use earmark_core::ucs::UcsCatalog;
use earmark_db::{LibraryDatabase, SongFile};
use std::path::Path;

const NOW: &str = "2027-01-15T08:00:00Z";
const AT: &str = "2026-10-30 12:00:00.000";

fn clap() -> Vec<f32> {
    (0..512).map(|i| i as f32 / 512.0).collect()
}
fn peav() -> Vec<f32> {
    (0..1024).map(|i| -(i as f32) / 1024.0).collect()
}

fn memory() -> LibraryDatabase {
    LibraryDatabase::open(None, false).unwrap()
}

fn read_fp(p: &Path) -> Option<String> {
    fingerprint(p)
}

/// A sound library in a new folder with these files (path → seconds of silence: the same
/// seconds, the same content).
fn library(db: &LibraryDatabase, name: &str, files: &[(&str, f64)]) -> Library {
    let root = temp_dir(name);
    for (path, seconds) in files {
        write(&root, path, &wav(*seconds, 48000, &[]));
    }
    let r = root.to_string_lossy().into_owned();
    let lib = db.add_library("sounds", &r, None).unwrap();
    db.replace_sounds(
        lib.id,
        &r,
        &scan(&root, UcsCatalog::shared(), 4, None, &|_, _| {}),
    )
    .unwrap();
    lib
}

fn facts(s: &SoundRecord, loudness: f64, peak: f64) -> SoundFacts {
    SoundFacts {
        sound_id: s.id.unwrap(),
        fingerprint: s.fingerprint.clone(),
        version: 1,
        loudness: Some(loudness),
        peak: Some(peak),
        error: None,
        analyzed_at: AT.into(),
    }
}

fn embedding(s: &SoundRecord, model: &str, v: &[f32]) -> SoundEmbedding {
    SoundEmbedding {
        sound_id: s.id.unwrap(),
        model: model.into(),
        fingerprint: s.fingerprint.clone(),
        version: 1,
        vector: Some(SoundEmbedding::bytes(v)),
        error: None,
        analyzed_at: AT.into(),
    }
}

fn rule(lib: i64, folder: &str, cat: &str) -> FolderRule {
    FolderRule {
        library_id: lib,
        folder: folder.into(),
        cat_id: cat.into(),
        created_at: AT.into(),
    }
}

fn round_trip(f: &AnalysisFile) -> AnalysisFile {
    AnalysisFile::read(&f.encoded().unwrap()).unwrap()
}

fn named(db: &LibraryDatabase, name: &str) -> SoundRecord {
    db.sounds(None)
        .unwrap()
        .into_iter()
        .find(|s| s.file_name == name)
        .unwrap()
}

#[test]
fn sounds_travel_by_content_and_only_fill_gaps() {
    let (here, there) = (memory(), memory());
    let lib = library(
        &here,
        "travel-a",
        &[("Pack/one.wav", 1.0), ("Pack/two.wav", 2.0)],
    );
    for s in here.sounds(None).unwrap() {
        here.save_facts(&[facts(&s, -20.0, -1.0)]).unwrap();
        here.save_embeddings(&[
            embedding(&s, "clap-general", &clap()),
            embedding(&s, "pe-av-large", &peav()),
        ])
        .unwrap();
    }
    here.save_folder_rules(&[rule(lib.id, "Pack", "AMBForst")])
        .unwrap();
    let one = named(&here, "one.wav");
    here.set_sound_category(
        &[(one.id.unwrap(), one.fingerprint.clone())],
        Some("DOORWood"),
    )
    .unwrap();
    // The other machine: one.wav moved and renamed, two.wav changed (other content).
    let theirs = library(
        &there,
        "travel-b",
        &[("Moved/uno.wav", 1.0), ("Pack/two.wav", 3.0)],
    );

    let file = round_trip(&here.analysis_file(&lib, true, NOW, &read_fp).unwrap());
    assert_eq!(file.sounds.as_ref().unwrap().len(), 2);
    assert_eq!(
        file.folder_categories.as_ref().unwrap()[0].cat_id,
        "AMBForst"
    );
    let report = there.import_analysis(&file, &read_fp).unwrap();
    assert_eq!(
        (
            report.sounds,
            report.sounds_matched,
            report.facts,
            report.embeddings
        ),
        (2, 1, 1, 2)
    );
    assert_eq!((report.folder_categories, report.sound_categories), (1, 1));
    let uno = named(&there, "uno.wav");
    let id = uno.id.unwrap();
    let choice = there.sound_category_choices().unwrap()[&id].clone();
    assert!(choice.cat_id == "DOORWood" && choice.by_owner);
    let got = there.sound_facts().unwrap();
    assert_eq!(got[&id].loudness, Some(-20.0));
    assert!(got[&id].is_current(&uno));
    let vector = |model| {
        SoundEmbedding::floats(&there.embedding(id, model).unwrap().unwrap().vector.unwrap())
    };
    assert_eq!(vector("clap-general"), clap()); // bit-exact
    assert_eq!(vector("pe-av-large"), peav());
    assert!(!got.contains_key(&named(&there, "two.wav").id.unwrap())); // changed: analysed again there
    let rules = there.folder_rules().unwrap();
    assert_eq!(rules.len(), 1);
    assert_eq!(
        (
            rules[0].library_id,
            rules[0].folder.as_str(),
            rules[0].cat_id.as_str()
        ),
        (theirs.id, "Pack", "AMBForst")
    );
    // A second import adds nothing.
    let again = there.import_analysis(&file, &read_fp).unwrap();
    assert_eq!(
        (again.sound_categories, again.facts, again.embeddings),
        (0, 0, 0)
    );
}

#[test]
fn local_results_and_choices_win() {
    let (here, there) = (memory(), memory());
    let lib = library(&here, "win-a", &[("Pack/one.wav", 1.0)]);
    let mine = here.sounds(None).unwrap()[0].clone();
    here.save_facts(&[facts(&mine, -20.0, -1.0)]).unwrap();
    here.save_folder_rules(&[rule(lib.id, "Pack", "AMBForst")])
        .unwrap();
    let theirs = library(&there, "win-b", &[("Pack/one.wav", 1.0)]);
    let s = there.sounds(None).unwrap()[0].clone();
    there.save_facts(&[facts(&s, -30.0, -6.0)]).unwrap();
    there
        .save_folder_rules(&[rule(theirs.id, "Pack", "AIRBrst")])
        .unwrap();
    let file = round_trip(&here.analysis_file(&lib, false, NOW, &read_fp).unwrap());
    let report = there.import_analysis(&file, &read_fp).unwrap();
    assert_eq!(
        (
            report.sounds_matched,
            report.facts,
            report.folder_categories
        ),
        (1, 0, 0)
    );
    assert_eq!(
        there.sound_facts().unwrap()[&s.id.unwrap()].loudness,
        Some(-30.0)
    );
    assert_eq!(there.folder_rules().unwrap()[0].cat_id, "AIRBrst");
}

#[test]
fn written_file_is_the_same_as_the_one_built_in_memory() {
    let db = memory();
    let lib = library(
        &db,
        "written",
        &[("Pack/one.wav", 1.0), ("Pack/two.wav", 2.0), ("b.wav", 3.0)],
    );
    for s in db.sounds(None).unwrap() {
        db.save_facts(&[facts(&s, -20.0, -1.0)]).unwrap();
        db.save_embeddings(&[embedding(&s, "clap-general", &clap())])
            .unwrap();
    }
    db.save_folder_rules(&[rule(lib.id, "Pack", "AMBForst")])
        .unwrap();
    let dir = temp_dir("written-out");
    let path = dir.join(analysis_file::file_name(&lib));
    for _ in 0..2 {
        // The second time over the first.
        let bytes = db
            .write_analysis_file(&lib, true, &path, NOW, &read_fp)
            .unwrap();
        let data = std::fs::read(&path).unwrap();
        assert_eq!(bytes, data.len());
        let written = AnalysisFile::read(&data).unwrap();
        let built = db.analysis_file(&lib, true, NOW, &read_fp).unwrap();
        assert_eq!(written, built);
        assert_eq!(written.sounds.unwrap().len(), 3);
    }
    let names: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert_eq!(names.len(), 1, "no partial file left behind");
}

#[test]
fn embeddings_can_be_left_out() {
    let db = memory();
    let lib = library(&db, "leftout", &[("a.wav", 1.0)]);
    let s = db.sounds(None).unwrap()[0].clone();
    db.save_embeddings(&[embedding(&s, "clap-general", &clap())])
        .unwrap();
    assert!(
        db.analysis_file(&lib, false, NOW, &read_fp)
            .unwrap()
            .sounds
            .unwrap()
            .is_empty()
    );
    let with = db
        .analysis_file(&lib, true, NOW, &read_fp)
        .unwrap()
        .sounds
        .unwrap();
    assert!(
        with[0]
            .embeddings
            .as_ref()
            .unwrap()
            .contains_key("clap-general")
    );
}

#[test]
fn songs_travel_with_source_and_corrections() {
    let (here, there) = (memory(), memory());
    let (a, b) = (temp_dir("songs-a"), temp_dir("songs-b"));
    for (path, seconds) in [("s1.wav", 1.0), ("s2.wav", 2.0), ("sub/s3.wav", 3.0)] {
        write(&a, path, &wav(seconds, 48000, &[]));
    }
    // The other machine: s1 moved, s2 in place, s3 missing.
    write(&b, "other/s1.wav", &wav(1.0, 48000, &[]));
    write(&b, "s2.wav", &wav(2.0, 48000, &[]));
    let songs = |root: &Path, paths: &[&str]| -> Vec<SongFile> {
        paths
            .iter()
            .map(|p| {
                let path = root.join(p);
                SongFile {
                    path: path.to_string_lossy().into_owned(),
                    file_size: std::fs::metadata(&path).unwrap().len() as i64,
                    modified: 0.0,
                    title: None,
                    artist: None,
                    album: None,
                    duration: None,
                }
            })
            .collect()
    };
    let text = |p: &Path| p.to_string_lossy().into_owned();
    let lib = here.add_library("music", &text(&a), None).unwrap();
    here.replace_songs(
        lib.id,
        &text(&a),
        &songs(&a, &["s1.wav", "s2.wav", "sub/s3.wav"]),
    )
    .unwrap();
    let id = |db: &LibraryDatabase, name: &str| {
        db.songs(None)
            .unwrap()
            .into_iter()
            .find(|s| s.file_name == name)
            .unwrap()
    };
    let earmark = |bpm| SongAnalysis {
        bpm: Some(bpm),
        source: "Earmark".into(),
        ..Default::default()
    };
    here.save_song_analysis(&[
        (
            id(&here, "s1.wav").id.unwrap(),
            SongAnalysis {
                bpm: Some(61.75),
                key: Some(MusicKey::new(11, true)),
                key_confidence: Some(0.8),
                source: "Phase 0".into(),
                ..Default::default()
            },
        ),
        (id(&here, "s2.wav").id.unwrap(), earmark(90.0)),
        (id(&here, "s3.wav").id.unwrap(), earmark(100.0)),
    ])
    .unwrap();
    let s1 = id(&here, "s1.wav");
    here.set_song_corrections(&[(
        s1.path.clone(),
        s1.correction_after(SongEdit::DoubleTempo, AT),
    )])
    .unwrap();

    let their_lib = there.add_library("music", &text(&b), None).unwrap();
    there
        .replace_songs(
            their_lib.id,
            &text(&b),
            &songs(&b, &["other/s1.wav", "s2.wav"]),
        )
        .unwrap();
    there
        .save_song_analysis(&[(id(&there, "s2.wav").id.unwrap(), earmark(45.0))])
        .unwrap(); // already there

    let file = round_trip(&here.analysis_file(&lib, true, NOW, &read_fp).unwrap());
    let entries = file.songs.as_ref().unwrap();
    assert!(entries.len() == 3 && entries.iter().all(|s| s.fingerprint.is_some()));
    let report = there.import_analysis(&file, &read_fp).unwrap();
    assert_eq!(
        (
            report.songs,
            report.songs_matched,
            report.song_analyses,
            report.corrections
        ),
        (3, 2, 1, 1)
    );
    let theirs = id(&there, "s1.wav");
    assert_eq!(
        (
            theirs.bpm,
            theirs.analysis_source.as_deref(),
            theirs.key_confidence
        ),
        (Some(61.75), Some("Phase 0"), Some(0.8))
    );
    assert_eq!(theirs.key(), Some(MusicKey::new(11, true)));
    let corrections = there.song_corrections().unwrap();
    assert_eq!(corrections.len(), 1);
    assert_eq!(
        (corrections[0].path.as_str(), corrections[0].bpm),
        (theirs.path.as_str(), Some(123.5))
    );
    assert_eq!(id(&there, "s2.wav").bpm, Some(45.0)); // theirs stays
}

#[test]
fn songs_without_fingerprint_match_by_place_and_size() {
    let db = memory();
    let lib = db.add_library("music", "/Music/Liked", None).unwrap();
    let f = |p: &str| SongFile {
        path: p.into(),
        file_size: 10,
        modified: 0.0,
        title: None,
        artist: None,
        album: None,
        duration: None,
    };
    db.replace_songs(
        lib.id,
        "/Music/Liked",
        &[f("/Music/Liked/sub/a.mp3"), f("/Music/Liked/b.mp3")],
    )
    .unwrap();
    let mut file = AnalysisFile::new(NOW, &lib);
    file.songs = Some(vec![Song {
        path: "sub/a.mp3".into(),
        size: 10,
        fingerprint: None,
        analysis: Some(SongValues {
            bpm: Some(120.0),
            source: Some("Phase 0".into()),
            ..Default::default()
        }),
        correction: None,
    }]);
    let report = db.import_analysis(&file, &|_| None).unwrap();
    assert_eq!((report.songs_matched, report.song_analyses), (1, 1));
    // b.mp3, sub/a.mp3 (by path).
    assert_eq!(
        db.songs(None)
            .unwrap()
            .iter()
            .map(|s| s.bpm)
            .collect::<Vec<_>>(),
        [None, Some(120.0)]
    );
}
