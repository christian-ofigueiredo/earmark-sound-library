//! The Swift tests for folder suggestions, category votes, song corrections and the music maths
//! (AnalysisTests.swift's FolderRuleTests, SoundCategoryTests, SongCorrectionTests, MusicAnalysisTests).

use earmark_core::analysis::categories::{self, Vote, disagrees, votes};
use earmark_core::analysis::folder_rules::{self, GUESS_SOURCE, Tuning, suggest_from};
use earmark_core::analysis::music;
use earmark_core::analysis::similarity::SimilarityIndex;
use earmark_core::metadata::AudioTechnical;
use earmark_core::music_key::MusicKey;
use earmark_core::normalize::NormalizedMetadata;
use earmark_core::records::{SongRecord, SoundRecord};
use earmark_core::scan::ScannedSound;
use earmark_core::song_corrections::SongEdit;
use earmark_core::ucs::UcsCatalog;
use std::collections::{BTreeMap, HashMap, HashSet};

fn record(path: &str, details: Option<&str>) -> SoundRecord {
    let scanned = ScannedSound {
        path: path.into(),
        file_size: 1,
        modified: 0.0,
        fingerprint: None,
        technical: AudioTechnical::default(),
        metadata: NormalizedMetadata::default(),
        warnings: vec![],
    };
    let mut s = SoundRecord::from_scan(1, "/L", &scanned);
    s.details = details.map(str::to_string);
    s
}

fn top(folder: &str, files: &[(&str, f64)], pack: &[&str]) -> Vec<folder_rules::Suggestion> {
    let files: BTreeMap<String, f64> = files.iter().map(|(w, v)| (w.to_string(), *v)).collect();
    let pack: HashSet<String> = pack.iter().map(|w| w.to_string()).collect();
    suggest_from(
        folder,
        &[],
        None,
        &HashMap::new(),
        &files,
        &pack,
        3,
        &Tuning::default(),
    )
}

fn first(folder: &str) -> Option<String> {
    top(folder, &[], &[])
        .first()
        .map(|o| o.entry.cat_id.clone())
}

#[test]
fn folder_names_point_to_ucs() {
    let best = |folder: &str| {
        let scores = folder_rules::name_scores(folder);
        let mut v: Vec<(&String, &(f64, Vec<String>))> = scores.iter().collect();
        v.sort_by(|a, b| b.1.0.partial_cmp(&a.1.0).unwrap().then(a.0.cmp(b.0)));
        v.first().and_then(|(k, _)| {
            UcsCatalog::shared()
                .entry_by_cat_id(Some(k))
                .map(|e| e.category.clone())
        })
    };
    assert_eq!(
        best("Sound Ideas - The SFX KIT Disk [Wav] MERRY XMAS 2022/TSK-03/Footsteps/Concrete")
            .as_deref(),
        Some("FOOTSTEPS")
    );
    assert_eq!(
        best("Sound Ideas - The SFX KIT Disk [Wav] MERRY XMAS 2022/TSK-06/Crowds").as_deref(),
        Some("CROWDS")
    );
    let words: Vec<String> = folder_rules::folder_words("Pack/TSK-01/Automobiles")
        .into_iter()
        .map(|w| w.0)
        .collect();
    assert_eq!(words, ["automobile"]);
}

#[test]
fn parent_folder_decides_the_category_and_synonyms_the_subcategory() {
    assert_eq!(
        first("Pack/TSK-03/Footsteps/Metal - Steel").as_deref(),
        Some("FEETHmn")
    );
    assert_eq!(
        first("Pack/TSK-03/Footsteps/Concrete").as_deref(),
        Some("FEETHmn")
    );
    assert_eq!(first("Pack/TSK-01/Automobiles").as_deref(), Some("VEHMisc"));
    assert_eq!(first("Pack/TSK-06/Crowds").as_deref(), Some("CRWDMisc"));
}

#[test]
fn words_are_spelled_as_ucs_spells_them() {
    let w = folder_rules::words;
    assert_eq!(w("StreetBall_HitPad2"), ["street", "ball", "hit", "pad"]);
    assert!(
        w("Sci-Fi Loops").contains(&"scifi".to_string())
            && !w("Sci-Fi Loops").contains(&"loop".to_string())
    );
    assert!(w("SCI FI WEAPONS").contains(&"scifi".to_string()));
    assert!(w("Powerful Braaams").contains(&"braam".to_string()));
    assert_eq!(w("Whooshes & Glitches, Boxes"), ["whoosh", "glitch", "box"]);
    assert!(
        w("Zombies").contains(&"zombie".to_string())
            && w("Batteries").contains(&"battery".to_string())
    );
    assert!(w("MA_SoundsByGFXSounds_CameraShutter").contains(&"camera".to_string()));
}

