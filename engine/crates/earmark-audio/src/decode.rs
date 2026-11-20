//! Decodes a file, opened read-only, to float samples. Port of `AudioDecoder.swift` over Symphonia
//! instead of AVFoundation: channels averaged, at most `max_seconds` from the start, resampled
//! (`Resampler`). Streams, so a long 96 kHz file never sits in memory at its original rate.

use crate::resample::Resampler;
use earmark_core::metadata::AudioTechnical;
use std::fs::File;
use std::path::Path;
use symphonia::core::codecs::audio::well_known::CODEC_ID_MP3;
use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum AudioError {
    Open(String),
    UnsupportedFormat(String),
    Decode(String),
}

impl std::fmt::Display for AudioError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AudioError::Open(why) => write!(f, "couldn't open the file: {why}"),
            AudioError::UnsupportedFormat(why) => write!(f, "unsupported audio format: {why}"),
            AudioError::Decode(why) => write!(f, "couldn't decode the file: {why}"),
        }
    }
}

impl std::error::Error for AudioError {}

/// A whole file at its own rate, channels interleaved.
#[derive(Clone, Debug, PartialEq)]
pub struct Decoded {
    pub sample_rate: u32,
    pub channels: usize,
    pub samples: Vec<f32>,
}

/// Reads a file block by block.
pub struct Reader {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track: u32,
    pub sample_rate: u32,
    pub channels: usize,
    /// Frames in the file, if it says.
    pub frames: Option<u64>,
    bad_packets: usize,
    is_mp3: bool,
    first_packet: bool,
    /// Frames still to drop from the start, and silence still to give at the end.
    skip: usize,
    pad: usize,
}

/// An MP3 decoder's own delay. A file with a gapless tag has it trimmed by the tag; for one
/// without, Apple's decoder removes it and keeps the file's length, so its audio starts here.
const MP3_DELAY: usize = 529;

impl Reader {
    pub fn open(path: &Path) -> Result<Reader, AudioError> {
        let file = File::open(path).map_err(|e| AudioError::Open(e.to_string()))?;
        let stream = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(extension) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(extension);
        }
        let format = symphonia::default::get_probe()
            .probe(
                &hint,
                stream,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(|e| AudioError::UnsupportedFormat(e.to_string()))?;
        let track = format
            .default_track(TrackType::Audio)
            .ok_or_else(|| AudioError::UnsupportedFormat("no audio track".into()))?;
        let id = track.id;
        let frames = track.num_frames;
        let params = track
            .codec_params
            .as_ref()
            .and_then(|c| c.audio())
            .ok_or_else(|| AudioError::UnsupportedFormat("no audio parameters".into()))?;
        let is_mp3 = params.codec == CODEC_ID_MP3;
        let sample_rate = params.sample_rate.unwrap_or(0);
        let channels = params.channels.as_ref().map_or(0, |c| c.count());
        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(params, &AudioDecoderOptions::default())
            .map_err(|e| AudioError::UnsupportedFormat(e.to_string()))?;
        Ok(Reader {
            format,
            decoder,
            track: id,
            sample_rate,
            channels,
            frames,
            bad_packets: 0,
            is_mp3,
            first_packet: true,
            skip: 0,
            pad: 0,
        })
    }

