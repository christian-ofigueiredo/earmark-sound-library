//! The Swift DatabaseTests (app/Tests/EarmarkCoreTests/CoreTests.swift), with the same files.

#[path = "../../earmark-core/tests/common/mod.rs"]
mod common;

use common::*;
use earmark_core::music_key::MusicKey;
use earmark_core::phase0::{self, SongAnalysis};
use earmark_core::scan::scan;
use earmark_core::twins::{self, TwinCandidate};
use earmark_core::ucs::UcsCatalog;
use earmark_db::{LibraryDatabase, SongFile};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

fn scanned(root: &Path) -> Vec<earmark_core::scan::ScannedSound> {
    scan(root, UcsCatalog::shared(), 4, None, &|_, _| {})
}

fn root_str(root: &Path) -> String {
    root.to_string_lossy().into_owned()
}

#[test]
fn sounds_are_replaced_not_duplicated() {
    let db = LibraryDatabase::open(None, false).unwrap();
    let root = temp_dir("db-replace");
    write(&root, "TSK-03/Footsteps/one.wav", &wav(0.5, 48000, &[]));
    write(&root, "two.wav", &wav(0.5, 48000, &[]));
    let lib = db.add_library("sounds", &root_str(&root), None).unwrap();
    db.replace_sounds(lib.id, &root_str(&root), &scanned(&root))
        .unwrap();
    let first = db.sounds(None).unwrap();
    assert_eq!(first.len(), 2);
    assert!(first.iter().any(|s| s.folder == "TSK-03/Footsteps"));
    std::fs::remove_file(root.join("two.wav")).unwrap();
    db.replace_sounds(lib.id, &root_str(&root), &scanned(&root))
        .unwrap();
    let second = db.sounds(None).unwrap();
    assert_eq!(second.len(), 1);
    assert_eq!(
        second[0].id,
        first.iter().find(|s| s.file_name == "one.wav").unwrap().id
    );
    assert_eq!(
        db.add_library("sounds", &root_str(&root), None).unwrap().id,
        lib.id
    );
    db.remove_library(lib.id).unwrap();
    assert!(db.sounds(None).unwrap().is_empty());
}

#[test]
fn sounds_keep_their_id_through_renames_and_re_adding() {
    let db = LibraryDatabase::open(None, false).unwrap();
    let root = temp_dir("db-ids");
    let r = root_str(&root);
    write(&root, "A/one.wav", &wav(1.0, 48000, &[]));
    write(&root, "two.wav", &wav(2.0, 48000, &[]));
    let mut lib = db.add_library("sounds", &r, None).unwrap();
    db.replace_sounds(lib.id, &r, &scanned(&root)).unwrap();
    let ids: BTreeMap<String, i64> = db
        .sounds(None)
        .unwrap()
        .into_iter()
        .map(|s| (s.file_name, s.id.unwrap()))
        .collect();

    // Moved and renamed: the same content, the same id.
    std::fs::create_dir_all(root.join("B")).unwrap();
    std::fs::rename(root.join("A/one.wav"), root.join("B/renamed.wav")).unwrap();
    db.replace_sounds(lib.id, &r, &scanned(&root)).unwrap();
    let moved = db.sounds(None).unwrap();
    assert_eq!(moved.len(), 2);
    let renamed = moved.iter().find(|s| s.file_name == "renamed.wav").unwrap();
    assert_eq!(renamed.id, Some(ids["one.wav"]));
    assert_eq!(renamed.folder, "B");

    // Removed from Earmark, then added again: the ids come back.
    db.remove_library(lib.id).unwrap();
    assert!(db.sounds(None).unwrap().is_empty());
    lib = db.add_library("sounds", &r, None).unwrap();
    db.replace_sounds(lib.id, &r, &scanned(&root)).unwrap();
    let back = db.sounds(None).unwrap();
    assert_eq!(
        back.iter()
            .find(|s| s.file_name == "renamed.wav")
            .unwrap()
            .id,
        Some(ids["one.wav"])
    );
    assert_eq!(
        back.iter().find(|s| s.file_name == "two.wav").unwrap().id,
        Some(ids["two.wav"])
    );

    // A file deleted on disk and later restored also gets its id back.
    let two = root.join("two.wav");
    let saved = std::fs::read(&two).unwrap();
    std::fs::remove_file(&two).unwrap();
    db.replace_sounds(lib.id, &r, &scanned(&root)).unwrap();
    assert_eq!(db.sounds(None).unwrap().len(), 1);
    std::fs::write(&two, saved).unwrap();
    db.replace_sounds(lib.id, &r, &scanned(&root)).unwrap();
    assert_eq!(
        db.sounds(None)
            .unwrap()
            .iter()
            .find(|s| s.file_name == "two.wav")
            .unwrap()
            .id,
        Some(ids["two.wav"])
    );
}

