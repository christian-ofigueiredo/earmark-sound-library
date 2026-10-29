//! A read-only reader for WAV/BWF/RF64/BW64 and AIFF metadata chunks. Audio data is skipped,
//! never loaded. Other formats give an empty result. Port of `MetadataReader.swift`.

use crate::bytes::{Bytes, ReadOnlyFile};
use crate::xml;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

/// Technical facts from the file header.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioTechnical {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample_rate: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channels: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bits_per_sample: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcidInfo {
    pub one_shot: bool,
    pub tempo: f64,
    pub beats: i64,
}

/// Everything read from the file's metadata chunks, before normalising.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawMetadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
    #[serde(rename = "chunkIDs")]
    pub chunk_ids: Vec<String>,
    pub bext: HashMap<String, String>,
    pub ixml: HashMap<String, String>,
    pub xmp: HashMap<String, String>,
    pub info: HashMap<String, String>,
    pub aiff: HashMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub acid: Option<AcidInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub loop_count: Option<i64>,
    pub technical: AudioTechnical,
    pub warnings: Vec<String>,
}

const MAX_METADATA_CHUNK: u64 = 16 * 1024 * 1024;

fn info_name(id: &str) -> &str {
    match id {
        "INAM" => "Title",
        "IART" => "Artist",
        "ICMT" => "Comment",
        "ICOP" => "Copyright",
        "ICRD" => "DateCreated",
        "IGNR" => "Genre",
        "IKEY" => "Keywords",
        "IPRD" => "Product",
        "ISBJ" => "Subject",
        "ISFT" => "Software",
        "ISRC" => "Source",
        "ITRK" => "Track",
        "IENG" => "Engineer",
        "ITCH" => "Technician",
        other => other,
    }
}

pub fn read(path: &Path) -> RawMetadata {
    let mut raw = RawMetadata::default();
    let Ok(mut file) = ReadOnlyFile::open(path) else {
        raw.warnings.push("could not open file".into());
        return raw;
    };
    let header = file.read(0, 12);
    if header.len() != 12 {
        return raw;
    }
    let (magic, form) = (header.four_cc(0), header.four_cc(8));
    if ["RIFF", "RF64", "BW64"].contains(&magic.as_str()) && form == "WAVE" {
        read_wav(&mut file, magic, &mut raw);
    } else if magic == "FORM" && (form == "AIFF" || form == "AIFC") {
        read_aiff(&mut file, form, &mut raw);
    }
    raw
}

/// A WAV's BWF time reference: where its audio starts in its own timecode, in samples since
/// midnight (0 without a `bext` chunk).
pub fn time_reference(path: &Path) -> i64 {
    let Ok(mut file) = ReadOnlyFile::open(path) else {
        return 0;
    };
    let header = file.read(0, 12);
    if header.len() != 12
        || !["RIFF", "RF64", "BW64"].contains(&header.four_cc(0).as_str())
        || header.four_cc(8) != "WAVE"
    {
        return 0;
    }
    let mut pos = 12u64;
    while pos + 8 <= file.size {
        let h = file.read(pos, 8);
        if h.len() != 8 {
            break;
        }
        let size = h.u32_le(4) as u64;
        match h.four_cc(0).as_str() {
            "bext" => {
                let body = file.read(pos + 8, 346);
                return if body.len() == 346 {
                    i64::try_from(body.u64_le(338)).unwrap_or(i64::MAX)
                } else {
                    0
                };
            }
            "data" => break,
            _ => {}
        }
        pos += 8 + size + (size & 1);
    }
    0
}

