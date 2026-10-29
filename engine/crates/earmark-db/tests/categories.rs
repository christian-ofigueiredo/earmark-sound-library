//! The Swift database tests for folder rules and guesses, per-sound categories and song
//! corrections (FolderRuleTests, SoundCategoryTests, SongCorrectionTests).

#[path = "../../earmark-core/tests/common/mod.rs"]
mod common;

use common::*;
use earmark_core::analysis::categories::{
    self, OWNER_SOURCE, SOUND_GUESS_SOURCE, SoundCategoryChoice,
};
use earmark_core::analysis::folder_rules::{self, FolderGuess, FolderRule, GUESS_SOURCE, SOURCE};
use earmark_core::music_key::MusicKey;
use earmark_core::phase0::{Entry, SongAnalysis};
use earmark_core::records::SoundRecord;
use earmark_core::scan::scan;
use earmark_core::song_corrections::{self, SongEdit};
use earmark_core::ucs::UcsCatalog;
use earmark_db::{LibraryDatabase, SongFile};
use std::collections::HashMap;

fn library(name: &str, files: &[&str]) -> (LibraryDatabase, i64) {
    let db = LibraryDatabase::open(None, false).unwrap();
    let root = temp_dir(name);
    for (i, f) in files.iter().enumerate() {
        write(&root, f, &wav((i + 1) as f64, 48000, &[]));
    }
    let r = root.to_string_lossy().into_owned();
    let lib = db.add_library("sounds", &r, None).unwrap();
    db.replace_sounds(
        lib.id,
        &r,
        &scan(&root, UcsCatalog::shared(), 4, None, &|_, _| {}),
    )
    .unwrap();
    (db, lib.id)
}

fn named<'a>(sounds: &'a [SoundRecord], name: &str) -> &'a SoundRecord {
    sounds.iter().find(|s| s.file_name == name).unwrap()
}

#[test]
fn rules_fill_only_uncategorised_sounds_from_the_nearest_folder() {
    let (db, lib) = library(
        "rules",
        &[
            "Pack/Footsteps/Concrete/a.wav",
            "Pack/Footsteps/b.wav",
            "Pack/Footsteps/WHSH_Vendor_X_Y.wav",
            "Other/c.wav",
        ],
    );
    db.save_folder_rules(&[FolderRule {
        library_id: lib,
        folder: "Pack/Footsteps".into(),
        cat_id: "FEETHmn".into(),
        created_at: "now".into(),
    }])
    .unwrap();
    let sounds = folder_rules::apply(
        &db.folder_rules().unwrap(),
        &[],
        &db.sounds(None).unwrap(),
        UcsCatalog::shared(),
    );
    assert_eq!(named(&sounds, "a.wav").cat_id.as_deref(), Some("FEETHmn"));
    assert_eq!(
        named(&sounds, "a.wav").category_source.as_deref(),
        Some(SOURCE)
    );
    assert_eq!(
        named(&sounds, "b.wav").category.as_deref(),
        Some("FOOTSTEPS")
    );
    assert_eq!(
        named(&sounds, "WHSH_Vendor_X_Y.wav").cat_id.as_deref(),
        Some("WHSH")
    );
    assert_eq!(named(&sounds, "c.wav").cat_id, None);
    db.remove_folder_rule(lib, "Pack/Footsteps").unwrap();
    assert!(db.folder_rules().unwrap().is_empty());
}

