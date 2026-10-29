//! A musical key: tonic pitch class (C = 0) and mode. Port of `MusicKey.swift`.

use crate::text::trim_spaces;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicKey {
    pub pitch_class: i32,
    pub minor: bool,
}

const MAJOR_NAMES: [&str; 12] = [
    "C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B",
];
const MINOR_NAMES: [&str; 12] = [
    "C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B",
];

fn pitch_class(note: &str) -> Option<i32> {
    Some(match note {
        "C" | "B#" => 0,
        "C#" | "DB" => 1,
        "D" => 2,
        "D#" | "EB" => 3,
        "E" | "FB" => 4,
        "E#" | "F" => 5,
        "F#" | "GB" => 6,
        "G" => 7,
        "G#" | "AB" => 8,
        "A" => 9,
        "A#" | "BB" => 10,
        "B" | "CB" => 11,
        _ => return None,
    })
}

/// The Camelot number of a major key's pitch class.
fn camelot_number(major_pc: i32) -> i32 {
    ((major_pc * 7) % 12 + 7) % 12 + 1
}

impl MusicKey {
    pub fn new(pitch_class: i32, minor: bool) -> MusicKey {
        MusicKey {
            pitch_class: pitch_class.rem_euclid(12),
            minor,
        }
    }

    /// The 24 keys: the major ones from C up, then the minor ones.
    pub fn all() -> Vec<MusicKey> {
        [false, true]
            .iter()
            .flat_map(|&m| (0..12).map(move |pc| MusicKey::new(pc, m)))
            .collect()
    }

    fn names(&self) -> &'static [&'static str; 12] {
        if self.minor {
            &MINOR_NAMES
        } else {
            &MAJOR_NAMES
        }
    }

    /// "A minor", "Bb major".
    pub fn name(&self) -> String {
        format!(
            "{} {}",
            self.names()[self.pitch_class as usize],
            if self.minor { "minor" } else { "major" }
        )
    }

    /// "Am", "Bb".
    pub fn short_name(&self) -> String {
        format!(
            "{}{}",
            self.names()[self.pitch_class as usize],
            if self.minor { "m" } else { "" }
        )
    }

    /// The Camelot wheel code used for harmonic mixing, e.g. "8A" for A minor.
    pub fn camelot(&self) -> String {
        let major_pc = if self.minor {
            (self.pitch_class + 3) % 12
        } else {
            self.pitch_class
        };
        format!(
            "{}{}",
            camelot_number(major_pc),
            if self.minor { "A" } else { "B" }
        )
    }

    /// The relative major or minor (the same notes): the most common key-detection mix-up.
    pub fn relative(&self) -> MusicKey {
        if self.minor {
            MusicKey::new(self.pitch_class + 3, false)
        } else {
            MusicKey::new(self.pitch_class - 3, true)
        }
    }

    /// Camelot neighbours: the same code, ±1 on the wheel, and the relative key.
    pub fn mixes_with(&self) -> Vec<MusicKey> {
        vec![
            *self,
            MusicKey::new(self.pitch_class + 7, self.minor),
            MusicKey::new(self.pitch_class + 5, self.minor),
            self.relative(),
        ]
    }

    /// Parses "Am", "A minor", "C#m", "Dbmaj", "B♭m", "8A" (Camelot), "1m" (Open Key).
    pub fn parse(text: &str) -> Option<MusicKey> {
        static CAMELOT: OnceLock<Regex> = OnceLock::new();
        static OPEN_KEY: OnceLock<Regex> = OnceLock::new();
        static NAME: OnceLock<Regex> = OnceLock::new();
        let t = trim_spaces(text).replace('♭', "b").replace('♯', "#");
        if t.is_empty() {
            return None;
        }
        let camelot = CAMELOT.get_or_init(|| Regex::new(r"^0?(\d{1,2})\s*([ABab])$").unwrap());
        if let Some(m) = camelot.captures(&t)
            && let Ok(n) = m[1].parse::<i32>()
            && (1..=12).contains(&n)
        {
            let minor = m[2].eq_ignore_ascii_case("A");
            let major_pc = (0..12).find(|&pc| camelot_number(pc) == n)?;
            return Some(MusicKey::new(
                if minor { major_pc - 3 } else { major_pc },
                minor,
            ));
        }
        let open_key = OPEN_KEY.get_or_init(|| Regex::new(r"^0?(\d{1,2})\s*([dmDM])$").unwrap());
        if let Some(m) = open_key.captures(&t)
            && let Ok(n) = m[1].parse::<i32>()
            && (1..=12).contains(&n)
        {
            let mode = if m[2].eq_ignore_ascii_case("m") {
                "A"
            } else {
                "B"
            };
            return MusicKey::parse(&format!("{}{mode}", (n + 6) % 12 + 1));
        }
        let name = NAME.get_or_init(|| Regex::new(r"^([A-Ga-g])\s*([#b]?)\s*(.*)$").unwrap());
        let m = name.captures(&t)?;
        let note = format!("{}{}", m[1].to_uppercase(), m[2].to_uppercase());
        let pc = pitch_class(&note)?;
        match trim_spaces(&m[3]).to_lowercase().as_str() {
            "" | "maj" | "major" | "dur" => Some(MusicKey::new(pc, false)),
            "m" | "min" | "minor" | "moll" | "mi" => Some(MusicKey::new(pc, true)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::MusicKey;

    #[test]
    fn parses() {
        for (text, pc, minor) in [
            ("Am", 9, true),
            ("A minor", 9, true),
            ("C#m", 1, true),
            ("Dbmaj", 1, false),
            ("B♭m", 10, true),
            ("8A", 9, true),
            ("08B", 0, false),
            ("1d", 0, false),
            ("1m", 9, true),
            ("G", 7, false),
            ("Eb minor", 3, true),
        ] {
            assert_eq!(
                MusicKey::parse(text),
                Some(MusicKey::new(pc, minor)),
                "{text}"
            );
        }
        assert_eq!(MusicKey::parse("nonsense"), None);
        assert_eq!(MusicKey::parse(""), None);
        assert_eq!(MusicKey::parse("13A"), None);
    }

    #[test]
    fn camelot_and_relatives() {
        assert_eq!(MusicKey::new(0, false).camelot(), "8B");
        assert_eq!(MusicKey::new(9, true).camelot(), "8A");
        assert_eq!(MusicKey::new(6, false).camelot(), "2B");
        assert_eq!(MusicKey::new(9, true).relative(), MusicKey::new(0, false));
        assert_eq!(MusicKey::new(4, true).name(), "E minor");
        let mut mix: Vec<String> = MusicKey::new(9, true)
            .mixes_with()
            .iter()
            .map(|k| k.camelot())
            .collect();
        mix.sort();
        assert_eq!(mix, ["7A", "8A", "8B", "9A"]);
        assert_eq!(MusicKey::all().len(), 24);
    }
}
