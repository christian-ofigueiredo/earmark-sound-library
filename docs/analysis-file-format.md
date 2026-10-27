# Earmark analysis files

What Earmark worked out for one sound library or music folder, in one file, so it can move to
another Mac (or another tool) without analysing again. Written with **File ▸ Export
Analysis…**, read with **File ▸ Import Analysis…** (`EarmarkCore/AnalysisFiles.swift`).

- One file per library: `<library name>.earmark-analysis.json`.
- Never written inside a library: Earmark refuses a folder inside any of them.
- Items are matched by **content**, not by path, so another drive name, user name or folder
  layout is fine.
- An import **only fills gaps**. What Earmark already has, the user's folder categories and
  their tempo and key corrections are never overwritten.

## Format (version 1)

JSON, UTF-8. Dates are ISO 8601. Optional fields may be missing or `null`.

```json
{
  "format": "earmark-analysis",
  "version": 1,
  "exportedAt": "2026-10-26T23:40:00Z",
  "library": { "kind": "sounds", "name": "SoundFX", "path": "/Volumes/Library Drive/SoundFX" },
  "folderCategories": [ { "folder": "Vendor Pack/Footsteps", "catID": "FEETHmn" } ],
  "sounds": [
    {
      "path": "Vendor Pack/Impacts/Big Hit 01.wav",
      "fingerprint": "1b2c40-8f3e…",
      "facts": { "version": 1, "loudness": -23.4, "peak": -1.2 },
      "embeddings": {
        "clap-general": { "version": 1, "vector": "<base64>" },
        "pe-av-large":  { "version": 1, "vector": "<base64>" }
      },
      "category": "DOORWood"
    }
  ]
}
```

A music folder has `"kind": "music"` and `songs` instead of `sounds`:

```json
"songs": [
  {
    "path": "Artist - Song.mp3",
    "size": 10123456,
    "fingerprint": "9a7f…",
    "analysis":   { "bpm": 123.49, "bpmLow": 122.9, "bpmHigh": 124.1, "stability": "steady",
                    "beatsPerBar": 4, "keyPitchClass": 11, "keyMinor": true,
                    "keyConfidence": 0.81, "source": "Phase 0" },
    "correction": { "bpm": 61.75, "bpmLow": 61.45, "bpmHigh": 62.05 }
  }
]
```

| Field | Meaning |
|---|---|
| `library.path` | Where the library was on the exporting Mac. For people only; matching doesn't use it. |
| `path` | The file's path inside its library (`/`-separated). |
| `fingerprint` | Size (hex) and an FNV-1a hash of the first and last 64 KB: `Fingerprint.of(url:)`. A song's is `null` if it couldn't be read at export. |
| `facts` | Integrated loudness (LUFS, EBU R128) and sample peak (dBFS). |
| `embeddings` | Per model, float32 little-endian, base64. `vector: null` means silent (no embedding to make). CLAP: 512 values. PE-AV large: 1024. Both L2-normalised. |
| `version` | The analysis pipeline's version. An import skips anything older than the importing Earmark's. |
| `folderCategories` | The user's UCS categories for folders of sounds without one of their own. Earmark's guesses aren't exported; it makes them again. |
| `category` | The user's UCS category for this one sound (added 2026-10-27; older Earmarks ignore it). Earmark's guesses from how a sound sounds aren't exported. |
| `analysis` | Tempo and key as analysed. `source` is `Phase 0` or `Earmark`. `keyPitchClass`: C = 0 … B = 11. |
| `correction` | Tempo, key or beats per bar the user set by hand. Only the parts they changed are present. |

Results for files that couldn't be read are not exported: the other Mac may be able to read them.

## Import

- **Sounds** match local sounds (in any sound library) with the same fingerprint. Byte-identical
  copies all get the result. A file whose content changed since export doesn't match; it is
  analysed again as usual.
- **Folder categories** go to the library where most of the file's sounds were found, for
  folders it has and the user hasn't given a category.
- **A sound's category** goes to the matching sounds the user hasn't given one here.
- **Songs** match by fingerprint, among local songs of the same size, preferring the same path.
  If the file has no fingerprint, they match by path and size. Tempo and key are added only to
  songs with none (analysed by nobody yet), keeping `source`. Corrections are added only where
  the user hasn't made one.
- Phase 0's `music_analysis.json` is also accepted by Import Analysis… (matched by path, then
  file name and size).

## Size and speed (the owner's library, 2026-10-26)

| | |
|---|---|
| SoundFX, 28,827 sounds with both embeddings | 237 MB, exported in 2.7 s (peak memory 300 MB) |
| Liked Songs, 1,688 songs | 0.4 MB, 1.2 s (most of it reading fingerprints) |
| Import of both into a copy with no analysis | 5.9 s (peak memory ~800 MB: the file is read whole) |

Without embeddings, a sound library's file is about 3% of that.