#[test]
fn vendor_names_count_only_when_the_sound_agrees() {
    let with_pack = top("Boom.Library.Neon", &[("whoosh", 0.6)], &["boom"]);
    assert_ne!(
        with_pack.first().map(|o| o.entry.cat_id.as_str()),
        Some("DSGNBoom")
    );
    assert_eq!(first("Boom.Library.Neon").as_deref(), Some("DSGNBoom"));
    let tube = top(
        "Lens Distortions - Anticipation SFX/WAV/01 - Risers/Risers - Tube",
        &[],
        &[],
    );
    assert_eq!(tube[0].entry.cat_id, "DSGNRise");
    assert!(!tube.iter().any(|o| o.entry.cat_id == "DSGNDist"));
}

#[test]
fn a_parent_category_locks_materials_but_not_another_subject() {
    let t = |folder: &str, files: &[(&str, f64)]| {
        top(folder, files, &[])
            .first()
            .map(|o| o.entry.cat_id.clone())
    };
    assert_eq!(
        t("Pack/TSK-03/Footsteps/Snow - Crunchy", &[]).as_deref(),
        Some("FEETHmn")
    );
    assert_eq!(
        t("Pack/Monsters & Creatures/Creature Footsteps", &[]).as_deref(),
        Some("FEETCrea")
    );
    assert_eq!(
        t(
            "Pack/Human Vocal Full Sets/Male_LongSet_A",
            &[("male", 1.0), ("grunt", 0.5)]
        )
        .as_deref(),
        Some("VOXMale")
    );
    assert_eq!(
        t(
            "Pack/TSK-03/Footsteps/Leaves",
            &[("foot", 1.0), ("leaf", 1.0), ("leave", 1.0)]
        )
        .as_deref(),
        Some("FEETHmn")
    );
    assert_eq!(
        t(
            "Pack/TSK-03/Footsteps/Snow - Crunchy",
            &[("foot", 1.0), ("snow", 1.0), ("crunchy", 1.0)]
        )
        .as_deref(),
        Some("FEETHmn")
    );
    assert_eq!(
        t(
            "Pack/TSK-03/Footsteps/Glass",
            &[("foot", 1.0), ("glass", 1.0)]
        )
        .as_deref(),
        Some("FEETHmn")
    );
    assert_eq!(
        t(
            "Pack/TSK-03/Footsteps/Wood - Hollow Deck",
            &[("foot", 1.0), ("wood", 1.0)]
        )
        .as_deref(),
        Some("FEETHmn")
    );
    let gears = top("Pack/Mechanical", &[], &[]);
    assert_eq!(gears[0].entry.category, "MECHANICAL");
    assert_ne!(gears.last().unwrap().entry.category, "MECHANICAL");
}

#[test]
fn the_files_decide_when_the_name_is_vague() {
    let hockey = top(
        "Pack/TSK-06/Hockey",
        &[("hockey", 1.0), ("skating", 0.5), ("ice", 0.4)],
        &[],
    );
    assert_eq!(hockey[0].entry.cat_id, "SPRTWntr");
    assert!(hockey[0].file_words.contains(&"skating".to_string()));
}

#[test]
fn file_words_skip_vendor_parts_and_keep_common_words() {
    let catalog = UcsCatalog::shared();
    let ucs: Vec<SoundRecord> = (1..=4)
        .map(|i| {
            record(&format!("/L/Pack/Hits/DSGNImpt_Metal Hit {i}_Ocular Sounds_Deep Impacts_The Complete Ambiences Collection.wav"), None)
        })
        .collect();
    let words = folder_rules::file_words(&ucs, &HashSet::new(), catalog, &Tuning::default());
    assert_eq!(
        (words.get("metal"), words.get("hit")),
        (Some(&1.0), Some(&1.0))
    );
    assert!(!words.contains_key("ambience") && !words.contains_key("ocular"));
    let shared: Vec<SoundRecord> = (1..=4)
        .map(|i| {
            record(
                &format!("/L/Pack/Hits/Hockey_Puck{i}.wav"),
                Some("Sports & Recreation"),
            )
        })
        .collect();
    let w2 = folder_rules::file_words(
        &shared,
        &HashSet::from(["Sports & Recreation".to_string()]),
        catalog,
        &Tuning::default(),
    );
    assert_eq!(w2.get("hockey"), Some(&1.0));
    assert!(w2.get("sport").copied().unwrap_or(0.0) < 0.5);
}

