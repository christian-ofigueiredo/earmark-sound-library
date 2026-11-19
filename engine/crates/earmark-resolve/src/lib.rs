//! Puts sounds, or parts of them, on the timeline open in DaVinci Resolve Studio, and reads what
//! that timeline is. The original file is imported once into an "Earmark" bin of the media pool
//! and appended as a cut of it (in and out points, no new file), audio only, at a timecode (or
//! the playhead) on a chosen track, the first free one, or a track named "Earmark" (new if none
//! is free). Uses Resolve's own Python (21.1+, `ResolvePython`), which needs Resolve Studio
//! running with Preferences ▸ System ▸ General ▸ External scripting using: Local. Earmark only
//! asks Resolve to read the file; it never changes it. Port of `ResolveBridge.swift`.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize, Serializer};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Where Resolve's documentation (README, "Built-in Python") says its Python is.
pub fn python() -> PathBuf {
    PathBuf::from(if cfg!(windows) {
        r"C:\Program Files\Blackmagic Design\DaVinci Resolve\ResolvePython\ResolvePython.exe"
    } else if cfg!(target_os = "macos") {
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolvePython"
    } else {
        "/opt/resolve/bin/ResolvePython"
    })
}

/// The script, the same as the Swift bridge's (a test holds them together). Checked against
/// Resolve Studio 21.1.2 (2026-10-27): imported audio takes the project's frame rate; `endFrame`
/// is exclusive; fractional frames are rounded (so cuts are frame-accurate; a range is rounded
/// outwards); `recordFrame` counts from 00:00:00:00 (a timeline starting at 01:00:00:00 at 30 fps
/// starts at 108000); `trackIndex` is 1-based; `mediaType` 2 is audio only; a mono clip plays on
/// both sides of a stereo track.
pub const SCRIPT: &str = include_str!("bridge.py");

/// Resolve answers in a second or two; give up on a hung connection.
const ANSWER_WITHIN: Duration = Duration::from_secs(60);

/// Where on the timeline: a timecode ("01:00:12:05"), or seconds from the timeline's start.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(untagged)]
pub enum At {
    Timecode(String),
    Seconds(f64),
}

/// Which audio track: the first free one there, one named "Earmark" (new if none is free), or
/// this one (1-based).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Track {
    Free,
    Earmark,
    Index(i64),
}

impl Serialize for Track {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Track::Free => s.serialize_str("free"),
            Track::Earmark => s.serialize_str("new"),
            Track::Index(i) => s.serialize_i64(*i),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Item {
    pub path: String,
    /// Seconds into the file; none: from the start, to the end.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<f64>,
    /// None: the playhead.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<At>,
    pub track: Track,
    /// The file's length and channels as Earmark knows them (for a preview, nothing is imported).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub length: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channels: Option<i64>,
}

/// Where one item went (or would go), or why it couldn't.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Placement {
    pub ok: Option<bool>,
    pub error: Option<String>,
    pub track: Option<i64>,
    pub track_name: Option<String>,
    /// Timeline timecodes of the cut.
    pub start: Option<String>,
    pub end: Option<String>,
    /// A track was (or would be) added for it.
    pub new_track: Option<bool>,
}

