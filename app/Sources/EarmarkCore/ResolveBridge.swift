#if os(macOS)
import Foundation

/// Puts sounds, or parts of them, on the timeline open in DaVinci Resolve Studio, and reads what
/// that timeline is. The original file is imported once into an "Earmark" bin of the media pool
/// and appended as a cut of it (in and out points, no new file), audio only, at a timecode (or
/// the playhead) on a chosen track, the first free one, or a track named "Earmark" (new if none
/// is free). Uses Resolve's own Python (21.1+, `ResolvePython`), which needs Resolve Studio
/// running with Preferences ▸ System ▸ General ▸ External scripting using: Local. Earmark only
/// asks Resolve to read the file; it never changes it. Used by ⌘T and the MCP server.
public enum ResolveBridge {
    public static let python = URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolvePython")
    /// The name of the tracks Earmark makes for sounds placed together (`Track.earmark`).
    public static let trackName = "Earmark"

    /// Where on the timeline: a timecode ("01:00:12:05"), or seconds from the timeline's start.
    public enum At: Codable, Sendable, Equatable {
        case timecode(String)
        case seconds(Double)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(Double.self) { self = .seconds(s) } else { self = .timecode(try c.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .timecode(let tc): try c.encode(tc)
            case .seconds(let s): try c.encode(s)
            }
        }
    }

    /// Which audio track: the first free one there (⌘T), one named "Earmark" (new if none is
    /// free), or this one (1-based).
    public enum Track: Codable, Sendable, Equatable {
        case free
        case earmark
        case index(Int)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .index(i); return }
            switch try c.decode(String.self) {
            case "free": self = .free
            default: self = .earmark
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .free: try c.encode("free")
            case .earmark: try c.encode("new")
            case .index(let i): try c.encode(i)
            }
        }
    }

    public struct Item: Codable, Sendable {
        public var path: String
        /// Seconds into the file; nil: from the start, to the end.
        public var start: Double?
        public var end: Double?
        /// nil: the playhead.
        public var at: At?
        public var track: Track
        /// The file's length and channels as Earmark knows them (for a preview, nothing is imported).
        public var length: Double?
        public var channels: Int?

        public init(path: String, start: Double? = nil, end: Double? = nil, at: At? = nil, track: Track = .free,
                    length: Double? = nil, channels: Int? = nil) {
            self.path = path; self.start = start; self.end = end; self.at = at; self.track = track
            self.length = length; self.channels = channels
        }
    }

    /// Where one item went (or would go), or why it couldn't.
    public struct Placement: Codable, Sendable, Equatable {
        public var ok: Bool?
        public var error: String?
        public var track: Int?
        public var trackName: String?
        /// Timeline timecodes of the cut.
        public var start: String?
        public var end: String?
        /// A track was (or would be) added for it.
        public var newTrack: Bool?

        /// What went wrong, for people.
        public var problem: String? {
            switch error {
            case nil: nil
            case "importFailed": "Resolve couldn't import the file."
            case "tooShort": "The range is shorter than a frame of the timeline."
            case "busy": "That track has a clip there."
            case "locked": "That track is locked."
            case "noSuchTrack": "The timeline has no such audio track."
            case "noTrack": "Resolve couldn't add an audio track."
            case "appendFailed": "Resolve didn't put the sound on the timeline."
            case let other?: other
            }
        }
    }

    public struct Added: Decodable, Sendable {
        public var project: String
        public var timeline: String
        public var items: [Placement]
    }

    public struct Status: Codable, Sendable {
        public struct TimelineInfo: Codable, Sendable {
            public var name: String
            public var frameRate: Double
            public var start: String
            public var playhead: String
            public var end: String
            public var audioTracks: [TrackInfo]
        }
        public struct TrackInfo: Codable, Sendable {
            public var index: Int
            public var name: String
            public var kind: String
            public var locked: Bool
            public var clips: Int
            /// Where its last clip ends.
            public var end: String
        }
        public var product: String
        public var version: String
        public var project: String
        /// Nil when no timeline is open.
        public var timeline: TimelineInfo?
    }

    public enum Failure: Error, LocalizedError {
        case notInstalled
        case notConnected
        case noProject
        case noTimeline
        case other(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "Earmark adds sounds to the timeline through DaVinci Resolve Studio 21.1 or later, which isn't in Applications."
            case .notConnected: "Open DaVinci Resolve Studio with a project and a timeline. If it's open, set Preferences ▸ System ▸ "
                + "General ▸ “External scripting using” to Local, so Earmark can reach it. (The free DaVinci Resolve has no scripting: "
                + "use File ▸ Save as Timeline File… (⇧⌘T) in Earmark, or drag the file into it.)"
            case .noProject: "Open a project in DaVinci Resolve first."
            case .noTimeline: "Open a timeline in DaVinci Resolve first."
            case .other(let detail): "DaVinci Resolve didn't answer as expected: \(detail)"
            }
        }
    }

    /// Places the items, one after another (each sees where the others went). `preview`: works
    /// out where they'd go without importing or placing anything. `movePlayhead`: to the end of
    /// the last one placed (⌘T, so the next follows).
    public static func add(_ items: [Item], preview: Bool = false, movePlayhead: Bool = false) async throws -> Added {
        struct Request: Encodable { var action = "add"; var items: [Item]; var preview: Bool; var movePlayhead: Bool }
        return try await run(Request(items: items, preview: preview, movePlayhead: movePlayhead), as: Added.self)
    }

    /// The project and timeline open in Resolve, its playhead and audio tracks.
    public static func status() async throws -> Status {
        struct Request: Encodable { var action = "status" }
        return try await run(Request(), as: Status.self)
    }

    private struct Problem: Decodable { var error: String?; var detail: String? }

    /// Runs the script in Resolve's Python, off the caller's thread.
    static func run<R: Decodable>(_ request: some Encodable, as: R.Type) async throws -> R {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw Failure.notInstalled }
        let input = try JSONEncoder().encode(request)
        let output: Data = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", script]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            // Resolve answers in a second or two; give up on a hung connection.
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); throw Failure.other("no answer in 60 s") }
            return stdout.fileHandleForReading.readDataToEndOfFile()
        }.value
        guard let line = String(decoding: output, as: UTF8.self).split(separator: "\n").last else {
            throw Failure.other("no answer")
        }
        let data = Data(line.utf8)
        if let p = try? JSONDecoder().decode(Problem.self, from: data), let error = p.error {
            switch error {
            case "noModule", "notConnected": throw Failure.notConnected
            case "noProject": throw Failure.noProject
            case "noTimeline": throw Failure.noTimeline
            default: throw Failure.other(p.detail ?? error)
            }
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw Failure.other(String(line.prefix(300)))
        }
    }

    /// The script. Checked against Resolve Studio 21.1.2 (2026-10-27): imported audio takes the
    /// project's frame rate; `endFrame` is exclusive; fractional frames are rounded (so cuts are
    /// frame-accurate; a range is rounded outwards); `recordFrame` counts from 00:00:00:00 (a
    /// timeline starting at 01:00:00:00 at 30 fps starts at 108000); `trackIndex` is 1-based;
    /// `mediaType` 2 is audio only; a mono clip plays on both sides of a stereo track.
    static let script = #"""
