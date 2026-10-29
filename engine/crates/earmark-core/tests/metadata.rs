//! The Swift MetadataTests (app/Tests/EarmarkCoreTests/CoreTests.swift), with the same test files.

use earmark_core::metadata;
use earmark_core::normalize::{MetadataField::*, is_junk, normalize};
use earmark_core::ucs::UcsCatalog;
mod common;

use common::*;

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
