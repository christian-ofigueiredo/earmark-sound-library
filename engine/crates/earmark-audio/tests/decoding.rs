//! Files read into samples, from WAVs written here. Compared with Apple's decoder on real files
//! by engine/parity/compare.py decode.

use earmark_audio::{AudioError, Reader, mono, technical};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

fn wav(format: u16, bits: u16, channels: u16, rate: u32, data: &[u8]) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("earmark-audio-{}-{n}.wav", std::process::id()));
    let mut f = Vec::new();
    f.extend_from_slice(b"RIFF");
    f.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    f.extend_from_slice(b"WAVEfmt ");
    f.extend_from_slice(&16u32.to_le_bytes());
    f.extend_from_slice(&format.to_le_bytes());
    f.extend_from_slice(&channels.to_le_bytes());
    f.extend_from_slice(&rate.to_le_bytes());
    let block = channels * bits / 8;
    f.extend_from_slice(&(rate * u32::from(block)).to_le_bytes());
    f.extend_from_slice(&block.to_le_bytes());
    f.extend_from_slice(&bits.to_le_bytes());
    f.extend_from_slice(b"data");
    f.extend_from_slice(&(data.len() as u32).to_le_bytes());
    f.extend_from_slice(data);
    std::fs::write(&path, f).unwrap();
    path
}

fn pcm16(samples: &[i16]) -> Vec<u8> {
    samples.iter().flat_map(|s| s.to_le_bytes()).collect()
}

#[test]
fn sample_formats_scale_as_apples() {
    let path = wav(1, 16, 1, 48000, &pcm16(&[0, 16384, -32768, 32767]));
    let d = Reader::open(&path).unwrap().read_all().unwrap();
    assert_eq!((d.sample_rate, d.channels), (48000, 1));
    assert_eq!(d.samples, [0.0, 0.5, -1.0, 32767.0 / 32768.0]);
    std::fs::remove_file(path).unwrap();

    // 24-bit: 0x400000 is a half.
    let path = wav(1, 24, 1, 48000, &[0, 0, 0x40, 0, 0, 0xC0]);
    let d = Reader::open(&path).unwrap().read_all().unwrap();
    assert_eq!(d.samples, [0.5, -0.5]);
    std::fs::remove_file(path).unwrap();

    // 32-bit float comes through untouched.
    let data: Vec<u8> = [0.25f32, -0.75]
        .iter()
        .flat_map(|x| x.to_le_bytes())
        .collect();
    let path = wav(3, 32, 1, 48000, &data);
    let d = Reader::open(&path).unwrap().read_all().unwrap();
    assert_eq!(d.samples, [0.25, -0.75]);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn channels_are_averaged_and_the_length_limited() {
    let frames: Vec<i16> = (0..48000).flat_map(|_| [16384i16, 0]).collect();
    let path = wav(1, 16, 2, 48000, &pcm16(&frames));
    let all = mono(&path, 48000, 600.0).unwrap();
    assert_eq!(all.len(), 48000);
    assert!(all.iter().all(|&x| x == 0.25));
    assert_eq!(mono(&path, 48000, 0.5).unwrap().len(), 24000);

    // Resampled: the length follows, whole samples.
    let at_44 = mono(&path, 44100, 600.0).unwrap();
    assert_eq!(at_44.len(), 44100);
    assert!((at_44[22050] - 0.25).abs() < 1e-4);
    assert_eq!(mono(&path, 44100, 0.5).unwrap().len(), 22050);

    let t = technical(&path).unwrap();
    assert_eq!((t.sample_rate, t.channels), (Some(48000.0), Some(2)));
    assert_eq!(t.duration, Some(1.0));
    std::fs::remove_file(path).unwrap();
}

#[test]
fn what_cant_be_read_says_so() {
    let path = std::env::temp_dir().join(format!("earmark-audio-{}-none.wav", std::process::id()));
    assert!(matches!(mono(&path, 48000, 1.0), Err(AudioError::Open(_))));
    std::fs::write(&path, b"this is not audio at all, not even a little").unwrap();
    assert!(matches!(
        mono(&path, 48000, 1.0),
        Err(AudioError::UnsupportedFormat(_))
    ));
    assert_eq!(technical(&path), None);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn the_file_isnt_touched() {
    let frames: Vec<i16> = (0..4800).map(|i| i as i16).collect();
    let path = wav(1, 16, 1, 44100, &pcm16(&frames));
    let before = std::fs::read(&path).unwrap();
    let modified = std::fs::metadata(&path).unwrap().modified().unwrap();
    mono(&path, 48000, 600.0).unwrap();
    technical(&path).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(
        std::fs::metadata(&path).unwrap().modified().unwrap(),
        modified
    );
    std::fs::remove_file(path).unwrap();
}
