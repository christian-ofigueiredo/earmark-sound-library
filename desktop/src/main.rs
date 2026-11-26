//! Earmark for Windows and Linux (docs/rust-engine-plan.md, step 9), drawn with egui on wgpu and
//! winit: no web window. The Rust engine reads the libraries, keeps the database, searches, groups
//! and maps the sounds; this app draws them and plays the files.
//!
//! `--check` runs the window's calls without the window on the database EARMARK_DATABASE names (a
//! copy); `--analyse` runs the analysis without the window; `--shot file.png [--select] [--music]
//! [--map] [--light|--dark] [--settings]` opens the window, saves what it draws and quits (for checking on a computer where the
//! window can't be driven).

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod analysis;
mod backend;
mod frame;
mod player;
// The family theme, shared as it is with the other apps (Offload keeps the original).
mod theme;
mod ui;

use backend::{Backend, Scope};
use std::sync::atomic::AtomicBool;

fn check() -> Result<(), String> {
    let back = Backend::open()?;
    let started = std::time::Instant::now();
    let snap = back.snapshot()?;
    println!(
        "snapshot: {} libraries, {} sounds, {} songs, {} analysed, {} in duplicates, {} categories ({:?})",
        snap.libraries.len(),
        snap.sounds,
        snap.songs,
        snap.analysed,
        snap.duplicates,
        snap.categories.len(),
        started.elapsed()
    );
    let all = back.sounds(&Scope::All, "")?;
    println!(
        "all sounds: {} — first: {:?}",
        all.len(),
        all.iter().take(3).map(|r| &r.name).collect::<Vec<_>>()
    );
    println!("“door”: {} sounds", back.sounds(&Scope::All, "door")?.len());
    for c in ["DOORS", "DOORWood"] {
        println!(
            "{c}: {} sounds",
            back.sounds(&Scope::Category(c.into()), "")?.len()
        );
    }
    println!(
        "duplicates: {} sounds",
        back.sounds(&Scope::Duplicates, "")?.len()
    );
    if let Some(first) = all.first() {
        let details = back.tool("get_sound", serde_json::json!({ "sound_id": first.id }))?;
        println!(
            "get_sound {}: {}",
            first.id,
            details.to_string().chars().take(160).collect::<String>()
        );
        let similar = back.tool(
            "find_similar",
            serde_json::json!({ "sound_id": first.id, "limit": 3 }),
        )?;
        let names: Vec<&str> = similar["similar"]
            .as_array()
            .map(|a| a.iter().filter_map(|r| r["name"].as_str()).collect())
            .unwrap_or_default();
        println!("find_similar {}: {names:?}", first.id);
    }
    let songs = back.songs(&Scope::All, "")?;
    println!(
        "songs: {} — first: {:?}",
        songs.len(),
        songs.first().map(|s| (&s.title, s.bpm, &s.key))
    );
    let started = std::time::Instant::now();
    let map = back.sound_map(Some("DOORS".into()))?;
    println!(
        "map of DOORS: {} points ({:?})",
        map.points.len(),
        started.elapsed()
    );
    Ok(())
}

fn analyse() -> Result<String, String> {
    let back = Backend::open()?;
    drop(back);
    let path = earmark_mcp::default_database_path();
    let db = std::sync::Mutex::new(
        earmark_db::LibraryDatabase::open(Some(&path), false).map_err(backend::error)?,
    );
    let stop = AtomicBool::new(false);
    let report = |what: &str, done: usize, total: usize| {
        if done == total || done.is_multiple_of(10) {
            println!("{what}: {done} of {total}");
        }
    };
    let progress = analysis::Progress {
        report: &report,
        stop: &stop,
    };
    analysis::run(&db, &path, &progress)
}

fn icon() -> egui::IconData {
    let image = image::load_from_memory(include_bytes!("../assets/icon.png"))
        .map(|i| i.to_rgba8())
        .ok();
    match image {
        Some(i) => egui::IconData {
            width: i.width(),
            height: i.height(),
            rgba: i.into_raw(),
        },
        None => egui::IconData::default(),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let has = |flag: &str| args.iter().any(|a| a == flag);
    if has("--check") {
        if let Err(e) = check() {
            eprintln!("earmark --check: {e}");
            std::process::exit(1);
        }
        return;
    }
    if has("--analyse") {
        match analyse() {
            Ok(said) => println!("{said}"),
            Err(e) => {
                eprintln!("earmark --analyse: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    let shot = args
        .iter()
        .position(|a| a == "--shot")
        .and_then(|i| args.get(i + 1))
        .map(|p| {
            let mut shot = ui::Shot::new(p.into(), has("--select"), has("--music"), has("--map"));
            shot.theme = if has("--light") {
                Some(ui::Appearance::Light)
            } else if has("--dark") {
                Some(ui::Appearance::Dark)
            } else {
                None
            };
            shot.settings = has("--settings");
            shot
        });
    let size = args
        .iter()
        .position(|a| a == "--size")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.split_once('x'))
        .and_then(|(w, h)| Some([w.parse().ok()?, h.parse().ok()?]))
        .unwrap_or([1400.0, 900.0]);

    let back = match Backend::open() {
        Ok(b) => b,
        Err(e) => {
            rfd::MessageDialog::new()
                .set_title("Earmark")
                .set_description(format!("Earmark couldn't open its database: {e}"))
                .show();
            std::process::exit(1);
        }
    };
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Earmark")
            .with_app_id("io.github.christian_ofigueiredo.earmark")
            .with_inner_size(size)
            .with_min_inner_size([1100.0, 620.0])
            .with_icon(icon()),
        centered: true,
        ..Default::default()
    };
    let result = eframe::run_native(
        "Earmark",
        options,
        Box::new(move |cc| Ok(Box::new(ui::EarmarkApp::new(cc, back, shot)))),
    );
    if let Err(e) = result {
        eprintln!("Earmark couldn't start: {e}");
        std::process::exit(1);
    }
}
