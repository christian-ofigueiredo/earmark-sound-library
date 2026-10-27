import Foundation

/// Puts a sound, or the selected part of it, on the timeline open in DaVinci Resolve Studio: the
/// original file is imported into an "Earmark" bin of the media pool (once) and appended as a cut
/// of it (in and out points, no new file), audio only, at the playhead, on the first audio track
/// that's free there (a new one if none is), and the playhead moves to the end of the cut. Uses
/// Resolve's own Python (21.1+, `ResolvePython`), which needs Resolve Studio running with
/// Preferences ▸ System ▸ General ▸ External scripting using: Local. Earmark only asks Resolve to
/// read the file; it never changes it.
enum ResolveBridge {
    static let python = URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolvePython")

    struct Request: Encodable {
        var path: String
        /// Seconds into the file; nil for the whole file.
        var start: Double?
        var end: Double?
    }

    struct Placed: Decodable {
        var track: Int
        var timeline: String
        var project: String
    }

    enum Failure: Error, LocalizedError {
        case notInstalled
        case notConnected
        case noProject
        case noTimeline
        case importFailed
        case tooShort
        case noTrack
        case appendFailed
        case other(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Earmark adds sounds to the timeline through DaVinci Resolve Studio 21.1 or later, which isn't in Applications."
            case .notConnected: "Open DaVinci Resolve Studio with a project and a timeline. If it's open, set Preferences ▸ System ▸ "
                + "General ▸ “External scripting using” to Local, so Earmark can reach it. (The free DaVinci Resolve has no scripting: "
                + "drag the file into it instead.)"
            case .noProject: "Open a project in DaVinci Resolve first."
            case .noTimeline: "Open a timeline in DaVinci Resolve first: the sound goes at its playhead."
            case .importFailed: "DaVinci Resolve couldn't import the file."
            case .tooShort: "The selection is shorter than a frame of the timeline."
            case .noTrack: "DaVinci Resolve couldn't add an audio track for the sound."
            case .appendFailed: "DaVinci Resolve didn't put the sound on the timeline (is the track locked?)."
            case .other(let detail): "DaVinci Resolve didn't answer as expected: \(detail)"
            }
        }
    }

    /// Runs the script in Resolve's Python, off the main thread.
    static func add(_ request: Request) async throws -> Placed {
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
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); throw Failure.other("no answer in 30 s") }
            return stdout.fileHandleForReading.readDataToEndOfFile()
        }.value
        struct Answer: Decodable { var ok: Bool?; var error: String?; var detail: String?; var track: Int?; var timeline: String?; var project: String? }
        guard let line = String(decoding: output, as: UTF8.self).split(separator: "\n").last,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)) else {
            throw Failure.other(String(decoding: output.prefix(300), as: UTF8.self))
        }
        if answer.ok == true, let track = answer.track {
            return Placed(track: track, timeline: answer.timeline ?? "", project: answer.project ?? "")
        }
        switch answer.error {
        case "noModule", "notConnected": throw Failure.notConnected
        case "noProject": throw Failure.noProject
        case "noTimeline": throw Failure.noTimeline
        case "importFailed": throw Failure.importFailed
        case "tooShort": throw Failure.tooShort
        case "noTrack": throw Failure.noTrack
        case "appendFailed": throw Failure.appendFailed
        default: throw Failure.other(answer.detail ?? answer.error ?? "unknown")
        }
    }

    /// The script. Checked against Resolve Studio 21.1.2 (2026-10-27): clips and their frame
    /// numbers are at the project's frame rate, `endFrame` is exclusive, fractional frames are
    /// rounded (so cuts are frame-accurate; the selection is rounded outwards), `recordFrame`
    /// counts from 00:00:00:00 (a timeline starting at 01:00:00:00 at 30 fps starts at 108000),
    /// `trackIndex` is 1-based, `mediaType` 2 is audio only.
    static let script = #"""
import json, math, sys

req = json.loads(sys.stdin.read())

def out(**kw):
    print(json.dumps(kw))
    sys.exit(0)

try:
    import DaVinciResolveScript as dvr
except Exception as e:
    out(error="noModule", detail=str(e))
resolve = dvr.scriptapp("Resolve")
if not resolve:
    out(error="notConnected")
manager = resolve.GetProjectManager()
project = manager.GetCurrentProject() if manager else None
if not project:
    out(error="noProject")
timeline = project.GetCurrentTimeline()
if not timeline:
    out(error="noTimeline")
pool = project.GetMediaPool()
root = pool.GetRootFolder()
path = req["path"]

# The file in the media pool's "Earmark" bin: there already, or imported now.
folder = next((f for f in (root.GetSubFolderList() or []) if f.GetName() == "Earmark"), None) or pool.AddSubFolder(root, "Earmark")
item = None
if folder:
    item = next((c for c in (folder.GetClipList() or []) if c.GetClipProperty("File Path") == path), None)
if not item:
    previous = pool.GetCurrentFolder()
    if folder:
        pool.SetCurrentFolder(folder)
    imported = pool.ImportMedia([path]) or []
    if previous:
        pool.SetCurrentFolder(previous)
    item = imported[0] if imported else None
if not item:
    out(error="importFailed")

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

rate = float(item.GetClipProperty("FPS") or timeline.GetSetting("timelineFrameRate") or 24)
length = frames(item.GetClipProperty("Duration") or "00:00:00:00", rate)
start = int(math.floor((req.get("start") or 0) * rate))
end = int(math.ceil(req["end"] * rate)) if req.get("end") is not None else length
if length:
    end = min(end, length)
if end <= start:
    out(error="tooShort")

timeline_rate = float(timeline.GetSetting("timelineFrameRate") or rate)
now = timeline.GetCurrentTimecode()
drop = ";" in now
record = frames(now, timeline_rate)
duration = int(math.ceil((end - start) * timeline_rate / rate))

# The first audio track free at the playhead for the cut's length: stereo for a stereo file, mono
# or stereo for a mono one (Resolve plays mono on both sides of a stereo track), not locked.
channels = int(item.GetClipProperty("Audio Ch") or 2)
kind = "mono" if channels == 1 else "stereo" if channels == 2 else "adaptive%d" % channels
fits = {"mono": ("mono", "stereo")}.get(kind, (kind,))

def free(track):
    if timeline.GetTrackSubType("audio", track) not in fits:
        return False
    try:
        if timeline.GetIsTrackLocked("audio", track):
            return False
    except Exception:
        pass
    for clip in timeline.GetItemListInTrack("audio", track) or []:
        if clip.GetStart() < record + duration and clip.GetEnd() > record:
            return False
    return True

track = next((t for t in range(1, timeline.GetTrackCount("audio") + 1) if free(t)), None)
if track is None:
    if not timeline.AddTrack("audio", kind):
        out(error="noTrack")
    track = timeline.GetTrackCount("audio")

placed = pool.AppendToTimeline([{"mediaPoolItem": item, "startFrame": start, "endFrame": end, "mediaType": 2,
                                 "trackIndex": track, "recordFrame": record}])
if not placed:
    out(error="appendFailed")
timeline.SetCurrentTimecode(timecode(placed[0].GetEnd(), timeline_rate, drop))
out(ok=True, track=track, timeline=timeline.GetName(), project=project.GetName())
"""#
}