#[test]
fn vague_names_are_flagged_and_archived_is_never_suggested() {
    assert!(top("Pack/TSK-02/Pickups", &[], &[])[0].is_uncertain);
    assert!(!top("Pack/TSK-03/Footsteps/Metal - Steel", &[], &[])[0].is_uncertain);
    assert!(
        !top("Pack/Scene Sequences", &[], &[])
            .iter()
            .any(|o| o.entry.category == "ARCHIVED")
    );
    assert_eq!(first("Pack/Rain").as_deref(), Some("RAIN"));
}

#[test]
fn sound_picks_the_subcategory_when_the_name_only_gives_the_category() {
    let v = |x: f32, y: f32| {
        let n = (x * x + y * y).sqrt();
        vec![x / n, y / n]
    };
    let index = SimilarityIndex::new(&[
        (1, v(1.0, 0.1)),
        (2, v(1.0, 0.12)),
        (10, v(1.0, 0.11)),
        (11, v(1.0, 0.09)),
        (20, v(0.0, 1.0)),
    ]);
    let labels: HashMap<i64, String> = [(10, "FEETHmn"), (11, "FEETHmn"), (20, "WHSHSwsh")]
        .into_iter()
        .map(|(k, v)| (k, v.to_string()))
        .collect();
    let options = suggest_from(
        "Pack/Footsteps",
        &[1, 2],
        Some(&index),
        &labels,
        &BTreeMap::new(),
        &HashSet::new(),
        3,
        &Tuning::default(),
    );
    assert_eq!(options[0].entry.cat_id, "FEETHmn");
    assert!(options[0].sound_share > 0.5);
}

// MARK: categories

fn sound(id: i64, cat_id: Option<&str>, source: Option<&str>) -> SoundRecord {
    let e = cat_id.and_then(|c| UcsCatalog::shared().entry_by_cat_id(Some(c)));
    let mut s = record(&format!("/L/Pack/Misc/s{id}.wav"), None);
    s.id = Some(id);
    s.fingerprint = Some(format!("f{id}"));
    s.cat_id = e.map(|e| e.cat_id.clone());
    s.category = e.map(|e| e.category.clone());
    s.subcategory = e.map(|e| e.subcategory.clone());
    s.category_source = source.map(str::to_string);
    s
}