#[test]
fn format_twins_keep_the_best_copy() {
    let db = LibraryDatabase::open(None, false).unwrap();
    let root = temp_dir("db-twins");
    write(
        &root,
        "Pack (MP3,WAV)/Pack - WAV/Hits/01 Hit.wav",
        &wav(1.0, 48000, &[]),
    );
    write(
        &root,
        "Pack (MP3,WAV)/Pack - MP3/Hits/01 Hit.mp3",
        b"not really an mp3",
    );
    // The same name and folder pattern, a clearly different length: a different sound.
    write(&root, "Other/Long.wav", &wav(1.0, 48000, &[]));
    write(&root, "Other/long.aif", &aiff(3.0, 44100.0, "x"));
    // The same name in an unrelated folder: not a twin.
    write(&root, "Elsewhere/01 Hit.mp3", b"mp3");
    let lib = db.add_library("sounds", &root_str(&root), None).unwrap();
    db.replace_sounds(lib.id, &root_str(&root), &scanned(&root))
        .unwrap();
    let sounds = db.sounds(None).unwrap();
    // By folder and name, which use "/" on every system.
    let id = |suffix: &str| {
        sounds
            .iter()
            .find(|s| format!("{}/{}", s.folder, s.file_name).ends_with(suffix))
            .unwrap()
            .id
            .unwrap()
    };
    let candidates: Vec<TwinCandidate> = sounds
        .iter()
        .map(|s| TwinCandidate {
            id: s.id.unwrap(),
            library_id: s.library_id,
            file_name: s.file_name.clone(),
            folder: s.folder.clone(),
            path: s.path.clone(),
            duration: s.duration,
            sample_rate: s.sample_rate,
            bits_per_sample: s.bits_per_sample,
        })
        .collect();
    let groups = twins::group(&candidates);
    assert_eq!(
        groups.hidden,
        BTreeSet::from([id("Pack - MP3/Hits/01 Hit.mp3")])
    );
    assert_eq!(
        groups.alternates,
        BTreeMap::from([(
            id("Pack - WAV/Hits/01 Hit.wav"),
            vec![id("Pack - MP3/Hits/01 Hit.mp3")]
        )])
    );
}

fn song(path: &str, size: i64, title: Option<&str>) -> SongFile {
    SongFile {
        path: path.into(),
        file_size: size,
        modified: 1_754_038_260.0,
        title: title.map(str::to_string),
        artist: None,
        album: None,
        duration: None,
    }
}

#[test]
fn imports_phase0_music_analysis() {
    let db = LibraryDatabase::open(None, false).unwrap();
    let lib = db.add_library("music", "/Music/Liked", None).unwrap();
    db.replace_songs(
        lib.id,
        "/Music/Liked",
        &[
            song("/Music/Liked/01 Loser.mp3", 1000, Some("Loser")),
            song("/Music/Liked/sub/02 Dragonborn.mp3", 2000, None),
            song("/Music/Liked/03 Untouched.mp3", 3000, None),
        ],
    )
    .unwrap();
    let json = br#"{"format": "soundlab-music-analysis", "version": 1, "tracks": [
      {"file": "01 Loser.mp3", "path": "/Volumes/Old/Liked/01 Loser.mp3", "size": 1000, "bpm": 83.0,
       "bpm_range": [82.9, 83.1], "tempo_stability": "steady", "beats_per_bar": 4, "key_pc": 5, "key_minor": true,
       "key_confidence": 0.84, "key_second_opinion": "F minor"},
      {"file": "sub/02 Dragonborn.mp3", "path": "/elsewhere/02 Dragonborn.mp3", "size": 2000, "bpm": 2.63,
       "beats_per_bar": 1, "key_pc": 11, "key_minor": true, "key_confidence": 0.51}
    ]}"#;
    let entries = phase0::read(json).unwrap();
    assert_eq!(db.apply_song_analysis(&entries).unwrap(), 2); // matched by file name + size
    let songs = db.songs(None).unwrap();
    let loser = songs
        .iter()
        .find(|s| s.file_name == "01 Loser.mp3")
        .unwrap();
    assert_eq!(loser.bpm, Some(83.0));
    assert_eq!(loser.key().unwrap().name(), "F minor");
    assert_eq!(loser.key().unwrap().camelot(), "4A");
    assert_eq!(
        songs
            .iter()
            .find(|s| s.file_name == "03 Untouched.mp3")
            .unwrap()
            .bpm,
        None
    );
    assert_eq!(
        songs.iter().find(|s| s.folder == "sub").unwrap().file_name,
        "02 Dragonborn.mp3"
    );
    // A later rescan keeps the analysis.
    db.replace_songs(
        lib.id,
        "/Music/Liked",
        &[song("/Music/Liked/01 Loser.mp3", 1000, Some("Loser"))],
    )
    .unwrap();
    assert_eq!(
        db.songs(None)
            .unwrap()
            .iter()
            .map(|s| s.bpm)
            .collect::<Vec<_>>(),
        vec![Some(83.0)]
    );
}

