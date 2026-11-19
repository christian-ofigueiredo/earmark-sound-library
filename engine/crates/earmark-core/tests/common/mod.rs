//! Builds small WAV and AIFF files with metadata chunks for tests, as the Swift TestFiles.swift.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

pub fn chunk(id: &str, body: &[u8]) -> Vec<u8> {
    let mut d = id.as_bytes().to_vec();
    d.extend((body.len() as u32).to_le_bytes());
    d.extend(body);
    if body.len() % 2 == 1 {
        d.push(0);
    }
    d
}

pub fn fixed(s: &str, n: usize) -> Vec<u8> {
    let mut d: Vec<u8> = s.bytes().take(n).collect();
    d.resize(n, 0);
    d
}

pub fn bext(description: &str, originator: &str, time_reference: u64) -> Vec<u8> {
    let mut b = fixed(description, 256);
    b.extend(fixed(originator, 32));
    b.extend(fixed("REF", 32));
    b.extend(fixed("2026-01-01", 10));
    b.extend(fixed("12:00:00", 8));
    b.extend(time_reference.to_le_bytes());
    b.resize(602, 0);
    b
}

pub fn ixml(user: &[(&str, &str)]) -> Vec<u8> {
    let inner: String = user
        .iter()
        .map(|(k, v)| format!("<{k}>{v}</{k}>"))
        .collect();
    format!(r#"<?xml version="1.0" encoding="UTF-8"?><BWFXML><IXML_VERSION>2.1</IXML_VERSION><USER>{inner}</USER></BWFXML>"#)
        .into_bytes()
}

pub fn info(items: &[(&str, &str)]) -> Vec<u8> {
    let mut b = b"INFO".to_vec();
    for (id, v) in items {
        let mut value = v.as_bytes().to_vec();
        value.push(0);
        b.extend(chunk(id, &value));
    }
    b
}

/// 16-bit mono WAV of silence plus the extra chunks.
pub fn wav(seconds: f64, sample_rate: u32, extra: &[Vec<u8>]) -> Vec<u8> {
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

pub fn aiff(seconds: f64, sample_rate: f64, name: &str) -> Vec<u8> {
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

pub fn write(dir: &Path, name: &str, data: &[u8]) -> PathBuf {
    let path = dir.join(name);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, data).unwrap();
    path
}

pub fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "earmark-engine-tests-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
