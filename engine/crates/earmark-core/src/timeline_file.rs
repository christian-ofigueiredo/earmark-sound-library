//! A timeline file (FCPXML 1.10) with sounds, or parts of them, at their times: what the free
//! DaVinci Resolve, Resolve Studio and Final Cut Pro import (docs/timeline-file-plan.md). Each
//! clip is a cut of the original file, connected below a gap as long as everything, on the first
//! lane free at its time. Times are whole frames; a range is rounded outwards. Port of
//! `TimelineFile.swift`.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A frame rate: one frame lasts numerator/denominator seconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rate {
    pub name: &'static str,
    pub numerator: i64,
    pub denominator: i64,
    pub drop_frame: bool,
}

pub const RATES: [Rate; 10] = [
    Rate {
        name: "23.976",
        numerator: 1001,
        denominator: 24000,
        drop_frame: false,
    },
    Rate {
        name: "24",
        numerator: 1,
        denominator: 24,
        drop_frame: false,
    },
    Rate {
        name: "25",
        numerator: 1,
        denominator: 25,
        drop_frame: false,
    },
    Rate {
        name: "29.97",
        numerator: 1001,
        denominator: 30000,
        drop_frame: false,
    },
    Rate {
        name: "29.97 DF",
        numerator: 1001,
        denominator: 30000,
        drop_frame: true,
    },
    Rate {
        name: "30",
        numerator: 1,
        denominator: 30,
        drop_frame: false,
    },
    Rate {
        name: "50",
        numerator: 1,
        denominator: 50,
        drop_frame: false,
    },
    Rate {
        name: "59.94",
        numerator: 1001,
        denominator: 60000,
        drop_frame: false,
    },
    Rate {
        name: "59.94 DF",
        numerator: 1001,
        denominator: 60000,
        drop_frame: true,
    },
    Rate {
        name: "60",
        numerator: 1,
        denominator: 60,
        drop_frame: false,
    },
];

impl Rate {
    /// "25", "29.97 DF", "29.97df", "29.97": one of `RATES`.
    pub fn named(text: &str) -> Option<Rate> {
        let t = text.to_lowercase().replace(' ', "");
        RATES
            .into_iter()
            .find(|r| r.name.to_lowercase().replace(' ', "") == t)
    }

    /// Frames per second, rounded (the timecode's frame count).
    pub fn nominal(&self) -> i64 {
        (self.fps()).round() as i64
    }

    fn fps(&self) -> f64 {
        self.denominator as f64 / self.numerator as f64
    }

    fn frame_duration(&self) -> Rational {
        Rational::new(self.numerator, self.denominator)
    }
}

/// One sound to place.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    pub path: String,
    pub name: String,
    /// The file's length in seconds, sample rate and channels, as Earmark knows them.
    pub length: f64,
    pub sample_rate: i64,
    pub channels: i64,
    /// Where the file's audio starts in its own timecode, in samples (a BWF time reference).
    #[serde(default)]
    pub time_reference: i64,
    /// Seconds into the file; none: from the start, to the end.
    #[serde(default)]
    pub start: Option<f64>,
    #[serde(default)]
    pub end: Option<f64>,
    /// Seconds from the timeline's start; none: where the previous clip ends.
    #[serde(default)]
    pub at: Option<f64>,
}

/// Where a clip went: its lane (1 is just below the gap) and its timeline timecodes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Placement {
    pub lane: i64,
    pub start: String,
    pub end: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    BadTimecode(String),
    TooShort(String),
    Nothing,
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::BadTimecode(tc) => write!(f, "“{tc}” isn't a timecode like 01:00:00:00."),
            Failure::TooShort(name) => write!(f, "The part of “{name}” is shorter than a frame."),
            Failure::Nothing => f.write_str("There are no sounds to put in the timeline file."),
        }
    }
}

impl std::error::Error for Failure {}