import json, math, sys

req = json.loads(sys.stdin.read())

def out(obj):
    print(json.dumps(obj))
    sys.exit(0)

def fail(code, detail=None):
    out({"error": code, "detail": detail})

try:
    import DaVinciResolveScript as dvr
except Exception as e:
    fail("noModule", str(e))
resolve = dvr.scriptapp("Resolve")
if not resolve:
    fail("notConnected")
manager = resolve.GetProjectManager()
project = manager.GetCurrentProject() if manager else None
if not project:
    fail("noProject")
timeline = project.GetCurrentTimeline()

def frames(tc, rate):
    drop = ";" in tc
    h, m, s, f = [int(x) for x in tc.replace(";", ":").split(":")]
    nominal = int(round(rate))
    n = (h * 3600 + m * 60 + s) * nominal + f
    if drop:
        dropped = 2 if nominal == 30 else 4 if nominal == 60 else 0
        minutes = 60 * h + m
        n -= dropped * (minutes - minutes // 10)
    return n

def timecode(n, rate, drop):
    nominal = int(round(rate))
    if drop:
        dropped = 2 if nominal == 30 else 4 if nominal == 60 else 0
        per10 = nominal * 600 - dropped * 9
        tens, rest = divmod(n, per10)
        n += dropped * 9 * tens + (dropped * ((rest - dropped) // (nominal * 60 - dropped)) if rest > dropped else 0)
    f = n % nominal
    s = n // nominal
    return "%02d:%02d:%02d%s%02d" % (s // 3600, s // 60 % 60, s % 60, ";" if drop else ":", f)

def locked(t):
    try:
        return bool(timeline.GetIsTrackLocked("audio", t))
    except Exception:
        return False

if req.get("action") == "status":
    info = {"product": resolve.GetProductName(), "version": resolve.GetVersionString(), "project": project.GetName()}
    if timeline:
        rate = float(timeline.GetSetting("timelineFrameRate") or 24)
        now = timeline.GetCurrentTimecode()
        drop = ";" in now
        tracks = []
        for t in range(1, timeline.GetTrackCount("audio") + 1):
            clips = timeline.GetItemListInTrack("audio", t) or []
            last = max([c.GetEnd() for c in clips], default=timeline.GetStartFrame())
            tracks.append({"index": t, "name": timeline.GetTrackName("audio", t) or "", "kind": timeline.GetTrackSubType("audio", t) or "",
                           "locked": locked(t), "clips": len(clips), "end": timecode(last, rate, drop)})
        info["timeline"] = {"name": timeline.GetName(), "frameRate": rate, "start": timeline.GetStartTimecode(), "playhead": now,
                            "end": timecode(timeline.GetEndFrame(), rate, drop), "audioTracks": tracks}
    out(info)

if not timeline:
    fail("noTimeline")
pool = project.GetMediaPool()
rate = float(timeline.GetSetting("timelineFrameRate") or 24)
now = timeline.GetCurrentTimecode()
drop = ";" in now
playhead = frames(now, rate)
first = timeline.GetStartFrame()
preview = bool(req.get("preview"))

# Each audio track: its kind, name, whether locked, and where its clips are (and the ones placed now).
tracks = {}
for t in range(1, timeline.GetTrackCount("audio") + 1):
    tracks[t] = {"kind": timeline.GetTrackSubType("audio", t), "name": timeline.GetTrackName("audio", t) or "",
                 "locked": locked(t), "busy": [(c.GetStart(), c.GetEnd()) for c in timeline.GetItemListInTrack("audio", t) or []]}

folder = None
def media(path):
    global folder
    root = pool.GetRootFolder()
    if folder is None:
        folder = next((f for f in (root.GetSubFolderList() or []) if f.GetName() == "Earmark"), None) or pool.AddSubFolder(root, "Earmark")
    if folder:
        found = next((c for c in (folder.GetClipList() or []) if c.GetClipProperty("File Path") == path), None)
        if found:
            return found
    previous = pool.GetCurrentFolder()
    if folder:
        pool.SetCurrentFolder(folder)
    imported = pool.ImportMedia([path]) or []
    if previous:
        pool.SetCurrentFolder(previous)
    return imported[0] if imported else None

def free(t, kind, start, length):
    info = tracks[t]
    fits = ("mono", "stereo") if kind == "mono" else (kind,)
    if info["kind"] not in fits or info["locked"]:
        return False
    return all(not (a < start + length and b > start) for a, b in info["busy"])

def add_track(kind, name):
    t = max(tracks) + 1 if tracks else 1
    if not preview:
        if not timeline.AddTrack("audio", kind):
            return None
        t = timeline.GetTrackCount("audio")
        if name:
            timeline.SetTrackName("audio", t, name)
    tracks[t] = {"kind": kind, "name": name or "Audio %d" % t, "locked": False, "busy": []}
    return t

results = []
last_end = None
for it in req.get("items", []):
    item = None
    clip_rate, channels = rate, it.get("channels") or 2
    # The clip's length in frames, as Resolve counts them (whole frames, rounded down).
    length = int(math.floor(it["length"] * clip_rate + 1e-6)) if it.get("length") else None
    if not preview:
        item = media(it["path"])
        if not item:
            results.append({"error": "importFailed"})
            continue
        clip_rate = float(item.GetClipProperty("FPS") or rate)
        duration_tc = item.GetClipProperty("Duration")
        length = frames(duration_tc, clip_rate) if duration_tc else length
        channels = int(item.GetClipProperty("Audio Ch") or channels)
    start = int(math.floor((it.get("start") or 0) * clip_rate))
    end = int(math.ceil(it["end"] * clip_rate)) if it.get("end") is not None else (length or 0)
    if length:
        end = min(end, length)
    if end <= start:
        results.append({"error": "tooShort"})
        continue
    duration = int(math.ceil((end - start) * rate / clip_rate))
    at = it.get("at")
    record = playhead if at is None else (first + int(round(at * rate)) if isinstance(at, (int, float)) else frames(at, rate))
    kind = "mono" if channels == 1 else "stereo" if channels == 2 else "adaptive%d" % channels
    mode = it.get("track", "free")
    created = False
    if isinstance(mode, int):
        if mode not in tracks:
            results.append({"error": "noSuchTrack"})
            continue
        if tracks[mode]["locked"]:
            results.append({"error": "locked"})
            continue
        if not all(not (a < record + duration and b > record) for a, b in tracks[mode]["busy"]):
            results.append({"error": "busy"})
            continue
        track = mode
    else:
        named = "Earmark" if mode == "new" else None
        track = next((t for t in sorted(tracks) if (named is None or tracks[t]["name"] == named) and free(t, kind, record, duration)), None)
        if track is None:
            track = add_track(kind, named)
            created = True
            if track is None:
                results.append({"error": "noTrack"})
                continue
    if not preview:
        placed = pool.AppendToTimeline([{"mediaPoolItem": item, "startFrame": start, "endFrame": end, "mediaType": 2,
                                         "trackIndex": track, "recordFrame": record}])
        if not placed:
            results.append({"error": "appendFailed"})
            continue
        record, stop = placed[0].GetStart(), placed[0].GetEnd()
    else:
        stop = record + duration
    tracks[track]["busy"].append((record, stop))
    last_end = stop
    results.append({"ok": True, "track": track, "trackName": tracks[track]["name"], "start": timecode(record, rate, drop),
                    "end": timecode(stop, rate, drop), "newTrack": created})

# Appending moves Resolve's playhead to the end of the clip: to the end of the last one for ⌘T
# (the next follows), else back where the editor had it.
if not preview and last_end is not None:
    timeline.SetCurrentTimecode(timecode(last_end, rate, drop) if req.get("movePlayhead") else now)
out({"project": project.GetName(), "timeline": timeline.GetName(), "items": results})
"""#
}
#endif