#[test]
fn saves_earmarks_song_analysis_without_overwriting_phase0() {
    let db = LibraryDatabase::open(None, false).unwrap();
    let lib = db.add_library("music", "/Music/Liked", None).unwrap();
    db.replace_songs(
        lib.id,
        "/Music/Liked",
        &[
            song("/Music/Liked/a.mp3", 1, None),
            song("/Music/Liked/b.mp3", 2, None),
            song("/Music/Liked/c.mp3", 3, None),
        ],
    )
    .unwrap();
    let songs = db.songs(None).unwrap();
    let phase0 = phase0::Entry {
        path: Some("/Music/Liked/b.mp3".into()),
        file_name: "b.mp3".into(),
        size: Some(2),
        title: None,
        artist: None,
        analysis: SongAnalysis {
            bpm: Some(90.0),
            source: "Phase 0".into(),
            ..Default::default()
        },
    };
    db.apply_song_analysis(&[phase0]).unwrap();
    let ours = SongAnalysis {
        key: Some(MusicKey::new(9, true)),
        key_confidence: Some(0.8),
        source: SongAnalysis::EARMARK_SOURCE.into(),
        ..Default::default()
    };
    let mut results: Vec<(i64, SongAnalysis)> = songs
        .iter()
        .map(|s| (s.id.unwrap(), ours.clone()))
        .collect();
    results.push((
        songs[2].id.unwrap(),
        SongAnalysis {
            source: "Earmark".into(),
            ..Default::default()
        },
    ));
    let updated = db.save_song_analysis(&results).unwrap();
    // b keeps Phase 0's; c is updated only once.
    assert_eq!(
        updated
            .iter()
            .map(|s| s.file_name.as_str())
            .collect::<Vec<_>>(),
        ["a.mp3", "c.mp3"]
    );
    let songs = db.songs(None).unwrap();
    assert_eq!(
        songs
            .iter()
            .map(|s| s.analysis_source.as_deref())
            .collect::<Vec<_>>(),
        [Some("Earmark"), Some("Phase 0"), Some("Earmark")]
    );
    assert_eq!(songs[1].bpm, Some(90.0));
    assert_eq!(songs[0].key_confidence, Some(0.8));
}

#[test]
fn opens_a_file_and_reopens_it_read_only() {
    let dir = temp_dir("db-file");
    let path = dir.join("Earmark/library.sqlite");
    {
        let db = LibraryDatabase::open(Some(&path), false).unwrap();
        db.add_library("sounds", "/Lib", None).unwrap();
    }
    let ro = LibraryDatabase::open(Some(&path), true).unwrap();
    assert_eq!(ro.libraries(Some("sounds")).unwrap().len(), 1);
    assert!(ro.add_library("music", "/Music", None).is_err());
    assert!(LibraryDatabase::open(Some(&dir.join("none.sqlite")), true).is_err());
    // Opening again doesn't migrate twice.
    LibraryDatabase::open(Some(&path), false).unwrap();
}