#[test]
fn guesses_fill_what_neither_files_nor_the_owner_categorised() {
    let (db, lib) = library(
        "guesses",
        &[
            "Pack/Hits/a.wav",
            "Pack/Hits/Metal/b.wav",
            "Pack/Whooshes/c.wav",
            "Pack/Whooshes/WHSH_Vendor_X_Y.wav",
        ],
    );
    let guess = |folder: &str, cat: &str| FolderGuess {
        library_id: lib,
        folder: folder.into(),
        cat_id: cat.into(),
        alternatives: "DSGNMisc".into(),
        reason: "test".into(),
        is_unsure: false,
        analysed: 0,
        version: folder_rules::SUGGESTER_VERSION,
        created_at: "now".into(),
    };
    db.update_guesses(
        &[
            guess("Pack/Hits/Metal", "METLImpt"),
            guess("Pack/Whooshes", "DSGNWhsh"),
        ],
        &[],
    )
    .unwrap();
    db.save_folder_rules(&[FolderRule {
        library_id: lib,
        folder: "Pack/Hits".into(),
        cat_id: "DSGNImpt".into(),
        created_at: "now".into(),
    }])
    .unwrap();
    let apply = || {
        folder_rules::apply(
            &db.folder_rules().unwrap(),
            &db.folder_guesses().unwrap(),
            &db.sounds(None).unwrap(),
            UcsCatalog::shared(),
        )
    };
    let sounds = apply();
    assert_eq!(named(&sounds, "a.wav").cat_id.as_deref(), Some("DSGNImpt"));
    assert_eq!(
        named(&sounds, "b.wav").cat_id.as_deref(),
        Some("DSGNImpt"),
        "a choice above beats a guess below"
    );
    assert_eq!(named(&sounds, "c.wav").cat_id.as_deref(), Some("DSGNWhsh"));
    assert_eq!(
        named(&sounds, "c.wav").category_source.as_deref(),
        Some(GUESS_SOURCE)
    );
    assert_eq!(
        named(&sounds, "WHSH_Vendor_X_Y.wav").cat_id.as_deref(),
        Some("WHSH")
    );
    let whooshes = db
        .folder_guesses()
        .unwrap()
        .into_iter()
        .find(|g| g.folder == "Pack/Whooshes")
        .unwrap();
    assert_eq!(whooshes.alternative_ids(), ["DSGNMisc"]);
    // Removing the choice brings the guess back; a stale guess is forgotten.
    db.remove_folder_rule(lib, "Pack/Hits").unwrap();
    db.update_guesses(&[], &[(lib, "Pack/Whooshes".into())])
        .unwrap();
    let after = apply();
    assert_eq!(named(&after, "b.wav").cat_id.as_deref(), Some("METLImpt"));
    assert_eq!(named(&after, "c.wav").cat_id, None);
    // Labels for the sound signal leave out both kinds of folder category.
    let labels: Vec<String> = folder_rules::labels(&sounds).into_values().collect();
    assert_eq!(labels, ["WHSH"]);
}

fn categorised(db_sounds: &[SoundRecord], id: i64, cat: &str, source: &str) -> SoundRecord {
    let mut s = db_sounds.iter().find(|s| s.id == Some(id)).unwrap().clone();
    let e = UcsCatalog::shared().entry_by_cat_id(Some(cat)).unwrap();
    s.fingerprint = Some(format!("f{id}"));
    s.cat_id = Some(e.cat_id.clone());
    s.category = Some(e.category.clone());
    s.subcategory = Some(e.subcategory.clone());
    s.category_source = Some(source.into());
    s
}

#[test]
fn owners_choices_win_earmarks_replace_only_folder_guesses() {
    let (db, _) = library(
        "choices",
        &["Pack/Misc/s1.wav", "Pack/Misc/s2.wav", "Pack/Misc/s3.wav"],
    );
    let base = db.sounds(None).unwrap();
    let ids: Vec<i64> = base.iter().map(|s| s.id.unwrap()).collect();
    let sounds = vec![
        categorised(&base, ids[0], "FEETHmn", GUESS_SOURCE),
        categorised(&base, ids[1], "FEETHmn", "UCS filename"),
        categorised(&base, ids[2], "FEETHmn", GUESS_SOURCE),
    ];
    let guess = |id: i64| SoundCategoryChoice {
        sound_id: id,
        fingerprint: Some(format!("f{id}")),
        cat_id: "DOORWood".into(),
        by_owner: false,
        share: None,
        replaced: None,
        version: 1,
        created_at: "now".into(),
    };
    db.replace_sound_guesses(&[guess(ids[0]), guess(ids[1])])
        .unwrap();
    db.set_sound_category(
        &[
            (ids[2], Some(format!("f{}", ids[2]))),
            (ids[1], Some(format!("f{}", ids[1]))),
        ],
        Some("GUNAuto"),
    )
    .unwrap();
    let applied = categories::apply(
        &db.sound_category_choices().unwrap(),
        &sounds,
        UcsCatalog::shared(),
    );
    assert_eq!(
        applied
            .iter()
            .map(|s| s.cat_id.clone().unwrap())
            .collect::<Vec<_>>(),
        ["DOORWood", "GUNAuto", "GUNAuto"]
    );
    assert_eq!(
        applied
            .iter()
            .map(|s| s.category_source.clone().unwrap())
            .collect::<Vec<_>>(),
        [SOUND_GUESS_SOURCE, OWNER_SOURCE, OWNER_SOURCE]
    );
    // New guesses leave the owner's alone, and say whether anything changed.
    assert!(
        !db.replace_sound_guesses(&[guess(ids[0]), guess(ids[2])])
            .unwrap()
    );
    assert!(db.sound_category_choices().unwrap()[&ids[2]].by_owner);
    // The owner takes theirs back; a changed file loses Earmark's.
    db.set_sound_category(&[(ids[1], Some(format!("f{}", ids[1])))], None)
        .unwrap();
    let mut changed = sounds.clone();
    changed[0].fingerprint = Some("new".into());
    let applied = categories::apply(
        &db.sound_category_choices().unwrap(),
        &changed,
        UcsCatalog::shared(),
    );
    assert_eq!(
        applied
            .iter()
            .map(|s| s.cat_id.clone().unwrap())
            .collect::<Vec<_>>(),
        ["FEETHmn", "FEETHmn", "GUNAuto"]
    );
}

