# Timeline files (FCPXML): plan

Approved by the owner on 2026-10-29 (ROADMAP.md, second alpha, item 2).

## What it's for

⌘T and the MCP server's `add_to_resolve` need DaVinci Resolve **Studio**: the free
Resolve has no scripting. A timeline file works with the free Resolve, with Studio and
with Final Cut Pro. Earmark writes the file, and you import it:

- **Resolve:** File ▸ Import ▸ Timeline… It opens as a new timeline in the media pool.
  Copy its clips into your own timeline.
- **Final Cut Pro:** File ▸ Import ▸ XML… It opens as a new project.

The clips are cuts of the original files, as with ⌘T: nothing is copied or rendered.

## The format

- **FCPXML 1.10.** Resolve 18 and later read it (Resolve 21 also reads Final Cut Pro
  12's newer versions), and so does Final Cut Pro 10.6 and later.
- One `asset` per file, pointing at the original (`media-rep src="file://…"`), with the
  file's real length in samples. A WAV with a BWF time reference starts at that time,
  as Resolve and Final Cut Pro read it, so that cuts land on the same audio.
- The sequence is a gap as long as everything, with each sound connected below it
  (lane −1, −2…). Each sound takes the first lane that's free at its time, as ⌘T takes
  the first free track. Resolve turns each lane into an audio track.
- Times are whole frames of the chosen frame rate. A range is rounded outwards, as in
  ⌘T.
- Frame rates: 23.976, 24, 25, 29.97 (non-drop or drop frame), 30, 50, 59.94 (non-drop
  or drop frame) and 60. The start timecode is 01:00:00:00 by default.

## In the app

**File ▸ Save as Timeline File…** (⇧⌘T)
- One sound selected: that sound, or its waveform selection.
- Several selected: one after another, in list order.
- The save panel asks for the frame rate and start timecode, and remembers them. The
  file name defaults to the sound's name, or "Earmark sounds".
- Earmark refuses to save inside a library folder: it never writes there.

When ⌘T can't reach Resolve, the message also suggests the timeline file.

## For agents (MCP)

A new tool, `save_timeline_file`, takes the same items as `add_to_resolve`
(`sound_id`, `start`, `end`, `at` in seconds from the timeline's start), plus
`frame_rate`, `start_timecode` and an optional `name`. It writes to
`~/Movies/Earmark/<name>.fcpxml` and returns the path and where each sound went. The
server's instructions tell agents to use it when `resolve_status` says Resolve Studio
can't be reached.

## Testing

- Unit tests: rational times, rounding, lanes, drop-frame start timecodes, BWF time
  references, XML escaping of names and paths (spaces, accents, `&`).
- Import into Resolve Studio 21 (it reads FCPXML as the free version does), with mono,
  stereo and multichannel WAVs, a BWF file with a time reference, MP3, a range, and
  23.976, 25 and 29.97 DF. Check that each cut plays the same audio as the same cut made
  with ⌘T.
- Final Cut Pro isn't installed on the owner's Mac, so that import isn't tested.