#[test]
fn facts_and_embeddings_follow_the_sound() {
    use earmark_db::{SoundEmbedding, SoundFacts};
    let db = LibraryDatabase::open(None, false).unwrap();
    let root = temp_dir("db-analysis");
    let r = root_str(&root);
    write(&root, "a.wav", &wav(1.0, 48000, &[]));
    write(&root, "b.wav", &wav(2.0, 48000, &[]));
    let lib = db.add_library("sounds", &r, None).unwrap();
    db.replace_sounds(lib.id, &r, &scanned(&root)).unwrap();
    let sounds = db.sounds(None).unwrap();
    let (a, b) = (&sounds[0], &sounds[1]);
    let fact = |s: &earmark_db::SoundRecord, loudness| SoundFacts {
        sound_id: s.id.unwrap(),
        fingerprint: s.fingerprint.clone(),
        version: SoundFacts::CURRENT_VERSION,
        loudness: Some(loudness),
        peak: Some(-1.0),
        error: None,
        analyzed_at: "2026-10-29 12:00:00.000".into(),
    };
    db.save_facts(&[fact(a, -20.0)]).unwrap();
    db.save_facts(&[fact(a, -18.5), fact(b, -30.0)]).unwrap(); // saving again replaces
    let facts = db.sound_facts().unwrap();
    assert_eq!(facts.len(), 2);
    assert_eq!(facts[&a.id.unwrap()].loudness, Some(-18.5));

    let embedding =
        |s: &earmark_db::SoundRecord, fingerprint: Option<String>, v: &[f32]| SoundEmbedding {
            sound_id: s.id.unwrap(),
            model: "clap-general".into(),
            fingerprint,
            version: SoundEmbedding::version_of("clap-general"),
            vector: Some(SoundEmbedding::bytes(v)),
            error: None,
            analyzed_at: "2026-10-29 12:00:00.000".into(),
        };
    // b's vector was made from other content: it doesn't count.
    db.save_embeddings(&[
        embedding(a, a.fingerprint.clone(), &[0.5, -1.25]),
        embedding(b, Some("old".into()), &[1.0, 2.0]),
    ])
    .unwrap();
    assert_eq!(
        db.vectors("clap-general").unwrap(),
        vec![(a.id.unwrap(), vec![0.5, -1.25])]
    );
    assert_eq!(db.embedding_status("clap-general").unwrap().len(), 2);
    assert_eq!(
        db.embedding(b.id.unwrap(), "clap-general")
            .unwrap()
            .unwrap()
            .fingerprint
            .as_deref(),
        Some("old")
    );
    assert!(
        db.embedding(b.id.unwrap(), "pe-av-large")
            .unwrap()
            .is_none()
    );
}

/// The sound map's vectors: sounds with a current vector from every model, in id order.
#[test]
fn vectors_from_several_models_come_together() {
    use earmark_db::SoundEmbedding;
    let db = LibraryDatabase::open(None, false).unwrap();
    let root = temp_dir("db-vectors");
    let r = root_str(&root);
    for (i, name) in ["a.wav", "b.wav", "c.wav"].iter().enumerate() {
        write(&root, name, &wav((i + 1) as f64, 48000, &[]));
    }
    let lib = db.add_library("sounds", &r, None).unwrap();
    db.replace_sounds(lib.id, &r, &scanned(&root)).unwrap();
    let mut s = db.sounds(None).unwrap();
    s.sort_by_key(|x| x.id);
    let e = |i: usize, model: &str, v: &[f32]| SoundEmbedding {
        sound_id: s[i].id.unwrap(),
        model: model.into(),
        fingerprint: s[i].fingerprint.clone(),
        version: 1,
        vector: Some(SoundEmbedding::bytes(v)),
        error: None,
        analyzed_at: "2026-10-29 12:00:00.000".into(),
    };
    db.save_embeddings(&[
        e(2, "pe-av-large", &[3.0, 3.0, 3.0]),
        e(2, "clap-general", &[3.0]),
        e(0, "pe-av-large", &[1.0, 1.0, 1.0]),
        e(0, "clap-general", &[1.0]),
        e(1, "pe-av-large", &[2.0, 2.0, 2.0]), // no CLAP
    ])
    .unwrap();
    let (mut count, mut got) = (0, Vec::new());
    db.for_each_vectors(
        &["pe-av-large", "clap-general"],
        None,
        &mut |n| count = n,
        &mut |id, v| got.push((id, v)),
    )
    .unwrap();
    assert_eq!(count, 2);
    assert_eq!(
        got.iter().map(|g| g.0).collect::<Vec<_>>(),
        [s[0].id.unwrap(), s[2].id.unwrap()]
    );
    assert_eq!(got[0].1, vec![vec![1.0, 1.0, 1.0], vec![1.0]]);
    let mut only = Vec::new();
    db.for_each_vectors(
        &["pe-av-large"],
        Some(&[s[1].id.unwrap()]),
        &mut |_| {},
        &mut |id, _| only.push(id),
    )
    .unwrap();
    assert_eq!(only, [s[1].id.unwrap()]);
}
