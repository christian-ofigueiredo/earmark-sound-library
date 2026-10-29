//! The Swift MetadataTests (app/Tests/EarmarkCoreTests/CoreTests.swift), with the same test files.

use earmark_core::metadata;
use earmark_core::normalize::{MetadataField::*, is_junk, normalize};
use earmark_core::ucs::UcsCatalog;
use std::path::{Path, PathBuf};

fn chunk(id: &str, body: &[u8]) -> Vec<u8> {
    let mut d = id.as_bytes().to_vec();
    d.extend((body.len() as u32).to_le_bytes());
    d.extend(body);
    if body.len() % 2 == 1 {
        d.push(0);
    }
    d
}

fn fixed(s: &str, n: usize) -> Vec<u8> {
    let mut d: Vec<u8> = s.bytes().take(n).collect();
    d.resize(n, 0);
    d
}

fn bext(description: &str, originator: &str, time_reference: u64) -> Vec<u8> {
    let mut b = fixed(description, 256);
    b.extend(fixed(originator, 32));
    b.extend(fixed("REF", 32));
    b.extend(fixed("2026-01-01", 10));
    b.extend(fixed("12:00:00", 8));
    b.extend(time_reference.to_le_bytes());
    b.resize(602, 0);
    b
}

fn ixml(user: &[(&str, &str)]) -> Vec<u8> {
    let inner: String = user
        .iter()
        .map(|(k, v)| format!("<{k}>{v}</{k}>"))
        .collect();
    format!(r#"<?xml version="1.0" encoding="UTF-8"?><BWFXML><IXML_VERSION>2.1</IXML_VERSION><USER>{inner}</USER></BWFXML>"#)
        .into_bytes()
}

fn info(items: &[(&str, &str)]) -> Vec<u8> {
    let mut b = b"INFO".to_vec();
    for (id, v) in items {
        let mut value = v.as_bytes().to_vec();
        value.push(0);
        b.extend(chunk(id, &value));
    }
    b
}

/// 16-bit mono WAV of silence plus the extra chunks.
fn wav(seconds: f64, sample_rate: u32, extra: &[Vec<u8>]) -> Vec<u8> {
    let mut fmt = Vec::new();
    fmt.extend(1u16.to_le_bytes());
    fmt.extend(1u16.to_le_bytes());
    fmt.extend(sample_rate.to_le_bytes());
    fmt.extend((sample_rate * 2).to_le_bytes());
    fmt.extend(2u16.to_le_bytes());
    fmt.extend(16u16.to_le_bytes());
    let mut body = b"WAVE".to_vec();
    body.extend(chunk("fmt ", &fmt));
    for e in extra {
        body.extend(e);
    }
    body.extend(chunk(
        "data",
        &vec![0; (sample_rate as f64 * seconds) as usize * 2],
    ));
    let mut file = b"RIFF".to_vec();
    file.extend((body.len() as u32).to_le_bytes());
    file.extend(body);
    file
}

fn aiff(seconds: f64, sample_rate: f64, name: &str) -> Vec<u8> {
    let frames = (sample_rate * seconds) as u32;
    let mut comm = Vec::new();
    comm.extend(2u16.to_be_bytes());
    comm.extend(frames.to_be_bytes());
    comm.extend(16u16.to_be_bytes());
    let mut exponent = 16383 + 63;
    let mut mantissa = sample_rate as u64;
    while mantissa & (1 << 63) == 0 {
        mantissa <<= 1;
        exponent -= 1;
    }
    comm.extend((exponent as u16).to_be_bytes());
    comm.extend(mantissa.to_be_bytes());
    let ch = |id: &str, b: &[u8]| {
        let mut d = id.as_bytes().to_vec();
        d.extend((b.len() as u32).to_be_bytes());
        d.extend(b);
        if b.len() % 2 == 1 {
            d.push(0);
        }
        d
    };
    let mut body = b"AIFF".to_vec();
    body.extend(ch("COMM", &comm));
    body.extend(ch("NAME", name.as_bytes()));
    body.extend(ch("SSND", &vec![0; 8 + frames as usize * 4]));
    let mut file = b"FORM".to_vec();
    file.extend((body.len() as u32).to_be_bytes());
    file.extend(body);
    file
}

fn write(dir: &Path, name: &str, data: &[u8]) -> PathBuf {
    let path = dir.join(name);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, data).unwrap();
    path
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "earmark-engine-tests-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn reads_soundminer_style_wav() {
    let dir = temp_dir("soundminer");
    let path = write(
        &dir,
        "Pack/Some Whoosh.wav",
        &wav(
            0.5,
            48000,
            &[
                chunk(
                    "bext",
                    &bext("Deep whoosh, bext text", "Vendor Co", 1_728_000_000),
                ),
                chunk(
                    "iXML",
                    &ixml(&[
                        ("CATID", "WHSH"),
                        ("FXNAME", "Deep Whoosh 01"),
                        ("DESCRIPTION", "Deep whoosh from iXML"),
                        ("KEYWORDS", "whoosh, deep"),
                    ]),
                ),
                chunk(
                    "LIST",
                    &info(&[("INAM", "Info title"), ("IGNR", "Sound Clip")]),
                ),
            ],
        ),
    );
    let raw = metadata::read(&path);
    assert_eq!(raw.container.as_deref(), Some("RIFF"));
    assert_eq!(raw.technical.sample_rate, Some(48000.0));
    assert_eq!(raw.technical.channels, Some(1));
    assert!((raw.technical.duration.unwrap() - 0.5).abs() < 0.001);
    assert_eq!(raw.bext["Originator"], "Vendor Co");
    assert_eq!(raw.ixml["BWFXML/USER/CATID"], "WHSH");
    assert_eq!(metadata::time_reference(&path), 1_728_000_000);
    let n = normalize(&raw, &path, UcsCatalog::shared());
    let ucs = n.ucs.as_ref().unwrap();
    assert_eq!(ucs.cat_id, "WHSH");
    assert!(ucs.source.starts_with("iXML"));
    assert_eq!(n.get(Description), Some("Deep whoosh from iXML"));
    assert_eq!(n.get(FxName), Some("Deep Whoosh 01"));
    assert_eq!(n.get(Manufacturer), Some("Vendor Co"));
    assert_eq!(n.get(Category), Some("SWOOSHES"));
}