/// The file's text and where each clip went.
pub fn fcpxml(
    clips: &[Clip],
    rate: &Rate,
    start_timecode: &str,
    name: &str,
) -> Result<(String, Vec<Placement>), Failure> {
    if clips.is_empty() {
        return Err(Failure::Nothing);
    }
    let first =
        frames(start_timecode, rate).ok_or_else(|| Failure::BadTimecode(start_timecode.into()))?;
    let fd = rate.frame_duration();
    let tc_start = fd * first;

    struct Cut<'a> {
        clip: &'a Clip,
        asset: usize,
        in_frame: i64,
        duration: i64,
        at: i64,
        lane: usize,
    }
    let mut assets: HashMap<&str, usize> = HashMap::new();
    let mut asset_order: Vec<&Clip> = Vec::new();
    let mut cuts: Vec<Cut> = Vec::new();
    let mut lanes: Vec<Vec<(i64, i64)>> = Vec::new();
    let mut cursor = 0i64;
    let fps = rate.fps();
    for clip in clips {
        let available = (clip.length * fps + 1e-6).floor() as i64;
        let in_frame = (clip.start.unwrap_or(0.0) * fps + 1e-9).floor() as i64;
        let out_frame = clip
            .end
            .map_or(available, |e| (e * fps - 1e-9).ceil() as i64)
            .min(available);
        if out_frame <= in_frame {
            return Err(Failure::TooShort(clip.name.clone()));
        }
        let duration = out_frame - in_frame;
        let at = clip
            .at
            .map_or(cursor, |a| ((a * fps).round() as i64).max(0));
        let lane = lanes
            .iter()
            .position(|l| l.iter().all(|&(a, b)| !(a < at + duration && b > at)))
            .unwrap_or(lanes.len());
        if lane == lanes.len() {
            lanes.push(Vec::new());
        }
        lanes[lane].push((at, at + duration));
        let asset = *assets.entry(&clip.path).or_insert_with(|| {
            asset_order.push(clip);
            asset_order.len()
        });
        cuts.push(Cut {
            clip,
            asset,
            in_frame,
            duration,
            at,
            lane: lane + 1,
        });
        cursor = at + duration;
    }
    let total = cuts.iter().map(|c| c.at + c.duration).max().unwrap_or(1);

    let mut x = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n<fcpxml version=\"1.10\">\n  <resources>\n    \
         <format id=\"r0\" frameDuration=\"{fd}\" width=\"1920\" height=\"1080\"/>\n"
    );
    for (n, clip) in asset_order.iter().enumerate() {
        let samples_rate = clip.sample_rate.max(1);
        let samples = (clip.length * samples_rate as f64).round() as i64;
        x += &format!(
            "    <asset id=\"r{}\" name=\"{}\" start=\"{}\" duration=\"{}\" hasAudio=\"1\" audioSources=\"1\" \
             audioChannels=\"{}\" audioRate=\"{}\">\n      <media-rep kind=\"original-media\" src=\"{}\"/>\n    </asset>\n",
            n + 1,
            escape(&clip.name),
            fd * start_frame(clip, rate),
            Rational::new(samples, samples_rate),
            clip.channels.max(1),
            clip.sample_rate,
            escape(&file_url(&clip.path, cfg!(windows))),
        );
    }
    x += &format!(
        "  </resources>\n  <library>\n    <event name=\"Earmark\">\n      <project name=\"{}\">\n        \
         <sequence format=\"r0\" duration=\"{}\" tcStart=\"{tc_start}\" tcFormat=\"{}\" audioLayout=\"stereo\" audioRate=\"48k\">\n          \
         <spine>\n            <gap name=\"Gap\" offset=\"{tc_start}\" start=\"{tc_start}\" duration=\"{}\">\n",
        escape(name),
        fd * total,
        if rate.drop_frame { "DF" } else { "NDF" },
        fd * total,
    );
    for cut in &cuts {
        let asset_start = fd * start_frame(cut.clip, rate);
        x += &format!(
            "              <asset-clip ref=\"r{}\" lane=\"-{}\" offset=\"{}\" name=\"{}\" start=\"{}\" duration=\"{}\" audioRole=\"effects\"/>\n",
            cut.asset,
            cut.lane,
            tc_start + fd * cut.at,
            escape(&cut.clip.name),
            asset_start + fd * cut.in_frame,
            fd * cut.duration,
        );
    }
    x += "            </gap>\n          </spine>\n        </sequence>\n      </project>\n    </event>\n  </library>\n</fcpxml>\n";
    let placements = cuts
        .iter()
        .map(|c| Placement {
            lane: c.lane as i64,
            start: timecode(first + c.at, rate),
            end: timecode(first + c.at + c.duration, rate),
        })
        .collect();
    Ok((x, placements))
}

/// The file's own start (its BWF time reference) in whole frames, rounded to the nearest:
/// Resolve 21 reads an asset's start that way.
pub fn start_frame(clip: &Clip, rate: &Rate) -> i64 {
    let per = rate.numerator * clip.sample_rate.max(1);
    (clip.time_reference * rate.denominator + per / 2) / per
}

