//! Reading numbers and text out of file headers, and files read-only. Port of `BinaryReading.swift`.

use crate::text::trim;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Bounds-checked readers over a byte slice: out of range gives 0 or "", as in Swift.
pub trait Bytes {
    fn u16_le(&self, at: usize) -> u16;
    fn u32_le(&self, at: usize) -> u32;
    fn u64_le(&self, at: usize) -> u64;
    fn u16_be(&self, at: usize) -> u16;
    fn u32_be(&self, at: usize) -> u32;
    fn f32_le(&self, at: usize) -> f32;
    fn four_cc(&self, at: usize) -> String;
    fn metadata_string(&self, from: usize, to: usize) -> String;
    fn extended80_be(&self, at: usize) -> f64;
}

impl Bytes for [u8] {
    fn u16_le(&self, at: usize) -> u16 {
        self.get(at..at + 2)
            .map_or(0, |b| u16::from_le_bytes([b[0], b[1]]))
    }
    fn u32_le(&self, at: usize) -> u32 {
        self.get(at..at + 4)
            .map_or(0, |b| u32::from_le_bytes(b.try_into().unwrap()))
    }
    fn u64_le(&self, at: usize) -> u64 {
        self.get(at..at + 8)
            .map_or(0, |b| u64::from_le_bytes(b.try_into().unwrap()))
    }
    fn u16_be(&self, at: usize) -> u16 {
        self.get(at..at + 2)
            .map_or(0, |b| u16::from_be_bytes([b[0], b[1]]))
    }
    fn u32_be(&self, at: usize) -> u32 {
        self.get(at..at + 4)
            .map_or(0, |b| u32::from_be_bytes(b.try_into().unwrap()))
    }
    fn f32_le(&self, at: usize) -> f32 {
        f32::from_bits(self.u32_le(at))
    }
    fn four_cc(&self, at: usize) -> String {
        self.get(at..at + 4)
            .map_or(String::new(), |b| String::from_utf8_lossy(b).into_owned())
    }

    /// Text up to the first NUL, trying UTF-8 then Windows-1252, trimmed.
    fn metadata_string(&self, from: usize, to: usize) -> String {
        let hi = to.min(self.len());
        if from >= hi {
            return String::new();
        }
        let mut b = &self[from..hi];
        if let Some(nul) = b.iter().position(|&x| x == 0) {
            b = &b[..nul];
        }
        let s = match std::str::from_utf8(b) {
            Ok(s) => s.to_string(),
            // Foundation falls back to Latin-1 for the five bytes Windows-1252 leaves undefined;
            // WHATWG's Windows-1252 maps those to the same C1 characters.
            Err(_) => encoding_rs::WINDOWS_1252
                .decode_without_bom_handling(b)
                .0
                .into_owned(),
        };
        trim(&s).to_string()
    }

    /// An 80-bit IEEE extended float (AIFF sample rate).
    fn extended80_be(&self, at: usize) -> f64 {
        if self.len() < at + 10 {
            return 0.0;
        }
        let exp_field = self.u16_be(at) as i32;
        let mantissa = ((self.u32_be(at + 2) as u64) << 32) | self.u32_be(at + 6) as u64;
        let sign = if exp_field & 0x8000 != 0 { -1.0 } else { 1.0 };
        let exponent = exp_field & 0x7FFF;
        if exponent == 0 && mantissa == 0 {
            return 0.0;
        }
        sign * mantissa as f64 * 2f64.powi(exponent - 16383 - 63)
    }
}

/// A file read through a read-only handle, without loading it all.
pub struct ReadOnlyFile {
    file: File,
    pub size: u64,
}

impl ReadOnlyFile {
    pub fn open(path: &Path) -> std::io::Result<ReadOnlyFile> {
        let file = File::open(path)?;
        let size = file.metadata()?.len();
        Ok(ReadOnlyFile { file, size })
    }

    /// Up to `count` bytes from `offset` (fewer at the end, none on errors).
    pub fn read(&mut self, offset: u64, count: usize) -> Vec<u8> {
        if offset >= self.size || count == 0 {
            return Vec::new();
        }
        let mut out = Vec::with_capacity(count.min((self.size - offset) as usize));
        if self.file.seek(SeekFrom::Start(offset)).is_err() {
            return Vec::new();
        }
        if (&mut self.file)
            .take(count as u64)
            .read_to_end(&mut out)
            .is_err()
        {
            return Vec::new();
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::Bytes;

    #[test]
    fn numbers_and_text() {
        let b: &[u8] = &[1, 0, 0, 0, b'h', 0xE9, 0, b'x'];
        assert_eq!(b.u32_le(0), 1);
        assert_eq!(b.u32_le(6), 0);
        assert_eq!(b.metadata_string(4, 8), "hé");
        assert_eq!("  caf\u{e9} \n".as_bytes().metadata_string(0, 20), "café");
        // 44100 as an 80-bit float.
        let rate: &[u8] = &[0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0];
        assert_eq!(rate.extended80_be(0), 44100.0);
    }
}