#[test]
fn nearest_sounds_in_other_folders_vote() {
    let raw = [1.0f32, 0.0, 0.99, 0.14, 0.98, 0.2, 0.97, 0.24, 0.6, 0.8];
    let unit: Vec<f32> = raw
        .chunks(2)
        .flat_map(|p| {
            let l = (p[0] * p[0] + p[1] * p[1]).sqrt();
            [p[0] / l, p[1] / l]
        })
        .collect();
    let labels: Vec<Option<String>> = ["FEETHmn", "FEETHmn", "DOORWood", "DOORWood", "GUNAuto"]
        .iter()
        .map(|s| Some(s.to_string()))
        .collect();
    let folders: Vec<String> = ["a", "a", "b", "c", "d"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let v = votes(&unit, 5, 2, &labels, &folders, 3, 5, &|| false).unwrap();
    assert_eq!(v[0][0].cat_id, "DOORWood");
    assert!(!v[0].iter().any(|x| x.cat_id == "FEETHmn"));
    assert!((v[0].iter().map(|x| x.share).sum::<f64>() - 1.0).abs() < 1e-9);
    assert!(disagrees(&v[0], Some("FEETHmn"), 0.6, 0.1));
    assert!(!disagrees(&v[0], Some("DOORWood"), 0.6, 0.1));
}

#[test]
fn earmark_guesses_only_among_the_folders_runners_up() {
    let sounds = [
        sound(1, Some("FEETHmn"), Some(GUESS_SOURCE)),
        sound(2, Some("FEETHmn"), Some(GUESS_SOURCE)),
        sound(3, Some("FEETHmn"), Some("UCS filename")),
    ];
    let vote = vec![
        Vote {
            cat_id: "DOORWood".into(),
            share: 0.8,
        },
        Vote {
            cat_id: "FEETHmn".into(),
            share: 0.05,
        },
    ];
    let all = [
        vote.clone(),
        vec![Vote {
            cat_id: "GUNAuto".into(),
            share: 0.9,
        }],
        vote,
    ];
    let alternatives =
        |_: &SoundRecord| HashSet::from(["DOORWood".to_string(), "FEETCrea".to_string()]);
    let g = categories::guesses(&sounds, &all, &alternatives, 0.6, 0.1, "now");
    assert_eq!(g.iter().map(|x| x.sound_id).collect::<Vec<_>>(), [1]);
    assert!(
        g[0].cat_id == "DOORWood" && g[0].replaced.as_deref() == Some("FEETHmn") && !g[0].by_owner
    );
}

// MARK: song corrections

fn b_minor() -> MusicKey {
    MusicKey::new(11, true)
}

fn song(bpm: Option<f64>, key: Option<MusicKey>, beats: Option<i64>) -> SongRecord {
    SongRecord {
        id: Some(1),
        library_id: 1,
        path: "/Music/a.mp3".into(),
        file_name: "a.mp3".into(),
        folder: String::new(),
        file_size: 1,
        modified_at: "1970-01-01 00:00:00.000".into(),
        title: None,
        artist: None,
        album: None,
        duration: None,
        bpm,
        bpm_low: bpm.map(|b| b - 0.5),
        bpm_high: bpm.map(|b| b + 0.5),
        tempo_stability: Some("steady".into()),
        beats_per_bar: beats,
        key_pitch_class: key.map(|k| k.pitch_class as i64),
        key_minor: key.map(|k| k.minor),
        key_confidence: None,
        analysis_source: Some("Phase 0".into()),
        analysed: None,
        correction: None,
    }
}

fn analysed_song() -> SongRecord {
    song(Some(61.75), Some(b_minor()), Some(4))
}

fn edit(s: &SongRecord, e: SongEdit) -> SongRecord {
    s.applying(s.correction_after(e, "now").as_ref())
}

#[test]
fn double_then_halve_goes_back_to_the_analysis() {
    let s = analysed_song();
    let doubled = edit(&s, SongEdit::DoubleTempo);
    assert_eq!(
        (doubled.bpm, doubled.bpm_low, doubled.bpm_high),
        (Some(123.5), Some(122.5), Some(124.5))
    );
    assert_eq!(doubled.analysed.as_ref().unwrap().bpm, Some(61.75));
    assert!(
        doubled.correction.as_ref().unwrap().corrects_tempo()
            && !doubled.correction.as_ref().unwrap().corrects_key()
    );
    assert_eq!(doubled.key(), Some(b_minor()));
    let back = edit(&doubled, SongEdit::HalveTempo);
    assert_eq!(back, s);
}

#[test]
fn typed_tempo_drops_the_range() {
    let s = edit(&analysed_song(), SongEdit::SetTempo(120.0));
    assert_eq!((s.bpm, s.bpm_low, s.bpm_high), (Some(120.0), None, None));
    assert_eq!(s.uncorrected().bpm_low, Some(61.25));
    assert!(edit(&s, SongEdit::SetTempo(61.75)).correction.is_none());
}

#[test]
fn relative_key_twice_is_no_correction() {
    let s = edit(&analysed_song(), SongEdit::RelativeKey);
    assert_eq!(s.key(), Some(MusicKey::new(2, false)));
    assert_eq!(s.key().unwrap().camelot(), "10B");
    assert!(edit(&s, SongEdit::RelativeKey).correction.is_none());
}

#[test]
fn parts_are_corrected_and_reverted_on_their_own() {
    let mut s = edit(&analysed_song(), SongEdit::SetKey(MusicKey::new(9, true)));
    s = edit(&s, SongEdit::SetBeatsPerBar(3));
    s = edit(&s, SongEdit::DoubleTempo);
    assert_eq!(
        (s.key().unwrap().name(), s.beats_per_bar, s.bpm),
        ("A minor".to_string(), Some(3), Some(123.5))
    );
    s = edit(&s, SongEdit::RevertKey);
    assert_eq!(
        (s.key(), s.beats_per_bar, s.bpm),
        (Some(b_minor()), Some(3), Some(123.5))
    );
    s = edit(&s, SongEdit::RevertBeatsPerBar);
    assert_eq!(s.beats_per_bar, Some(4));
    assert!(s.correction.as_ref().unwrap().corrects_tempo());
    assert_eq!(edit(&s, SongEdit::RevertAll), analysed_song());
}

#[test]
fn what_each_edit_allows() {
    let s = analysed_song();
    assert!(!s.allows(SongEdit::RevertAll) && !s.allows(SongEdit::RevertTempo));
    assert!(
        !s.allows(SongEdit::SetKey(b_minor()))
            && s.allows(SongEdit::SetKey(MusicKey::new(0, false)))
    );
    assert!(
        !s.allows(SongEdit::SetBeatsPerBar(4))
            && !s.allows(SongEdit::SetBeatsPerBar(5))
            && s.allows(SongEdit::SetBeatsPerBar(3))
    );
    assert!(
        !song(Some(30.0), None, None).allows(SongEdit::HalveTempo)
            && !song(Some(210.0), None, None).allows(SongEdit::DoubleTempo)
    );
    assert!(!s.allows(SongEdit::SetTempo(10.0)) && s.allows(SongEdit::SetTempo(20.0)));
    let none = song(None, None, None);
    assert!(
        !none.allows(SongEdit::DoubleTempo)
            && !none.allows(SongEdit::RelativeKey)
            && none.allows(SongEdit::SetTempo(90.0))
    );
    assert!(edit(&s, SongEdit::DoubleTempo).allows(SongEdit::RevertTempo));
}

#[test]
fn corrections_dont_count_as_analysis() {
    let mut s = song(None, None, None);
    s.analysis_source = None;
    let set = edit(&s, SongEdit::SetTempo(100.0));
    assert_eq!(set.bpm, Some(100.0));
    assert!(!set.is_analysed());
}

// MARK: music (against Python: models/parity_music.py --fixture)

#[derive(serde::Deserialize)]
struct MusicFixture {
    spectrogram: Spect,
    chunk_starts: BTreeMap<String, Vec<i64>>,
    aggregate: Aggregate,
    songs: Vec<Song>,
    key_labels: Vec<String>,
    half_rate: HalfRate,
}
#[derive(serde::Deserialize)]
struct Spect {
    shape: Vec<usize>,
    index: Vec<usize>,
    values: Vec<f32>,
    mean: f64,
}
#[derive(serde::Deserialize)]
struct Aggregate {
    frames: usize,
    beat: Vec<f32>,
}
#[derive(serde::Deserialize)]
struct Song {
    name: String,
    beat_logits: Vec<f32>,
    downbeat_logits: Vec<f32>,
    peaks: Vec<f64>,
    downbeats: Vec<f64>,
    bpm: Option<f64>,
    bpm_range: Option<Vec<f64>>,
    stability: String,
    beats_per_bar: Option<i64>,
    confidence: f64,
}
#[derive(serde::Deserialize)]
struct HalfRate {
    index: Vec<usize>,
    values: Vec<f32>,
    length: usize,
}

fn fixture() -> MusicFixture {
    serde_json::from_str(include_str!(
        "../../../../app/Tests/EarmarkCoreTests/Fixtures/music_analysis.json"
    ))
    .unwrap()
}

/// The same formula as parity_music.drums().
fn drums(seconds: f64, bpm0: f64, bpm1: f64, per_bar: f64) -> Vec<f32> {
    use std::f64::consts::PI;
    let sr = music::SAMPLE_RATE as f64;
    (0..(seconds * sr) as usize)
        .map(|i| {
            let t = i as f64 / sr;
            let bpm = bpm0 + (bpm1 - bpm0) * t / seconds;
            let phase = (bpm0 * t + 0.5 * (bpm1 - bpm0) * t * t / seconds) / 60.0;
            let k = phase.floor();
            let since = (phase - k) * 60.0 / bpm;
            let eighth = (2.0 * phase - (2.0 * phase).floor()) * 30.0 / bpm;
            let accent = if k % per_bar == 0.0 { 1.0 } else { 0.6 };
            let kick = (2.0 * PI * 55.0 * since).sin() * (-30.0 * since).exp() * accent;
            let snare = if k % 2.0 == 1.0 {
                (2.0 * PI * 1800.0 * since + 40.0 * (2.0 * PI * 370.0 * since).sin()).sin()
            } else {
                0.0
            } * (-40.0 * since).exp()
                * 0.3;
            let hats = (2.0 * PI * 7000.0 * eighth + 30.0 * (2.0 * PI * 1130.0 * eighth).sin())
                .sin()
                * (-80.0 * eighth).exp()
                * 0.15;
            let chord = 0.1 * (2.0 * PI * 220.0 * t).sin() + 0.1 * (2.0 * PI * 277.18 * t).sin();
            (kick + snare + hats + chord) as f32
        })
        .collect()
}

#[test]
fn spectrogram_matches_log_mel_spect() {
    let r = fixture().spectrogram;
    let x = drums(40.0, 123.0, 123.0, 4.0);
    assert_eq!(music::frame_count(x.len()), r.shape[0]);
    let spect = music::spectrogram(&x);
    assert_eq!(spect.len(), r.shape[0] * r.shape[1]);
    let worst = r
        .index
        .iter()
        .zip(&r.values)
        .map(|(&i, v)| (spect[i] - v).abs())
        .fold(0f32, f32::max);
    assert!(worst < 1e-3, "largest difference {worst}");
    let mean = spect.iter().map(|&v| v as f64).sum::<f64>() / spect.len() as f64;
    assert!((mean - r.mean).abs() < 1e-5);
}

#[test]
fn half_rate_filter_matches_scipy() {
    let r = fixture().half_rate;
    let sweep: Vec<f32> = (0..2 * 44_100)
        .map(|i| {
            let t = i as f64 / 44_100.0;
            (0.5 * (2.0 * std::f64::consts::PI * (100.0 * t + 5000.0 * t * t)).sin()) as f32
        })
        .collect();
    let half = music::decimate(&sweep);
    assert_eq!(half.len(), r.length);
    assert!(
        r.index
            .iter()
            .zip(&r.values)
            .all(|(&i, v)| (half[i] - v).abs() < 1e-5)
    );
    assert_eq!(music::decimate(&[1.0, 2.0, 3.0]).len(), 2);
}

#[test]
fn chunks_start_where_split_piece_starts_them() {
    for (n, starts) in fixture().chunk_starts {
        assert_eq!(
            music::chunk_starts(n.parse().unwrap()),
            starts,
            "{n} frames"
        );
    }
}

#[test]
fn chunk_is_zero_outside_the_song() {
    let (n, mels) = (2000usize, music::MELS);
    let spect: Vec<f32> = (0..n * mels).map(|i| (i / mels + 1) as f32).collect();
    let first = music::chunk(&spect, n, -6);
    assert!(first[5 * mels] == 0.0 && first[6 * mels] == 1.0 && first[1499 * mels] == 1494.0);
    let last = music::chunk(&spect, n, n as i64 - 1494);
    assert!(
        last[0] == (n - 1494 + 1) as f32
            && last[1493 * mels] == n as f32
            && last[1494 * mels] == 0.0
    );
}

#[test]
fn aggregate_keeps_the_earlier_chunk() {
    let r = fixture().aggregate;
    let starts = music::chunk_starts(r.frames);
    let outputs: Vec<Vec<f32>> = (0..starts.len())
        .map(|i| {
            (0..music::CHUNK)
                .map(|j| j as f32 + (10_000 * (i + 1)) as f32)
                .collect()
        })
        .collect();
    assert_eq!(music::aggregate(&outputs, &starts, r.frames), r.beat);
}

#[test]
fn tempo_matches_phase0() {
    for song in fixture().songs {
        let (beats, downbeats) = music::peaks(&song.beat_logits, &song.downbeat_logits);
        assert_eq!(beats, song.peaks, "{}", song.name);
        assert_eq!(downbeats, song.downbeats);
        let prob: Vec<f32> = song
            .beat_logits
            .iter()
            .map(|&x| music::sigmoid(x))
            .collect();
        let s = music::summarize(&beats, &downbeats, &prob);
        assert_eq!(s.bpm, song.bpm, "{}", song.name);
        assert_eq!(s.bpm_range.map(|r| vec![r.0, r.1]), song.bpm_range);
        assert_eq!(s.stability, song.stability);
        assert_eq!(s.beats_per_bar, song.beats_per_bar);
        assert!((s.confidence - song.confidence).abs() <= 0.001);
    }
    let few = music::summarize(&[0.5, 1.0, 1.5], &[], &[0.9; 100]);
    assert!(few.bpm.is_none() && few.stability == "no steady beat");
}

#[test]
fn key_labels_follow_skeys_order() {
    let labels: Vec<MusicKey> = fixture()
        .key_labels
        .iter()
        .map(|k| MusicKey::parse(k).unwrap())
        .collect();
    assert_eq!(music::key_labels(), labels.as_slice());
    let mut p = [0.01f32; 24];
    p[22] = 0.7;
    p[3] = 0.2;
    let e = music::estimate_key(&p).unwrap();
    assert_eq!(
        (e.key, e.runner_up),
        (MusicKey::new(9, true), MusicKey::new(0, false))
    );
    assert!(music::estimate_key(&[0.5, 0.5]).is_none());
}