fn read_wav(file: &mut ReadOnlyFile, magic: String, raw: &mut RawMetadata) {
    raw.container = Some(magic);
    let mut pos = 12u64;
    let mut ds64_data_size: Option<u64> = None;
    let mut data_size: Option<u64> = None;
    let mut block_align = 0u64;
    let mut sample_rate = 0.0;
    while pos + 8 <= file.size {
        let h = file.read(pos, 8);
        if h.len() != 8 {
            break;
        }
        let id = h.four_cc(0);
        let mut size = h.u32_le(4) as u64;
        if id == "data"
            && size == 0xFFFF_FFFF
            && let Some(real) = ds64_data_size
        {
            size = real;
        }
        if pos + 8 + size > file.size {
            raw.warnings
                .push(format!("chunk '{id}' runs past the end of the file"));
            size = file.size - pos - 8;
        }
        raw.chunk_ids.push(id.clone());
        if id == "data" {
            data_size = Some(size);
        } else if size <= MAX_METADATA_CHUNK {
            let body = file.read(pos + 8, size as usize);
            match id.as_str() {
                "ds64" => {
                    if body.len() >= 16 {
                        ds64_data_size = Some(body.u64_le(8));
                    }
                }
                "fmt " => {
                    if body.len() >= 16 {
                        raw.technical.channels = Some(body.u16_le(2) as i64);
                        sample_rate = body.u32_le(4) as f64;
                        raw.technical.sample_rate = Some(sample_rate);
                        block_align = body.u16_le(12) as u64;
                        raw.technical.bits_per_sample = Some(body.u16_le(14) as i64);
                    }
                }
                "bext" => raw.bext = decode_bext(&body),
                "iXML" | "IXML" => raw.ixml = xml::flatten(&body),
                "_PMX" | "XMP " => raw.xmp = xml::flatten(&body),
                "LIST" => {
                    if body.four_cc(0) == "INFO" {
                        for (k, v) in decode_info(&body) {
                            raw.info.entry(k).or_insert(v);
                        }
                    }
                }
                "acid" => {
                    if body.len() >= 24 {
                        raw.acid = Some(AcidInfo {
                            one_shot: body.u32_le(0) & 1 != 0,
                            tempo: body.f32_le(20) as f64,
                            beats: body.u32_le(12) as i64,
                        });
                    }
                }
                "smpl" if body.len() >= 36 => {
                    raw.loop_count = Some(body.u32_le(28) as i64);
                }
                _ => {}
            }
        } else {
            raw.warnings
                .push(format!("skipped very large '{id}' chunk"));
        }
        pos += 8 + size + (size & 1);
    }
    if let Some(d) = data_size
        && block_align > 0
        && sample_rate > 0.0
    {
        raw.technical.duration = Some((d / block_align) as f64 / sample_rate);
    }
}

pub fn decode_bext(b: &[u8]) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut put = |key: &str, value: String| {
        if !value.is_empty() {
            out.insert(key.to_string(), value);
        }
    };
    put("Description", b.metadata_string(0, 256));
    put("Originator", b.metadata_string(256, 288));
    put("OriginatorReference", b.metadata_string(288, 320));
    put("OriginationDate", b.metadata_string(320, 330));
    put("OriginationTime", b.metadata_string(330, 338));
    if b.len() > 602 {
        put("CodingHistory", b.metadata_string(602, b.len()));
    }
    out
}

fn decode_info(b: &[u8]) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut pos = 4usize;
    while pos + 8 <= b.len() {
        let id = b.four_cc(pos);
        let size = b.u32_le(pos + 4) as usize;
        let value = b.metadata_string(pos + 8, pos + 8 + size);
        if !value.is_empty() {
            out.insert(info_name(&id).to_string(), value);
        }
        pos += 8 + size + (size & 1);
    }
    out
}

fn read_aiff(file: &mut ReadOnlyFile, form: String, raw: &mut RawMetadata) {
    raw.container = Some(form);
    let mut pos = 12u64;
    while pos + 8 <= file.size {
        let h = file.read(pos, 8);
        if h.len() != 8 {
            break;
        }
        let id = h.four_cc(0);
        let size = (h.u32_be(4) as u64).min(file.size - pos - 8);
        raw.chunk_ids.push(id.clone());
        if id != "SSND" && size <= MAX_METADATA_CHUNK {
            let body = file.read(pos + 8, size as usize);
            let text_name = match id.as_str() {
                "NAME" => Some("Title"),
                "AUTH" => Some("Author"),
                "(c) " => Some("Copyright"),
                "ANNO" => Some("Annotation"),
                _ => None,
            };
            if id == "COMM" && body.len() >= 18 {
                let channels = body.u16_be(0) as i16 as i64;
                let frames = body.u32_be(2) as f64;
                let bits = body.u16_be(6) as i16 as i64;
                let rate = body.extended80_be(8);
                raw.technical = AudioTechnical {
                    sample_rate: Some(rate),
                    channels: Some(channels),
                    bits_per_sample: Some(bits),
                    duration: if rate > 0.0 {
                        Some(frames / rate)
                    } else {
                        None
                    },
                };
            } else if let Some(name) = text_name {
                let v = body.metadata_string(0, body.len());
                if !v.is_empty() {
                    raw.aiff.insert(name.to_string(), v);
                }
            } else if id == "iXML" || id == "IXML" {
                raw.ixml = xml::flatten(&body);
            }
        }
        pos += 8 + size + (size & 1);
    }
}