#[test]
fn corrections_survive_rescans_imports_analysis_and_re_adding() {
    let db = LibraryDatabase::open(None, false).unwrap();
    let mut lib = db.add_library("music", "/Music/Liked", None).unwrap();
    let file = |p: &str, size: i64| SongFile {
        path: p.into(),
        file_size: size,
        modified: 0.0,
        title: None,
        artist: None,
        album: None,
        duration: None,
    };
    let files = [file("/Music/Liked/a.mp3", 1), file("/Music/Liked/b.mp3", 2)];
    db.replace_songs(lib.id, "/Music/Liked", &files).unwrap();
    let b_minor = MusicKey::new(11, true);
    let import = |bpm: f64| Entry {
        path: Some("/Music/Liked/a.mp3".into()),
        file_name: "a.mp3".into(),
        size: Some(1),
        title: None,
        artist: None,
        analysis: SongAnalysis {
            bpm: Some(bpm),
            key: Some(b_minor),
            source: "Phase 0".into(),
            ..Default::default()
        },
    };
    db.apply_song_analysis(&[import(61.75)]).unwrap();
    let shown = || {
        let c: HashMap<String, _> = db
            .song_corrections()
            .unwrap()
            .into_iter()
            .map(|c| (c.path.clone(), c))
            .collect();
        song_corrections::apply(&c, &db.songs(None).unwrap())
    };
    let a = shown()[0].clone();
    let b = shown()[1].clone();
    db.set_song_corrections(&[
        (
            a.path.clone(),
            a.correction_after(SongEdit::DoubleTempo, "now"),
        ),
        (
            b.path.clone(),
            b.correction_after(SongEdit::SetTempo(90.0), "now"),
        ),
    ])
    .unwrap();
    let a = shown()[0].clone();
    assert_eq!((a.bpm, a.uncorrected().bpm), (Some(123.5), Some(61.75)));
    assert_eq!(db.songs(None).unwrap()[0].bpm, Some(61.75)); // the stored analysis is untouched
    // A rescan, a new Phase 0 import and Earmark's own analysis leave it alone.
    db.replace_songs(lib.id, "/Music/Liked", &files).unwrap();
    db.apply_song_analysis(&[import(62.0)]).unwrap();
    let second = db.songs(None).unwrap()[1].id.unwrap();
    db.save_song_analysis(&[(
        second,
        SongAnalysis {
            bpm: Some(45.0),
            source: "Earmark".into(),
            ..Default::default()
        },
    )])
    .unwrap();
    assert_eq!(
        shown().iter().map(|s| s.bpm).collect::<Vec<_>>(),
        [Some(123.5), Some(90.0)]
    );
    assert_eq!(shown()[1].uncorrected().bpm, Some(45.0));
    // Removed and added again.
    db.remove_library(lib.id).unwrap();
    lib = db.add_library("music", "/Music/Liked", None).unwrap();
    db.replace_songs(lib.id, "/Music/Liked", &files).unwrap();
    assert_eq!(
        shown().iter().map(|s| s.bpm).collect::<Vec<_>>(),
        [Some(123.5), Some(90.0)]
    );
    // Reverting removes it.
    db.set_song_corrections(&[(a.path.clone(), None)]).unwrap();
    assert_eq!(
        db.song_corrections()
            .unwrap()
            .iter()
            .map(|c| c.path.as_str())
            .collect::<Vec<_>>(),
        ["/Music/Liked/b.mp3"]
    );
}