#[test]
fn ignores_junk_descriptions() {
    let dir = temp_dir("junk");
    let path = write(
        &dir,
        "Clicks_01.wav",
        &wav(
            0.5,
            48000,
            &[chunk(
                "LIST",
                &info(&[("ICMT", "www.example-download-site.com")]),
            )],
        ),
    );
    let n = normalize(&metadata::read(&path), &path, UcsCatalog::shared());
    assert_eq!(n.get(Description), None);
    assert!(is_junk("GET MORE ASSETS - SOMEWHERE"));
    assert!(is_junk("0000007D6750434D2D44313030000000000000"));
    assert!(!is_junk("Metallic strike with a long ring-out."));
}

#[test]
fn reads_aiff() {
    let dir = temp_dir("aiff");
    let path = write(&dir, "tone.aif", &aiff(1.0, 44100.0, "Tone A"));
    let raw = metadata::read(&path);
    assert_eq!(raw.container.as_deref(), Some("AIFF"));
    assert_eq!(raw.technical.sample_rate, Some(44100.0));
    assert!((raw.technical.duration.unwrap() - 1.0).abs() < 0.001);
    assert_eq!(raw.aiff["Title"], "Tone A");
    assert_eq!(metadata::time_reference(&path), 0);
}

#[test]
fn ucs_from_filename_when_no_chunks() {
    let dir = temp_dir("filename");
    let path = write(
        &dir,
        "DSGNImpt_Low Thud 03_SLAB_PackB.wav",
        &wav(0.5, 48000, &[]),
    );
    let n = normalize(&metadata::read(&path), &path, UcsCatalog::shared());
    assert_eq!(n.ucs.as_ref().map(|u| u.cat_id.as_str()), Some("DSGNImpt"));
    assert_eq!(
        n.ucs.as_ref().map(|u| u.source.as_str()),
        Some("UCS filename")
    );
    assert_eq!(n.get(FxName), Some("Low Thud 03"));
}

#[test]
fn ucs_from_folder_name() {
    let dir = temp_dir("folder");
    let path = write(&dir, "WHSH/Takes/whoosh 1.wav", &wav(0.1, 48000, &[]));
    let n = normalize(&metadata::read(&path), &path, UcsCatalog::shared());
    assert_eq!(
        n.ucs.map(|u| u.source),
        Some("folder name 'WHSH'".to_string())
    );
}
