# Earmark: handoff (2026-10-23)

Notes for continuing in a new chat (for example Claude Code on the owner's Mac).
Read `CLAUDE.md` and `docs/PLAN.md` first; this file says where the work stopped.

## Rules from the owner (keep these)

- **Ask the owner before changing anything** (code, docs, repository, settings).
  Work on branches; merge to `main` only when the owner approves.
- Never write to, rename or move original sound/music files. Earmark only reads them;
  state lives in its own database (`~/Library/Application Support/Earmark/library.sqlite`).
- Quality over speed; best models available.
- Open source (MIT), public repo. Don't commit non-free test audio (ESC-50 is CC BY-NC)
  or the owner's library data (metadata CSVs, folder mappings) without approval.
- Don't ask for tokens in chat.
- Don't rerun the Phase 0 music analysis. The owner checked it: mostly right; key
  mistakes are the relative key; tempo is right even when confidence is low.
- The owner uses **DaVinci Resolve Studio** on a 16 GB M1 Pro. Libraries live on an
  external SanDisk SSD ("Banana One", ~1 GB/s). The owner may be exporting video
  while analysis runs, so long jobs must be gentle (idle/overnight scheduling).

## Approvals

| Item | Status |
|---|---|
| B: update docs/PLAN.md | Done (on `main`, aa7edd4) |
| C: Sound Ideas folder → UCS mapping draft | Done. Two CSVs were sent to the owner in chat (`sound_ideas_ucs_mapping.csv`, `sound_ideas_ucs_per_file_preview.csv`). They are **not** in the repo (library data). The owner should fill the "Your decision" column. |
| D: Phase 1 app with both sections, built on a GitHub Mac at every push | **In progress, branch `phase1`** |
| A: recompute Phase 0 report fixes | **Not approved.** The owner only asked how long it takes. Answer given: it's quick, but I recommended skipping it and fixing these things in the app instead. Waiting for the owner's decision. |

The repository rename (sound-library → earmark) can only be done by the owner in GitHub
Settings → Repository name. Topics/description also have to be set there.

## Where the code is

- `main`: Phase 0 (Python tools in `phase0/`, CI in `.github/workflows/checks.yml` and
  `mac-selftest.yml`), plan and docs.
- `phase1` branch: the Swift app in `app/` (SwiftPM, tools 6.0, macOS 14+, Swift 6 mode,
  GRDB 7.11.1), plus `.github/workflows/app.yml` (macos-15: `swift build` + `swift test`
  in `app/`).

### app/ layout

- `Package.swift`: library `EarmarkCore` (+ UCS CSV resource), test target, and the
  macOS-only executable `Earmark` (inside `#if os(macOS)`, so Linux can build/test the core).
- `Sources/EarmarkCore/` (tested on Linux, 15 tests pass):
  - `CSV.swift`, `UCS.swift` (UCS v8.2.1 catalogue; CatID in filenames/folders only counts
    in exact or all-caps case; resource lookup checks `Contents/Resources` first so a
    signed .app works).
  - `BinaryReading.swift`: read-only file access.
  - `XMLFlattener.swift`, `MetadataReader.swift` (WAV/RF64/BW64, bext, iXML, INFO, XMP,
    acid, smpl, AIFF).
  - `MetadataNormalizer.swift`: same priority rules as Phase 0; drops junk descriptions.
  - `LibraryScanner.swift`: lists audio files, fingerprints (size + FNV-1a of the first and
    last 64 KB), parallel header scan.
  - `MusicKey.swift`: parsing, Camelot, relative key, compatible keys.
  - `Phase0Import.swift`: reads Phase 0 `music_analysis.json` and drops impossible BPM
    (outside 20–400) and beats-per-bar values other than 2, 3, 4 or 6.
  - `LibraryDatabase.swift`: GRDB schema v1 (library/sound/song), replace-on-rescan keeping
    ids, Phase 0 analysis matching (path → name+size → unique name).
- `Sources/Earmark/` (macOS app, **not compiled yet**, see below):
  - `EarmarkApp.swift`: one window; File menu has Add Sound Library ⌘O, Add Music
    Folder ⇧⌘O, Import Phase 0 Music Analysis and Rescan All. ⌘1/⌘2 switch sections;
    Help has Welcome.
  - `AppModel.swift`: shared state; reads the DB off the main thread. Also: overlap checks
    for folders, a scan guard (doesn't wipe a library if the drive drops mid-scan), and the
    Phase 0 import (offers to add the songs' folder).
  - `ContentView.swift`: segmented Sound Effects / Music switch. The bottom status bar always
    says "Analysis is much faster when you're not using the Mac. Leave Earmark open
    overnight." (the owner asked for this on open). There's also a welcome sheet on first
    launch.
  - `SoundsView.swift`: sidebar (libraries with offline state, UCS categories →
    subcategories, uncategorised), sortable searchable table, detail pane. Rows drag into
    Resolve (`NSItemProvider(object: url as NSURL)`); Space or double-click plays;
    auto-play toggle.
  - `MusicView.swift`: folders, BPM range filter with half/double time, key filter with
    compatible (Camelot) keys, "Or relative" column, "Find songs that mix with this".
  - `SharedViews.swift`, `Waveform.swift` (AVAudioFile peaks via vDSP; click to play from
    a point, drag to select a range), `AudioPlayer.swift` (AVAudioPlayer, range playback),
    `MusicFiles.swift` (AVFoundation tags), `Display.swift` (formatting, search indexes).

## Next steps (in order)

1. ~~Get the app compiling on macOS.~~ Done: builds clean with Swift 6.4 on macOS 27 and on the
   GitHub macos-15 runner (`app.yml` green).
2. Try it on the real library (read-only). Done for sound effects on Banana 01
   (`02 RESOURCES/AUDIO/SoundFX`, 29,177 files): scan, UCS categories, waveform, playback,
   range playback, search. Fixed: squeezed table (detail is now an `.inspector`), stale
   selection after filtering, status bar "N of M". Still to check, with the owner at the Mac:
   - dragging into Resolve Studio;
   - whether clicking a top-level category (e.g. "Ambience") selects it with a real mouse click
     (accessibility presses only toggle the disclosure).
   Music checked too (`~/Music/IPOD/Liked Songs`, 1,688 songs): Phase 0 import matched all 1,688
   (1,670 with BPM after dropping 14 outside 20–400, 1,444 with beats per bar), BPM filter with
   half/double, "Find Songs That Mix With This", detail pane and playback all correct (counts
   checked against SQL). The owner has to pick folders/files: the macOS Open panel runs out of
   process, so computer use can't drive it.
   Not a bug: UCS filenames like `…_Ocular Sounds_Forest_The Complete Ambiences Collection` show
   Library "Forest", because SourceID is the fourth field by the spec.
3. Phase 1 items:
   - ~~`scripts/build-app.sh`~~ Done (`app/build/Earmark.app`, ad hoc signed, bundle id
     `io.github.christian-ofigueiredo.Earmark`).
   - ~~Sound-ID persistence by fingerprint~~ Done: renamed/moved files keep their id, and ids of
     removed sounds are kept in `retiredSound` (schema v2) so re-adding a library restores them.
   - ~~MP3/AAC length and format~~ Done: the scanner takes an optional `TechnicalReader`; the app
     passes an AVAudioFile one (`SoundFiles.technical`), so the core still builds on Linux.
   - Applying the owner-approved Sound Ideas folder → UCS mapping (from the C CSVs) as vendor
     rules: **blocked** until the owner fills in the "Your decision" column.
   - ~~Group MP3/WAV twins~~ Done (`FormatTwins`): same library, same name apart from the
     extension, folders equal once format words are blanked, lengths within 0.5 s. The list shows
     the best copy (WAV > AIFF > FLAC > AAC > MP3); the detail pane lists the others under
     "Also in this pack as". On SoundFX this hides 350 copies (29,177 → 28,827 listed).
4. Phase 2 (analysis engine), started on `phase1`:
   - ~~Idle/overnight scheduler~~ Done. `AnalysisGovernor` (core, tested) turns `SystemSignals`
     into a pace: paused / 1 gentle worker while you work / cores÷2 when idle ≥ 5 min. Other
     apps' load pauses it: while you work at CPU > 50% or GPU > 35% (editing in Resolve:
     GPU ~40%, Resolve ~47% CPU on the Edit page); once idle only at CPU or GPU > 60%
     (an export), so Resolve left open overnight doesn't block it. Hysteresis back to
     25%/15% (idle 40%/45%); speeding up waits 60 s, slowing down is immediate; heat
     (serious), battery and Low Power Mode pause it. `SystemMonitor` (app) samples idle time
     (HID), CPU (host ticks minus Earmark's own rusage), GPU (IOAccelerator "Device
     Utilization %"), thermal state, power. Analysis menu: Pause / Resume / Run at Full Speed
     Now (not remembered after relaunch) / gentle-or-wait-while-you-work. App Nap is held off
     while working; idle sleep is still allowed.
     **To check with the owner:** the thresholds are first guesses from one sample. Watch a
     real night (Resolve open, and once during an export) and tune. Status-bar wording right
     after launch says "waits for the Mac to be idle" during the 60 s ramp-up.
   - ~~First stage-1 fact: loudness~~ Done. `LoudnessMeter` (BS.1770-4 / EBU R128 gating,
     sample peak) passes EBU Tech 3341 cases 1–3 at 44.1/48/96 kHz and matches ffmpeg ebur128
     within 0.05 LU on 6 real files. Results in `soundFacts` (schema v3, keyed by sound id +
     fingerprint, no FK, so they survive re-adding a library). Shown in the detail pane.
     Measured ~15–20 files/s at full speed from the SSD (843 in about a minute).
     Menu titles can't follow state: SwiftUI menu commands didn't refresh from @Observable or
     @AppStorage when read via accessibility, so Pause and Resume are separate fixed items.
   - Core ML conversion of PE-AV large + CLAP (half precision only if the parity check
     passes);
   - music tempo/key in-app (Beat This! + S-KEY);
   - learning from the owner's labelled files (kNN gave 62% exact in Phase 0; zero-shot
     only 13–16%).
5. Phase 4: Resolve Studio bridge for sending only a selected range. Use the scripting
   API: import the original into the media pool, then `MediaPool.AppendToTimeline` with
   `startFrame`/`endFrame`. External scripting must be set to Local in Resolve
   preferences.

## Gotchas learned

- See `CLAUDE.md` "Gotchas" for Phase 0 (S-KEY writes `prediction/` folders if called on a
  directory; PE-AV text embeds bug; CLAP 10 s windowing; Beat This! checkpoint fallback;
  GitHub macOS runners fail any MPS allocation).
- SwiftPM's `Bundle.module` looks at the top of the .app, which breaks code signing; that's
  handled in `UCSCatalog.bundledResource`.
- The GRDB `sound.path` column is UNIQUE, so folders of the same kind can't overlap; the app
  refuses or offers to replace them.
- Phase 0 music confidence flags are miscalibrated; don't present them as errors.
