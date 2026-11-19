//! A tempo, key or beats per bar the owner set for a song by hand, kept apart from what Phase 0
//! or Earmark found, so Revert always works and rescans, imports and Earmark's own analysis
//! never undo it. Port of `SongCorrections.swift`.

use crate::music_key::MusicKey;
use crate::records::SongRecord;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Keyed by the file's path, with no link to the song row: it survives removing and re-adding
/// the folder.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SongCorrection {
    pub path: String,
    pub bpm: Option<f64>,
    /// The tempo range scaled with the tempo (Double, Half), or None for a tempo typed in.
    pub bpm_low: Option<f64>,
    pub bpm_high: Option<f64>,
    pub key_pitch_class: Option<i64>,
    pub key_minor: Option<bool>,
    pub beats_per_bar: Option<i64>,
    pub corrected_at: String,
}

impl SongCorrection {
    pub fn new(path: &str, corrected_at: &str) -> SongCorrection {
        SongCorrection {
            path: path.into(),
            bpm: None,
            bpm_low: None,
            bpm_high: None,
            key_pitch_class: None,
            key_minor: None,
            beats_per_bar: None,
            corrected_at: corrected_at.into(),
        }
    }

    pub fn key(&self) -> Option<MusicKey> {
        self.key_pitch_class
            .map(|pc| MusicKey::new(pc as i32, self.key_minor.unwrap_or(false)))
    }
    pub fn corrects_tempo(&self) -> bool {
        self.bpm.is_some()
    }
    pub fn corrects_key(&self) -> bool {
        self.key_pitch_class.is_some()
    }
    pub fn corrects_beats_per_bar(&self) -> bool {
        self.beats_per_bar.is_some()
    }
    pub fn is_empty(&self) -> bool {
        !self.corrects_tempo() && !self.corrects_key() && !self.corrects_beats_per_bar()
    }
}

/// What Phase 0 or Earmark found for a song the owner corrected.
#[derive(Clone, Debug, PartialEq)]
pub struct AnalysedValues {
    pub bpm: Option<f64>,
    pub bpm_low: Option<f64>,
    pub bpm_high: Option<f64>,
    pub beats_per_bar: Option<i64>,
    pub key: Option<MusicKey>,
}

/// A change to a song's tempo, key or beats per bar.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SongEdit {
    DoubleTempo,
    HalveTempo,
    SetTempo(f64),
    RelativeKey,
    SetKey(MusicKey),
    SetBeatsPerBar(i64),
    RevertTempo,
    RevertKey,
    RevertBeatsPerBar,
    RevertAll,
}

impl SongEdit {
    /// For the Edit menu's Undo ("Undo Halve Tempo").
    pub fn title(&self) -> &'static str {
        match self {
            SongEdit::DoubleTempo => "Double Tempo",
            SongEdit::HalveTempo => "Halve Tempo",
            SongEdit::SetTempo(_) => "Set Tempo",
            SongEdit::RelativeKey => "Use Relative Key",
            SongEdit::SetKey(_) => "Set Key",
            SongEdit::SetBeatsPerBar(_) => "Set Beats per Bar",
            SongEdit::RevertTempo => "Revert Tempo",
            SongEdit::RevertKey => "Revert Key",
            SongEdit::RevertBeatsPerBar => "Revert Beats per Bar",
            SongEdit::RevertAll => "Revert to Analysed Values",
        }
    }

    /// Tempos that can be typed in, as Phase 0's import and Earmark's analysis keep.
    pub const TEMPO_RANGE: std::ops::RangeInclusive<f64> = 20.0..=400.0;
}

impl SongRecord {
    /// As Phase 0 or Earmark found it, without the owner's corrections.
    pub fn uncorrected(&self) -> SongRecord {
        let mut s = self.clone();
        if let Some(a) = &self.analysed {
            s.bpm = a.bpm;
            s.bpm_low = a.bpm_low;
            s.bpm_high = a.bpm_high;
            s.beats_per_bar = a.beats_per_bar;
            s.key_pitch_class = a.key.map(|k| k.pitch_class as i64);
            s.key_minor = a.key.map(|k| k.minor);
            s.analysed = None;
            s.correction = None;
        }
        s
    }

    /// With this correction laid over what was analysed (None or empty: as analysed).
    pub fn applying(&self, c: Option<&SongCorrection>) -> SongRecord {
        let mut s = self.uncorrected();
        let Some(c) = c.filter(|c| !c.is_empty()) else {
            return s;
        };
        s.analysed = Some(AnalysedValues {
            bpm: s.bpm,
            bpm_low: s.bpm_low,
            bpm_high: s.bpm_high,
            beats_per_bar: s.beats_per_bar,
            key: s.key(),
        });
        s.correction = Some(c.clone());
        if let Some(bpm) = c.bpm {
            s.bpm = Some(bpm);
            s.bpm_low = c.bpm_low;
            s.bpm_high = c.bpm_high;
        }
        if let Some(key) = c.key() {
            s.key_pitch_class = Some(key.pitch_class as i64);
            s.key_minor = Some(key.minor);
        }
        if let Some(beats) = c.beats_per_bar {
            s.beats_per_bar = Some(beats);
        }
        s
    }