    /// The next block's samples, interleaved, into `out` (replacing what's there); false at the
    /// end. Rates and channel counts the file's first packets don't state are taken from them.
    pub fn next_block(&mut self, out: &mut Vec<f32>) -> Result<bool, AudioError> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => return Ok(self.silence(out)),
                Err(Error::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                    return Ok(self.silence(out));
                }
                Err(e) => return Err(AudioError::Decode(e.to_string())),
            };
            if packet.track_id != self.track {
                continue;
            }
            if self.first_packet {
                self.first_packet = false;
                if self.is_mp3 && packet.trim_start.is_zero() {
                    self.skip = MP3_DELAY;
                    self.pad = MP3_DELAY;
                }
            }
            match self.decoder.decode(&packet) {
                Ok(block) => {
                    let spec = block.spec();
                    self.sample_rate = spec.rate();
                    self.channels = spec.channels().count();
                    out.resize(block.samples_interleaved(), 0.0);
                    block.copy_to_slice_interleaved(out.as_mut_slice());
                    let drop = self.skip.min(out.len() / self.channels.max(1));
                    if drop > 0 {
                        out.drain(..drop * self.channels);
                        self.skip -= drop;
                        if out.is_empty() {
                            continue;
                        }
                    }
                    return Ok(true);
                }
                // A damaged packet: on to the next, as players do.
                Err(Error::DecodeError(_)) => {
                    self.bad_packets += 1;
                    if self.bad_packets > 1000 {
                        return Err(AudioError::Decode("too many damaged packets".into()));
                    }
                }
                Err(e) => return Err(AudioError::Decode(e.to_string())),
            }
        }
    }

    /// The last block, when the start was dropped: the file keeps its length.
    fn silence(&mut self, out: &mut Vec<f32>) -> bool {
        let frames = std::mem::take(&mut self.pad);
        out.clear();
        out.resize(frames * self.channels, 0.0);
        frames > 0
    }

    /// The rest of the file, interleaved.
    pub fn read_all(mut self) -> Result<Decoded, AudioError> {
        let mut samples = Vec::new();
        let mut block = Vec::new();
        while self.next_block(&mut block)? {
            samples.extend_from_slice(&block);
        }
        Ok(Decoded {
            sample_rate: self.sample_rate,
            channels: self.channels,
            samples,
        })
    }
}

/// Mono float32 at `target` Hz: channels averaged, at most `max_seconds` from the start.
pub fn mono(path: &Path, target: u32, max_seconds: f64) -> Result<Vec<f32>, AudioError> {
    let mut reader = Reader::open(path)?;
    let mut block = Vec::new();
    let mut out = Vec::new();
    let mut resampler: Option<Resampler> = None;
    let mut left: Option<u64> = None;
    let mut mixed = Vec::new();
    while reader.next_block(&mut block)? {
        let channels = reader.channels.max(1);
        let rate = reader.sample_rate;
        if rate == 0 {
            return Err(AudioError::UnsupportedFormat("no sample rate".into()));
        }
        let remaining = left.get_or_insert((max_seconds * f64::from(rate)) as u64);
        let frames = (block.len() / channels).min(*remaining as usize);
        *remaining -= frames as u64;
        mixed.clear();
        let scale = 1.0 / channels as f32;
        mixed.extend(block.chunks_exact(channels).take(frames).map(|frame| {
            if channels == 1 {
                frame[0]
            } else {
                frame.iter().sum::<f32>() * scale
            }
        }));
        if rate == target {
            out.extend_from_slice(&mixed);
        } else {
            resampler
                .get_or_insert_with(|| Resampler::new(rate, target))
                .process(&mixed, &mut out);
        }
        if *remaining == 0 {
            break;
        }
    }
    if let Some(mut r) = resampler {
        r.finish(&mut out);
    }
    Ok(out)
}

/// The length and format of a file the metadata reader can't parse (MP3, AAC, FLAC…), for the
/// scanner (`scan::TechnicalReader`). Counts the frames by decoding when the file doesn't say.
pub fn technical(path: &Path) -> Option<AudioTechnical> {
    let mut reader = Reader::open(path).ok()?;
    let mut frames = reader.frames;
    if frames.is_none() {
        let mut block = Vec::new();
        let mut counted = 0u64;
        while reader.next_block(&mut block).ok()? {
            counted += (block.len() / reader.channels.max(1)) as u64;
        }
        frames = Some(counted);
    }
    let rate = f64::from(reader.sample_rate);
    Some(AudioTechnical {
        sample_rate: (rate > 0.0).then_some(rate),
        channels: (reader.channels > 0).then_some(reader.channels as i64),
        bits_per_sample: None,
        duration: frames.filter(|_| rate > 0.0).map(|f| f as f64 / rate),
    })
}