/// "01:00:00:00" (or "01:00:00;00" for drop frame) as a frame count from 00:00:00:00.
pub fn frames(tc: &str, rate: &Rate) -> Option<i64> {
    let parts: Vec<i64> = tc
        .split([':', ';', '.'])
        .filter(|p| !p.is_empty())
        .filter_map(|p| p.parse().ok())
        .collect();
    let nominal = rate.nominal();
    if parts.len() != 4
        || parts.iter().any(|&p| p < 0)
        || parts[1] >= 60
        || parts[2] >= 60
        || parts[3] >= nominal
    {
        return None;
    }
    let mut n = (parts[0] * 3600 + parts[1] * 60 + parts[2]) * nominal + parts[3];
    if rate.drop_frame {
        let dropped = nominal / 15;
        let minutes = 60 * parts[0] + parts[1];
        n -= dropped * (minutes - minutes / 10);
    }
    Some(n)
}

/// A frame count from 00:00:00:00 as a timecode (";" before the frames for drop frame).
pub fn timecode(frames: i64, rate: &Rate) -> String {
    let nominal = rate.nominal();
    let mut n = frames;
    if rate.drop_frame {
        let dropped = nominal / 15;
        let per10 = nominal * 600 - dropped * 9;
        let (tens, rest) = (n / per10, n % per10);
        n += dropped * 9 * tens
            + if rest > dropped {
                dropped * ((rest - dropped) / (nominal * 60 - dropped))
            } else {
                0
            };
    }
    let (f, s) = (n % nominal, n / nominal);
    format!(
        "{:02}:{:02}:{:02}{}{f:02}",
        s / 3600,
        s / 60 % 60,
        s % 60,
        if rate.drop_frame { ";" } else { ":" }
    )
}