    /// Analysed by Phase 0 or by Earmark; the owner's corrections don't count.
    pub fn is_analysed(&self) -> bool {
        let s = self.uncorrected();
        s.analysis_source.is_some() || s.bpm.is_some() || s.key_pitch_class.is_some()
    }

    /// Whether this edit can apply to the song as shown.
    pub fn allows(&self, edit: SongEdit) -> bool {
        let range = SongEdit::TEMPO_RANGE;
        match edit {
            SongEdit::DoubleTempo => self.bpm.is_some_and(|b| b * 2.0 <= *range.end()),
            SongEdit::HalveTempo => self.bpm.is_some_and(|b| b / 2.0 >= *range.start()),
            SongEdit::SetTempo(x) => range.contains(&x),
            SongEdit::RelativeKey => self.key().is_some(),
            SongEdit::SetKey(k) => Some(k) != self.key(),
            SongEdit::SetBeatsPerBar(n) => {
                [2, 3, 4, 6].contains(&n) && Some(n) != self.beats_per_bar
            }
            SongEdit::RevertTempo => self.correction.as_ref().is_some_and(|c| c.corrects_tempo()),
            SongEdit::RevertKey => self.correction.as_ref().is_some_and(|c| c.corrects_key()),
            SongEdit::RevertBeatsPerBar => self
                .correction
                .as_ref()
                .is_some_and(|c| c.corrects_beats_per_bar()),
            SongEdit::RevertAll => self.correction.is_some(),
        }
    }

    /// The correction this song has after the edit; None when nothing differs from what was
    /// analysed any more (Double then Half, or a key set back to the analysed one).
    pub fn correction_after(&self, edit: SongEdit, at: &str) -> Option<SongCorrection> {
        let base = self.uncorrected();
        let mut c = self
            .correction
            .clone()
            .unwrap_or_else(|| SongCorrection::new(&self.path, at));
        c.corrected_at = at.into();
        let scale = |c: &mut SongCorrection, f: f64| {
            if let Some(bpm) = self.bpm {
                c.bpm = Some(bpm * f);
                c.bpm_low = self.bpm_low.map(|v| v * f);
                c.bpm_high = self.bpm_high.map(|v| v * f);
            }
        };
        match edit {
            SongEdit::DoubleTempo => scale(&mut c, 2.0),
            SongEdit::HalveTempo => scale(&mut c, 0.5),
            SongEdit::SetTempo(x) => {
                c.bpm = Some(x);
                c.bpm_low = None;
                c.bpm_high = None;
            }
            SongEdit::RelativeKey => {
                if let Some(key) = self.key() {
                    c.key_pitch_class = Some(key.relative().pitch_class as i64);
                    c.key_minor = Some(key.relative().minor);
                }
            }
            SongEdit::SetKey(k) => {
                c.key_pitch_class = Some(k.pitch_class as i64);
                c.key_minor = Some(k.minor);
            }
            SongEdit::SetBeatsPerBar(n) => c.beats_per_bar = Some(n),
            SongEdit::RevertTempo => {
                c.bpm = None;
                c.bpm_low = None;
                c.bpm_high = None;
            }
            SongEdit::RevertKey => {
                c.key_pitch_class = None;
                c.key_minor = None;
            }
            SongEdit::RevertBeatsPerBar => c.beats_per_bar = None,
            SongEdit::RevertAll => return None,
        }
        // Back where the analysis was (a typed tempo equal to it too): no correction for that part.
        let near = |x: Option<f64>, y: Option<f64>| match (x, y) {
            (None, None) => true,
            (Some(x), Some(y)) => (x - y).abs() < 0.005,
            _ => false,
        };
        if c.bpm.is_some()
            && near(c.bpm, base.bpm)
            && ((c.bpm_low.is_none() && c.bpm_high.is_none())
                || (near(c.bpm_low, base.bpm_low) && near(c.bpm_high, base.bpm_high)))
        {
            c.bpm = None;
            c.bpm_low = None;
            c.bpm_high = None;
        }
        if c.key().is_some() && c.key() == base.key() {
            c.key_pitch_class = None;
            c.key_minor = None;
        }
        if c.beats_per_bar.is_some() && c.beats_per_bar == base.beats_per_bar {
            c.beats_per_bar = None;
        }
        if c.is_empty() { None } else { Some(c) }
    }
}

/// The songs with the owner's corrections laid over what Phase 0 or Earmark found.
pub fn apply(
    corrections: &HashMap<String, SongCorrection>,
    songs: &[SongRecord],
) -> Vec<SongRecord> {
    if corrections.is_empty() {
        return songs.to_vec();
    }
    songs
        .iter()
        .map(|s| {
            corrections
                .get(&s.path)
                .map_or_else(|| s.clone(), |c| s.applying(Some(c)))
        })
        .collect()
}