impl Placement {
    /// What went wrong, for people.
    pub fn problem(&self) -> Option<String> {
        let error = self.error.as_deref()?;
        Some(
            match error {
                "importFailed" => "Resolve couldn't import the file.",
                "tooShort" => "The range is shorter than a frame of the timeline.",
                "busy" => "That track has a clip there.",
                "locked" => "That track is locked.",
                "noSuchTrack" => "The timeline has no such audio track.",
                "noTrack" => "Resolve couldn't add an audio track.",
                "appendFailed" => "Resolve didn't put the sound on the timeline.",
                other => other,
            }
            .to_string(),
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Added {
    pub project: String,
    pub timeline: String,
    pub items: Vec<Placement>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Status {
    pub product: String,
    pub version: String,
    pub project: String,
    /// None when no timeline is open.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline: Option<TimelineInfo>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineInfo {
    pub name: String,
    pub frame_rate: f64,
    pub start: String,
    pub playhead: String,
    pub end: String,
    pub audio_tracks: Vec<TrackInfo>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackInfo {
    pub index: i64,
    pub name: String,
    pub kind: String,
    pub locked: bool,
    pub clips: i64,
    /// Where its last clip ends.
    pub end: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    NotInstalled,
    NotConnected,
    NoProject,
    NoTimeline,
    Other(String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::NotInstalled => f.write_str(if cfg!(target_os = "macos") {
                "Earmark adds sounds to the timeline through DaVinci Resolve Studio 21.1 or later, which isn't in Applications."
            } else {
                "Earmark adds sounds to the timeline through DaVinci Resolve Studio 21.1 or later, which isn't installed."
            }),
            Failure::NotConnected => f.write_str(
                "Open DaVinci Resolve Studio with a project and a timeline. If it's open, set Preferences ▸ System ▸ \
                 General ▸ “External scripting using” to Local, so Earmark can reach it. (The free DaVinci Resolve has no scripting: \
                 use File ▸ Save as Timeline File… (⇧⌘T) in Earmark, or drag the file into it.)",
            ),
            Failure::NoProject => f.write_str("Open a project in DaVinci Resolve first."),
            Failure::NoTimeline => f.write_str("Open a timeline in DaVinci Resolve first."),
            Failure::Other(detail) => {
                write!(f, "DaVinci Resolve didn't answer as expected: {detail}")
            }
        }
    }
}

impl std::error::Error for Failure {}

/// Places the items, one after another (each sees where the others went). `preview`: works out
/// where they'd go without importing or placing anything. `move_playhead`: to the end of the
/// last one placed, so the next follows.
pub fn add(items: &[Item], preview: bool, move_playhead: bool) -> Result<Added, Failure> {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Request<'a> {
        action: &'static str,
        items: &'a [Item],
        preview: bool,
        move_playhead: bool,
    }
    let request = Request {
        action: "add",
        items,
        preview,
        move_playhead,
    };
    run(&python(), &request, ANSWER_WITHIN)
}

/// The project and timeline open in Resolve, its playhead and audio tracks.
pub fn status() -> Result<Status, Failure> {
    run(
        &python(),
        &serde_json::json!({"action": "status"}),
        ANSWER_WITHIN,
    )
}

/// Runs the script in that Python.
fn run<R: DeserializeOwned>(
    python: &Path,
    request: &impl Serialize,
    within: Duration,
) -> Result<R, Failure> {
    if !python.is_file() {
        return Err(Failure::NotInstalled);
    }
    let input = serde_json::to_vec(request).map_err(|e| Failure::Other(e.to_string()))?;
    let output = run_script(python, input, within)?;
    answer(&output)
}

fn run_script(python: &Path, input: Vec<u8>, within: Duration) -> Result<Vec<u8>, Failure> {
    let other = |e: std::io::Error| Failure::Other(e.to_string());
    let mut command = Command::new(python);
    command
        .args(["-c", SCRIPT])
        // The request is UTF-8; on Windows Python would otherwise read it in the system's code page.
        .env("PYTHONUTF8", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = command.spawn().map_err(other)?;
    let mut stdin = child.stdin.take().expect("piped");
    let mut stdout = child.stdout.take().expect("piped");
    // Both on their own threads, so a full pipe can't hold up the wait below.
    std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });
    let reader = std::thread::spawn(move || {
        let mut output = Vec::new();
        let _ = stdout.read_to_end(&mut output);
        output
    });
    let deadline = Instant::now() + within;
    while child.try_wait().map_err(other)?.is_none() {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Failure::Other(format!(
                "no answer in {} s",
                within.as_secs()
            )));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    reader
        .join()
        .map_err(|_| Failure::Other("no answer".into()))
}

/// The script's last line of output: the answer, or what went wrong.
fn answer<R: DeserializeOwned>(output: &[u8]) -> Result<R, Failure> {
    let text = String::from_utf8_lossy(output);
    let Some(line) = text.lines().rfind(|l| !l.is_empty()) else {
        return Err(Failure::Other("no answer".into()));
    };
    #[derive(Deserialize)]
    struct Problem {
        error: Option<String>,
        detail: Option<String>,
    }
    if let Ok(Problem {
        error: Some(error),
        detail,
    }) = serde_json::from_str(line)
    {
        return Err(match error.as_str() {
            "noModule" | "notConnected" => Failure::NotConnected,
            "noProject" => Failure::NoProject,
            "noTimeline" => Failure::NoTimeline,
            _ => Failure::Other(detail.unwrap_or(error)),
        });
    }
    serde_json::from_str(line).map_err(|_| Failure::Other(line.chars().take(300).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_script_is_the_swift_bridges() {
        let swift = include_str!("../../../../app/Sources/EarmarkCore/ResolveBridge.swift");
        let swift = swift.replace("\r\n", "\n");
        assert!(swift.contains(&format!(
            "#\"\"\"\n{}\n\"\"\"#",
            SCRIPT.replace("\r\n", "\n")
        )));
    }

    #[test]
    fn requests_as_the_script_reads_them() {
        let item = Item {
            path: "/a/b.wav".into(),
            start: Some(0.5),
            end: None,
            at: Some(At::Seconds(12.25)),
            track: Track::Free,
            length: Some(3.0),
            channels: None,
        };
        assert_eq!(
            serde_json::to_value(&item).unwrap(),
            serde_json::json!({"path": "/a/b.wav", "start": 0.5, "at": 12.25, "track": "free", "length": 3.0})
        );
        let by_timecode = Item {
            at: Some(At::Timecode("01:00:10:00".into())),
            track: Track::Index(2),
            ..item.clone()
        };
        let v = serde_json::to_value(&by_timecode).unwrap();
        assert_eq!(v["at"], "01:00:10:00");
        assert_eq!(v["track"], 2);
        let new = Item {
            track: Track::Earmark,
            ..item
        };
        assert_eq!(serde_json::to_value(&new).unwrap()["track"], "new");
    }

    #[test]
    fn answers() {
        let added: Added = answer(
            br#"a line of its own
{"project": "Film", "timeline": "Edit 1", "items": [{"ok": true, "track": 3, "trackName": "Earmark", "start": "01:00:02:00", "end": "01:00:03:06", "newTrack": true}, {"error": "busy"}]}
"#,
        )
        .unwrap();
        assert_eq!(added.items[0].track_name.as_deref(), Some("Earmark"));
        assert_eq!(added.items[0].new_track, Some(true));
        assert_eq!(
            added.items[1].problem().as_deref(),
            Some("That track has a clip there.")
        );

        let status: Status = answer(
            br#"{"product": "DaVinci Resolve Studio", "version": "21.1.2", "project": "Film", "timeline": {"name": "Edit", "frameRate": 25.0, "start": "01:00:00:00", "playhead": "01:00:00:00", "end": "01:00:10:00", "audioTracks": [{"index": 1, "name": "A1", "kind": "stereo", "locked": false, "clips": 2, "end": "01:00:04:00"}]}}"#,
        )
        .unwrap();
        assert_eq!(status.timeline.unwrap().audio_tracks[0].clips, 2);

        let fails = |text: &[u8]| answer::<Status>(text).unwrap_err();
        assert_eq!(
            fails(br#"{"error": "noModule", "detail": "x"}"#),
            Failure::NotConnected
        );
        assert_eq!(
            fails(br#"{"error": "notConnected", "detail": null}"#),
            Failure::NotConnected
        );
        assert_eq!(fails(br#"{"error": "noProject"}"#), Failure::NoProject);
        assert_eq!(fails(br#"{"error": "noTimeline"}"#), Failure::NoTimeline);
        assert_eq!(
            fails(br#"{"error": "x", "detail": "why"}"#),
            Failure::Other("why".into())
        );
        assert_eq!(fails(b""), Failure::Other("no answer".into()));
        assert_eq!(fails(b"Traceback"), Failure::Other("Traceback".into()));
    }

    #[test]
    fn not_installed() {
        let missing = Path::new("/no/such/ResolvePython");
        let got: Result<Status, _> = run(missing, &serde_json::json!({}), Duration::from_secs(1));
        assert_eq!(got.unwrap_err(), Failure::NotInstalled);
    }

    /// A stand-in for Resolve's Python: gets the request and answers.
    #[cfg(unix)]
    fn stand_in(body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("earmark-resolve-{}-{n}.sh", std::process::id()));
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(unix)]
    #[test]
    fn running_the_script() {
        // Echoes the request back as the "project", having read all of a big one.
        let echo = stand_in(
            r#"cat > /dev/null; echo noise; echo '{"product":"P","version":"1","project":"Film"}'"#,
        );
        let big = "x".repeat(1 << 20);
        let status: Status = run(
            &echo,
            &serde_json::json!({"action": "status", "padding": big}),
            Duration::from_secs(20),
        )
        .unwrap();
        assert_eq!(status.project, "Film");
        std::fs::remove_file(echo).unwrap();

        // Far more output than a pipe holds, then the answer.
        let chatty = stand_in(
            r#"cat > /dev/null; i=0; while [ $i -lt 20000 ]; do echo xxxxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done; echo '{"product":"P","version":"1","project":"Film"}'"#,
        );
        let status: Status = run(&chatty, &serde_json::json!({}), Duration::from_secs(20)).unwrap();
        assert_eq!(status.project, "Film");
        std::fs::remove_file(chatty).unwrap();

        let hung = stand_in("exec sleep 30");
        let got: Result<Status, _> = run(&hung, &serde_json::json!({}), Duration::from_secs(1));
        assert_eq!(got.unwrap_err(), Failure::Other("no answer in 1 s".into()));
        std::fs::remove_file(hung).unwrap();
    }
}