/// A file URL keeping the path's characters as they are, percent-encoded as UTF-8. On Windows
/// "C:\a b" is "file:///C:/a%20b".
fn file_url(path: &str, windows: bool) -> String {
    let path = if windows {
        path.replace('\\', "/")
    } else {
        path.to_string()
    };
    let mut out = String::from(if path.starts_with('/') {
        "file://"
    } else {
        "file:///"
    });
    for b in path.bytes() {
        // CharacterSet.urlPathAllowed, less "%;?#[]".
        if b.is_ascii_alphanumeric() || b"!$&'()*+,-./:=@_~".contains(&b) {
            out.push(b as char);
        } else {
            out += &format!("%{b:02X}");
        }
    }
    out
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// An exact time in seconds, written as FCPXML wants it ("1001/30000s", "3600s").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Rational {
    numerator: i64,
    denominator: i64,
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

impl Rational {
    fn new(numerator: i64, denominator: i64) -> Rational {
        let g = gcd(numerator.abs(), denominator.abs());
        if g == 0 {
            Rational {
                numerator: 0,
                denominator: 1,
            }
        } else {
            Rational {
                numerator: numerator / g,
                denominator: denominator / g,
            }
        }
    }
}

impl std::ops::Add for Rational {
    type Output = Rational;
    fn add(self, b: Rational) -> Rational {
        let g = gcd(self.denominator, b.denominator);
        let d = self.denominator / g * b.denominator;
        Rational::new(
            self.numerator * (d / self.denominator) + b.numerator * (d / b.denominator),
            d,
        )
    }
}

impl std::ops::Mul<i64> for Rational {
    type Output = Rational;
    fn mul(self, n: i64) -> Rational {
        Rational::new(self.numerator * n, self.denominator)
    }
}

impl std::fmt::Display for Rational {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.denominator == 1 {
            write!(f, "{}s", self.numerator)
        } else {
            write!(f, "{}/{}s", self.numerator, self.denominator)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rate25() -> Rate {
        Rate::named("25").unwrap()
    }
    fn df() -> Rate {
        Rate::named("29.97 DF").unwrap()
    }

    fn clip(name: &str) -> Clip {
        Clip {
            path: format!("/Volumes/Banana 01/SFX/{name}.wav"),
            name: name.into(),
            length: 4.0,
            sample_rate: 48000,
            channels: 2,
            time_reference: 0,
            start: None,
            end: None,
            at: None,
        }
    }

    #[test]
    fn rational() {
        assert_eq!(Rational::new(3600, 1).to_string(), "3600s");
        assert_eq!(Rational::new(2002, 60000).to_string(), "1001/30000s");
        assert_eq!(
            (Rational::new(1, 25) + Rational::new(1, 48000)).to_string(),
            "1921/48000s"
        );
        assert_eq!(Rational::new(0, 25).to_string(), "0s");
    }

    #[test]
    fn timecodes() {
        let (r, d) = (rate25(), df());
        assert_eq!(frames("01:00:00:00", &r), Some(90000));
        assert_eq!(frames("01:00:00;00", &d), Some(107892));
        assert_eq!(frames("00:01:00;02", &d), Some(1800));
        assert_eq!(timecode(1800, &d), "00:01:00;02");
        assert_eq!(timecode(107892, &d), "01:00:00;00");
        assert_eq!(timecode(17982, &d), "00:10:00;00");
        assert_eq!(frames("1:00:00", &r), None);
        assert_eq!(frames("00:00:00:25", &r), None);
        for n in [0, 1, 1799, 1800, 1801, 17981, 17982, 107892, 123456] {
            assert_eq!(frames(&timecode(n, &d), &d), Some(n));
        }
    }

    #[test]
    fn end_to_end_and_lanes() {
        let (a, b, c, d) = (
            clip("A"),
            Clip {
                length: 2.0,
                ..clip("B")
            },
            Clip {
                at: Some(1.0),
                ..clip("C")
            },
            Clip {
                at: Some(10.0),
                start: Some(1.01),
                end: Some(2.0),
                ..clip("A")
            },
        );
        let (xml, placed) = fcpxml(&[a, b, c, d], &rate25(), "01:00:00:00", "Test").unwrap();
        let p = |lane, s: &str, e: &str| Placement {
            lane,
            start: s.into(),
            end: e.into(),
        };
        assert_eq!(
            placed,
            [
                p(1, "01:00:00:00", "01:00:04:00"),
                p(1, "01:00:04:00", "01:00:06:00"),
                p(2, "01:00:01:00", "01:00:05:00"),
                p(1, "01:00:10:00", "01:00:11:00"),
            ]
        );
        // One asset per file; the range is rounded outwards to frames (1.01 s → frame 25).
        assert_eq!(xml.matches("<asset ").count(), 3);
        assert!(xml.contains(
            r#"<asset-clip ref="r1" lane="-1" offset="3610s" name="A" start="1s" duration="1s""#
        ));
        assert!(xml.contains(r#"<asset-clip ref="r3" lane="-2" offset="3601s""#));
        assert!(xml.contains(r#"tcStart="3600s" tcFormat="NDF""#));
        assert!(xml.contains(r#"<gap name="Gap" offset="3600s" start="3600s" duration="11s">"#));
    }

    #[test]
    fn drop_frame_and_time_reference() {
        // A BWF file starting at 10:00:00 (48 kHz): the asset starts there and so does the cut.
        let c = Clip {
            start: Some(0.5),
            end: Some(1.0),
            time_reference: 1_728_000_000,
            ..clip("T")
        };
        let (xml, placed) = fcpxml(&[c], &df(), "01:00:00;00", "DF").unwrap();
        assert_eq!(
            (placed[0].start.as_str(), placed[0].end.as_str()),
            ("01:00:00;00", "01:00:00;16")
        );
        assert!(xml.contains(r#"tcFormat="DF""#) && xml.contains(r#"tcStart="8999991/2500s""#));
        // 36000 s is frame 1078921.08 at 29.97: the asset starts at the nearest frame, the cut 14 later.
        let fd = Rational::new(1001, 30000);
        assert!(xml.contains(&format!(r#"start="{}" duration="4s""#, fd * 1_078_921)));
        assert!(xml.contains(&format!(
            r#"start="{}" duration="1001/1875s""#,
            fd * 1_078_935
        )));
        // A start 0.88 of a frame in rounds up, as Resolve reads it (56.096 s at 30 fps).
        let late = Clip {
            time_reference: 2_692_608,
            ..clip("L")
        };
        assert_eq!(start_frame(&late, &Rate::named("30").unwrap()), 1683);
        assert_eq!(start_frame(&late, &rate25()), 1402);
    }

    #[test]
    fn escaping_and_failures() {
        let c = Clip {
            path: "/tmp/Ação & co/x.wav".into(),
            ..clip("Rain & \"Thunder\" <loud>")
        };
        let (xml, _) = fcpxml(&[c], &rate25(), "01:00:00:00", "A & B").unwrap();
        assert!(xml.contains(r#"name="Rain &amp; &quot;Thunder&quot; &lt;loud&gt;""#));
        assert!(xml.contains(r#"<project name="A &amp; B">"#));
        assert_eq!(
            file_url("/tmp/Ação & co/x.wav", false),
            "file:///tmp/A%C3%A7%C3%A3o%20&%20co/x.wav"
        );
        assert_eq!(
            file_url(r"C:\Sons\a b.wav", true),
            "file:///C:/Sons/a%20b.wav"
        );
        let short = Clip {
            start: Some(1.0),
            end: Some(1.0),
            ..clip("S")
        };
        assert_eq!(
            fcpxml(&[short], &rate25(), "01:00:00:00", "x"),
            Err(Failure::TooShort("S".into()))
        );
        assert_eq!(
            fcpxml(&[clip("S")], &rate25(), "x", "x"),
            Err(Failure::BadTimecode("x".into()))
        );
        assert_eq!(
            fcpxml(&[], &rate25(), "01:00:00:00", "x"),
            Err(Failure::Nothing)
        );
    }
}
