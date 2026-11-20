//! The plumbing around the models, on tiny stand-ins (models/make_onnx_fixtures.py): the real
//! models are compared with Core ML's results by engine/parity/compare.py.

use earmark_core::analysis::audio;
use earmark_core::analysis::music;
use earmark_models::{
    ClapEmbedder, ClapModelStore, Compute, FileResult, ModelError, MusicAnalyzer, MusicModelStore,
    PeavEmbedder,
};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn tone(seconds: f64, rate: usize) -> Vec<f32> {
    (0..(seconds * rate as f64) as usize)
        .map(|i| (i as f32 * 0.05).sin() * 0.5)
        .collect()
}

fn norm(v: &[f32]) -> f32 {
    v.iter().map(|x| x * x).sum::<f32>().sqrt()
}

#[test]
fn clap_features_go_in_and_a_unit_vector_comes_out() {
    let clap = ClapEmbedder::open(&fixtures().join("CLAPAudio.onnx")).unwrap();
    let features: Vec<f32> = (0..audio::CLAP_FRAMES * audio::CLAP_MELS)
        .map(|i| (i % audio::CLAP_MELS) as f32)
        .collect();
    let e = clap.embed_features(&features).unwrap();
    assert_eq!(e.len(), 512);
    assert!((norm(&e) - 1.0).abs() < 1e-5);
    // Each band's mean, in order: the stand-in's sum, so the features' layout is checked too.
    assert!((e[1] / e[2] - 0.5).abs() < 1e-5);

    let v = clap.embed(&tone(3.0, 48_000)).unwrap().unwrap();
    assert!((norm(&v) - 1.0).abs() < 1e-5);
    assert_eq!(clap.embed(&vec![0.0; 48_000]).unwrap(), None);
    assert_eq!(clap.embed_windows(&[]).unwrap(), None);
}

#[test]
fn models_load_on_demand_and_let_go() {
    let store = ClapModelStore::new(fixtures());
    assert!(store.is_installed() && !store.is_loaded());
    store.get().unwrap();
    assert!(store.is_loaded());
    store.unload();
    assert!(!store.is_loaded());

    let missing = ClapModelStore::new(fixtures().join("nowhere"));
    assert!(!missing.is_installed());
    assert!(matches!(missing.get(), Err(ModelError::NotInstalled(_))));
    assert!(matches!(
        PeavEmbedder::new(fixtures().join("nowhere"), Compute::Cpu),
        Err(ModelError::NotInstalled(_))
    ));

    let music = MusicModelStore::new(fixtures());
    assert!(music.is_installed());
    music.get(Compute::Cpu).unwrap();
    assert!(music.is_loaded());
    music.unload();
    assert!(!music.is_loaded());
}

#[test]
fn peav_runs_its_parts_over_windows_of_any_length() {
    let peav = PeavEmbedder::new(fixtures().join("PEAV"), Compute::Cpu).unwrap();
    let long = PeavEmbedder::windows(&tone(25.0, 48_000));
    let short = PeavEmbedder::windows(&tone(1.5, 48_000));
    assert!(long.len() > 1 && long.iter().all(|w| w.len() == audio::WINDOW_SAMPLES));
    assert!(short.len() == 1 && short[0].len() != audio::WINDOW_SAMPLES);
    let results = peav
        .embed(&[long, Vec::new(), short], &|| false)
        .unwrap()
        .unwrap();
    assert_eq!(results.len(), 3);
    for r in [&results[0], &results[2]] {
        let FileResult::Vector(v) = r else {
            panic!("{r:?}")
        };
        assert_eq!(v.len(), 1024);
        assert!((norm(v) - 1.0).abs() < 1e-5);
    }
    assert_eq!(results[1], FileResult::Silent);
}

#[test]
fn peav_stops_when_asked() {
    let peav = PeavEmbedder::new(fixtures().join("PEAV"), Compute::Cpu).unwrap();
    let windows = PeavEmbedder::windows(&tone(1.5, 48_000));
    let asked = AtomicUsize::new(0);
    let answer = peav
        .embed(&[windows], &|| asked.fetch_add(1, Ordering::Relaxed) >= 2)
        .unwrap();
    assert_eq!(answer, None);
}

#[test]
fn a_song_goes_through_tempo_and_key() {
    let analyzer = MusicAnalyzer::open(&fixtures(), Compute::Cpu).unwrap();
    let sr = music::SAMPLE_RATE;
    let song = tone(45.0, sr);
    let result = analyzer.analyse(&song, &|| false).unwrap().unwrap();
    assert!((result.seconds - 45.0).abs() < 1e-3);
    let key = result.key.unwrap();
    assert_eq!(key.key, music::key_labels()[3]);
    assert!((key.confidence - 0.54).abs() < 1e-5);

    // Too short, silent, or cancelled: nothing.
    assert!(analyzer.analyse(&song[..sr], &|| false).unwrap().is_none());
    assert!(
        analyzer
            .analyse(&vec![0.0; sr * 5], &|| false)
            .unwrap()
            .is_none()
    );
    assert!(analyzer.analyse(&song, &|| true).unwrap().is_none());
    let (beat, downbeat) = analyzer
        .logits(&vec![2.0; music::CHUNK * music::MELS])
        .unwrap();
    assert_eq!((beat.len(), downbeat.len()), (music::CHUNK, music::CHUNK));
    assert!((beat[0] - 2.0).abs() < 1e-5 && (downbeat[0] + 2.0).abs() < 1e-5);
}
