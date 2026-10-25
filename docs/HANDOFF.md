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
     **Checked on a real night (2026-10-23, log in Logs/scheduler-*.csv):** with Resolve left
     open, idle GPU was 0% (p90 5%) and other CPU 8%, so analysis ran at full speed for 4.5 h.
     It paused for 12 min when another app used ~88% CPU at 03:00, and at once when the owner's
     Resolve export started at 07:46 (GPU 85–96%). Something used the GPU at ~90% for a minute
     every 30 min (not identified; possibly a periodic background task); each cost 2–3 min
     with ramp-up, ~5% of the night. **Thresholds left as they are.** Status-bar wording right
     after launch says "waits for the Mac to be idle" during the 60 s ramp-up.
   - ~~First stage-1 fact: loudness~~ Done. `LoudnessMeter` (BS.1770-4 / EBU R128 gating,
     sample peak) passes EBU Tech 3341 cases 1–3 at 44.1/48/96 kHz and matches ffmpeg ebur128
     within 0.05 LU on 6 real files. Results in `soundFacts` (schema v3, keyed by sound id +
     fingerprint, no FK, so they survive re-adding a library). Shown in the detail pane.
     Measured ~15–20 files/s at full speed from the SSD (843 in about a minute).
     Menu titles can't follow state: SwiftUI menu commands didn't refresh from @Observable or
     @AppStorage when read via accessibility, so Pause and Resume are separate fixed items.
   - ~~Core ML conversion of CLAP~~ Done (`models/`, see its README): `convert_clap.py` makes
     `CLAPAudio.mlpackage` (not committed, 271 MB); `parity_clap.py` checks it against
     Phase 0's cached vectors. On 300 real files, full precision matches Phase 0 exactly
     (cosine 1.00000, neighbours 100%); half precision keeps 99.4% of top-5 neighbours, so
     **the app uses full precision** (39 ms/window on CPU). The Swift pipeline
     (`EarmarkML`: AVFoundation decode + Core ML; `EarmarkCore/ClapFeatures.swift`: Phase 0
     prep + CLAP log-mel, tested against a Python fixture to < 0.01 dB) gives median cosine
     1.000000, p1 0.99907, min 0.988 (short 96 kHz files: resampler differences move the
     -60 dB trim point), neighbours 99.9%; 0.38 s/file. `earmark-parity` reruns this check.
   - ~~CLAP as an analysis stage~~ Done. `soundEmbedding` table (schema v4, key soundId+model,
     float32 vector, fingerprint + version, no FK). The engine runs each sound's missing stages
     (loudness, CLAP) in one job; one shared model (predictions locked) is loaded on demand
     from `~/Library/Application Support/Earmark/Models/CLAPAudio.mlpackage` (compiled once to
     `.mlmodelc` beside it) and unloaded while analysis is paused. No model → status bar says
     "CLAP model not installed" and only loudness runs. Detail pane shows "Embedding: CLAP".
     On the real library: ~4.8 files/s with 5 workers (long 96 kHz files), Earmark ~780 MB
     with the model loaded. Stored vectors vs Phase 0 on the first 339 overlapping files:
     median cosine 1.000000, min 0.9955, top-5 neighbours 99.4% (`models/check_app_embeddings.py`).
   - Still open for CLAP: how the app gets the model file (download or release asset; it
     can't live in git). Nothing uses the embeddings yet (Phase 3: similarity, groups).
   - ~~Core ML conversion of PE-AV large~~ Done (`models/convert_peav.py`, `parity_peav.py`;
     see models/README). Audio tower only, in 5 parts (4.2 GB float32, not committed).
     300 real files: full precision matches Phase 0 exactly (cosine 1.00000, neighbours
     100%); half precision keeps only 94.6% of neighbours, so **full precision**. App side:
     `PeavAudio.input` (reflect padding, tested against the Python extractor) and
     `PeavEmbedder`, which runs **one part at a time over a batch of windows**: with three
     or more float32 parts loaded, Core ML's CPU path segfaulted under memory pressure
     (Resolve open, swap nearly full). Swift end to end vs Phase 0: median 1.000000, p1
     0.99984, min 0.99895, neighbours 99.9%; **4.0 s/file** on CPU, peak 2.5 GB.
   - ~~PE-AV as an analysis stage~~ Built (owner chose: GPU, only while idle). A separate
     lane in `AnalysisEngine`: batches of 32 sounds (`PeavBatch`), five parts loaded one at a
     time with `.cpuAndGPU`, only when the pace is `idle` or `requested`; the batch is
     cancelled and requeued as soon as that stops, and takes one of the per-sound worker
     slots while it runs. Model: `~/Library/Application Support/Earmark/Models/PEAV/
     PEAV*.mlmodelc` (installed, 4.2 GB). On the GPU it matches Phase 0 exactly (300 files:
     cosine 1.00000, neighbours 100%) at 0.44 s/window, 3× the CPU.
     **Telling Earmark's GPU use from other apps':** Core ML's GPU time is *not* reliably
     credited to Earmark's process in the GPU driver's per-client stats (during a batch at
     96–99% GPU, no process was credited; once a system agent, CoreServicesUIAgent, got
     ~0.67). So `SystemMonitor.sample(ownGPUWork:)`: without a PE-AV batch, other apps' GPU =
     total utilisation (as before); with one, other apps' GPU = GPU time credited to every
     *other* process. Checked 2026-10-23 at full speed: total GPU 0.96–0.99, other_gpu
     0.00–0.01. Not yet checked: a Resolve export during a PE-AV batch (Resolve uses Metal
     directly, so its time should be credited to it).
     **"Run at Full Speed Now" now also runs on battery** (owner asked to run on battery;
     heat and Low Power Mode still stop it). It isn't remembered after a relaunch; for
     testing, `open Earmark.app --args -analysisMode fullSpeed` sets it for one launch.
     Batches: up to 128 files or 256 windows (each window waits between parts as a 1.8 MB
     state); with 32-file batches, loading the five parts took about half of each 89 s batch.
     Estimate for the whole library at 128: ~8 h. Log: `Logs/analysis2-*.csv` with
     other_gpu, total_gpu and peav_running.
   - **PE-AV on the real library (2026-10-24):** a GPU prediction error ("Unable to compute
     the prediction using ML Program") stopped the stage for a whole night, because any
     model error disabled it until relaunch. Fixed: errors other than a missing model retry
     after 10 min and go to `Logs/errors.log`; a window the GPU can't compute is retried on
     the CPU; only a file both fail gets an error (the rest of the batch goes on). Then a
     batch of short sounds took 35 min for 128 files with the GPU nearly idle: with flexible
     lengths, the GPU path (MPSGraph) compiles a new graph on the CPU for every new window
     length. Now **full 10 s windows run on the GPU and shorter windows on the CPU**:
     2.1 s/sound on long-file packs, GPU 73% busy, no failures. Remaining on 2026-10-24
     ~10:00: 4,836 sounds ≥ 10 s and 23,387 shorter; rough estimate ~6 h.
   - Status bar: per-stage percentage, a progress bar (least finished stage) and the time
     left. The first version sampled every tick, so between batches the estimate kept
     climbing (25 → 44 h) and looked like a hang; it now measures between batch completions.
   - **PE-AV is too slow for the owner (max 12 h wanted); postponed, runs only when idle.**
     Measured per batch (`Logs/errors.log`, "PE-AV batch:"), on long-file packs:
     ~95 sounds / 256 windows (≈245 full 10 s) in ~185 s: GPU 120 s (≈0.47 s per full
     window), decode 33 s, CPU (short windows) 14–27 s, model loading 10–12 s, all one
     after another. That's ~0.5 sounds/s, i.e. ~15 h for the library. 1,323 of ~28,800
     done on 2026-10-24 10:12. Plan for later, in this order:
     1. Overlap: decode the next batch and run the short (CPU) windows while the GPU works
        on the full ones. Removes ~45–60 s of 185.
     2. GPU time is mostly the codec encoder (PEAVEmbed: 0.32 of 0.44 s per window). Try
        PEAVEmbed in float16 with the transformer parts in float32 (parity test first;
        whole-model float16 failed at 94.6% neighbours).
     3. Short windows: ~23,400 of them, avg 1.8 s; measure their CPU cost per window.
     Estimate with 1–2: GPU ~19k full windows × 0.47 s ≈ 2.5 h, CPU in parallel → ~4–6 h.
   - **Find Similar Sounds** (first Phase 3 feature, from CLAP): `SimilarityIndex` (core,
     tested) holds every current CLAP vector (~29k × 512, loaded on first use, rebuilt when
     more arrive) and ranks by cosine. Detail pane button and list context menu switch the
     list to "Similar to …": the sound first, then its 100 nearest, with a Match column
     (shown via column customisation; conditional columns need macOS 14.4). Format twins
     already hidden and byte-identical copies are left out. On the library's 4,948
     UCS-labelled sounds, the 5 nearest share the subcategory 56% and the category 66% of
     the time (Phase 0: 53–56% / 69–72%). Clearing it rebuilds the sidebar list (a removed,
     selected row otherwise stayed drawn).
   - **Player fixes (owner's feedback, 2026-10-25):** play/pause (no pause before), a stop
     button, time shown while paused, the waveform as an AppKit view (click: move the
     playhead, playing keeps playing, paused stays paused; drag the playhead: scrub; drag
     elsewhere: select), Play with a selection plays it, Clear Selection also lets playback
     run past the range, Space pauses/resumes. **Root cause of the dead buttons** (Play,
     Clear Selection): inside the detail pane's ScrollView under the toolbar, SwiftUI
     hit-tested the player's controls several points off what was drawn, and `.onDrag`'s
     area on the file chip sat a toolbar's height too high, over the player. Now the pane
     scrolls only when its content doesn't fit (`DetailScroll`) and the file chip drags via
     an AppKit view (`FileDragArea`). Verified with real mouse clicks (full-screen control);
     clicks sent to a background window are unreliable for testing SwiftUI controls.
   - Disk: only ~13 GB free on 2026-10-23 evening. Converting PE-AV used ~12 GB in
     `models/build` (could be trimmed to the float32 parts) plus 4.5 GB of installed models;
     45 GB of coremltools temp compiles from crashed runs were deleted. The rest of the drop
     (from 156 GB) wasn't from this work.
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
