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