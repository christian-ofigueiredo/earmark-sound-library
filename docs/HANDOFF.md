# Earmark: handoff (2026-10-27)

Notes for continuing in a new chat (for example Claude Code on the owner's Mac).
Read `CLAUDE.md` and `docs/PLAN.md` first; this file says where the work stopped.

## Rules from the owner (keep these)

- **Ask the owner before changing anything** (code, docs, repository, settings).
  Work on branches; merge to `main` only when the owner approves.
  Exception (owner, 2026-10-27): **the next five features need no plan or approval first.**
  Build each to the end, then tell the owner; if a real problem comes up, describe it and
  let the owner decide. Merging to `main` still needs approval. The five: similarity
  groups (done), refreshing the sound map for new sounds (done), suggested categories for single sounds
  (with a review list; done), sending a selected range to Resolve (done), and finding duplicates (done). All five
  were done on 2026-10-27: the old rule applies again.
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

The repository was renamed sound-library → earmark-sound-library on 2026-10-28 (the old
address redirects). The local folder is still `~/Documents/sound-library`.

**2026-10-29: the `alpha2` branch** (from `main`/`phase1` at 07ed061) is where the second
alpha is built. The owner approved, in their words: implement FCPXML and "start porting it to
Rust so we can have new Mac version and the Windows version". On it so far:
- Timeline files (`docs/timeline-file-plan.md`): `EarmarkCore/TimelineFile.swift`,
  File ▸ Save as Timeline File… (⇧⌘T, `Earmark/TimelineFileExport.swift`) and the MCP tool
  `save_timeline_file` (writes to `~/Movies/Earmark`). Unit tests pass; the import into
  Resolve is still to be checked with the owner (it needs their open project switched).
- The Rust engine (`docs/rust-engine-plan.md`): `engine/`, a Cargo workspace. Step 1 (UCS,
  CSV, metadata reading and normalising) is ported. `engine/parity/compare_metadata.py`
  compares it with the Swift code on a real folder (read-only); `.github/workflows/engine.yml`
  tests it on macOS, Windows and Linux. Cargo comes from Homebrew's rustup
  (`/opt/homebrew/opt/rustup/bin`, not on the shell's PATH).

## Where the code is

- `main`: Phase 0 (Python tools in `phase0/`, CI in `.github/workflows/checks.yml` and
  `mac-selftest.yml`), plan and docs.
- `phase1` branch: the Swift app in `app/` (SwiftPM, tools 6.0, macOS 14+, Swift 6 mode,
  GRDB 7.11.1), plus `.github/workflows/app.yml` (macos-26: `swift build` + `swift test`
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
    Resolve (the file URL); Space, Return or double-click plays; auto-play toggle.
  - `RecordTable.swift`: the sound and song lists, an AppKit table (see Gotchas).
  - `MusicView.swift`: folders, BPM range filter with half/double time, key filter with
    compatible (Camelot) keys, "Or relative" column, "Find songs that mix with this".
  - `SharedViews.swift`, `Waveform.swift` (AVAudioFile peaks via vDSP; click to play from
    a point, drag to select a range), `AudioPlayer.swift` (AVAudioPlayer, range playback),
    `MusicFiles.swift` (AVFoundation tags), `Display.swift` (formatting, search indexes).

## Next steps (in order)

1. ~~Get the app compiling on macOS.~~ Done: builds clean with Swift 6.4 on macOS 27 and on the
   GitHub macos-26 runner (`app.yml` green again since 2026-10-27). It had failed on macos-15
   from the loudness stage on, unnoticed: Swift 6.1 gave up type-checking two closures, and
   Xcode 16's SDK lacks the macOS 26 Liquid Glass APIs. Check the App run after pushing.
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
   - ~~Applying the owner-approved Sound Ideas folder → UCS mapping (from the C CSVs)~~
     Superseded by **Map Folders to Categories** in the app (see Phase 3 below): the owner
     picks a category per folder there, with suggestions, instead of filling the CSVs.
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
   - **PE-AV speed, 2026-10-25** (owner wants ≤ 12 h for the library):
     GPU and CPU groups run side by side per part; the next batch is decoded while one runs;
     the queue interleaves long (≥ 10 s, full windows → GPU) and short sounds (→ CPU) ~1:6 so
     both are busy; batches up to 256 sounds or 256 full windows' worth of audio.
     Measured at full speed (on battery): 768 sounds in ~17 min, 0.76 sounds/s (was 0.46)
     → ~9.5 h for the 26k left. Each batch is CPU-bound: GPU ~45–54 s, CPU 260–335 s for
     ~220 short windows (1.2–1.5 s each, though one alone measured 0.45–0.55 s in Python).
     Tried and rejected: PEAVEmbed in float16 (98.5% neighbours kept, fails parity).
     Ruled out: per-length recompiling on the CPU (+0.05 s per new length only).
     Next if more speed is needed: several CPU model instances for the short windows (same
     part, so the mmapped weights may be shared; check memory), or measure why short windows
     are 3× slower beside the GPU.
   - **Map Folders to Categories, 2026-10-25** (now Folder Categories, see below; File menu, the sidebar under Not Categorised
     Yet, or "Choose a Category for Its Folder…" on an uncategorised sound): lists the folders
     whose sounds have no category, largest first (214 folders, 23,879 sounds on SoundFX).
     Each row has a suggestion from `FolderSuggester`, the top 3 plus Other… (the whole UCS
     list, searchable by name, CatID and synonyms), the reason ("name “footstep” · files
     “foot walk” · 62% of similar sounds", orange "listen first" when nothing but a few
     similar sounds agree or another category is named just as well), and a play button (a
     different sound each click; selecting a row plays one, so the arrow keys review folders).
     Nothing is saved until a folder is ticked (Space ticks the selected rows) and Save
     Categories is pressed. Rules live in `folderRule` (schema v5) and apply on load to sounds
     with no category of their own, from the nearest folder with a rule
     (`categorySource` = "your folder rule"); "Your Folder Categories" lists them with
     Change… and Remove. Suggestions are computed while the window is open, folders on screen
     first. Tested in the app (tick, pick, Other…, save, change, remove, open from a sound);
     the test rules were removed, so the owner's database has none yet.
   - **Automatic folder categories, 2026-10-26** (owner: "I want everything automated… I'd
     rather change it later"): `FolderGuesser` (app) gives every folder whose sounds have no
     category its best suggestion, without asking, in the background after the library is
     read (status bar "Guessing categories for folders: n of N"; 214 folders in ~40 s). Guesses
     live in `folderGuess` (schema v6: CatID, runners-up, reason, unsure flag, how many sounds
     were analysed, `FolderSuggester.version`) and are made again when the version is bumped
     (bump it whenever suggestions change), when many more of the folder's sounds have been
     analysed, or for new folders after a scan; guesses of folders that no longer need one are
     dropped. Precedence on load (`FolderRules.apply`): the file's own category, then the
     user's choice for the folder or one above it, then Earmark's guess. The window is now
     **Folder Categories** (File menu, sidebar): tabs Guessed by Earmark (unsure first; the
     category menu saves the user's choice at once), Your Choices (Change…/Remove; Remove goes
     back to the guess) and Not Categorised (folders with no guess, tick and save as before).
     Sidebar: "Guessed by Earmark" lists the guessed sounds (23,879 on SoundFX); the detail
     pane says "Guessed by Earmark" with Change… (no "unsure": the owner, 2026-10-26, found
     it not needed; Folder Categories still marks unsure guesses). The sound signal only
     learns from categories that came with the files (`FolderSuggester.labels`).
   - **Folder suggestions improved, 2026-10-26** (owner asked about vendor names, Street
     Basketball and Pickups). Signals: the folder's name; the words at least 30% of its files
     share (file name, FXName, description, keywords; of a UCS file name only the FXName;
     descriptions many folders share, a vendor's collection names like "Sports & Recreation",
     at 0.35; describing words like "Short", "Key A#" skipped); the sound (CLAP neighbours with
     a category from their files). Rules added: vendor/pack words (the sounds' designer, the
     library's top folder above a deeper folder) count only when the sound agrees; a word in
     3+ subcategories of a category gives all of them a synonym's point, and the one named
     after it keeps its own ("Trucks": TRUCK VAN & SUV); the parent's category lock is
     released when the folder repeats it and names another ("Creature Footsteps"), or when
     the parent isn't just the category's name and most files name a subcategory of another
     ("Human Vocal Full Sets/Male_…" → VOICES / MALE; never on a word that names a category,
     those are materials: "Footsteps/Glass" stays FOOTSTEPS though DOORS / GLASS exists);
     under a lock the parent's words name a group, so "Monsters & Creatures/Ghosts" is
     ETHEREAL, not MONSTER (their synonyms still count: "Footstep" → FOOTSTEPS / HUMAN);
     sound shares shrink when under a quarter of the neighbour places have a category (three
     sword neighbours aren't "100% swords"); MISC/GENERAL loses only to evidence for the subcategories at the
     top; ARCHIVED is never suggested; the last of the 3 options comes from another category
     when the others share one; words split as UCS spells them (StreetBall, Sci-Fi → scifi,
     Braaams → braam, Whooshes → whoosh, Zombies → zombie and zomby). Tried and dropped (measured worse): discounting a
     word by how many categories use it, "misc" as a stop word, a bonus for words in the UCS
     explanation, ignoring file words that repeat the name.
     **Accuracy** (`earmark-parity folders <copy of library.sqlite> --truth local/folder_truth.tsv`):
     43 vendor-labelled folders 79% top 1, 93% top 3, 91% category (was 79/86/91); 107
     uncategorised folders checked by hand 67% top 1, 80% top 3, 79% category (was
     47/63/70). The hand-checked list had few Footsteps folders, and the first version broke
     them (files "Foot_Glass_…" released the lock): compare every folder with the last
     version too (`--list 0 --tops` in a worktree of the old commit and in this one; 2026-10-26:
     81 changed, 25 fixed and 3 broken among the hand-checked). The hand-checked list is the owner's library data: `local/` (git-ignored),
     judged from folder and file names without listening, alternatives allowed. 26 of 214
     folders are flagged "listen first". `--explain 0 <folder text>` shows each signal;
     `EARMARK_TUNING="pack=0,file=0.3,…"` switches parts off to measure them. Cases asked
     about: Boom Library packs no longer get DESIGNED / BOOM from the vendor's name, and Lens
     Distortions' risers no longer offer DISTORTION; Street Basketball went from AMBIENCE /
     MARKET to AMBIENCE / SPORT, not SPORTS / COURT (basketball is a synonym in five
     categories and nothing in the files separates them; Basketball, Baseball and Football
     have SPORTS in the top 3, flagged); Pickups is still METAL / HANDLE, now flagged "listen
     first" (game pickups; nothing points to GAMES / VIDEO). `SimilarityIndex.nearest` uses
     `vDSP_mmul` on macOS (the whole evaluation went from 195 s to 43 s).
   - Disk: only ~13 GB free on 2026-10-23 evening. Converting PE-AV used ~12 GB in
     `models/build` (could be trimmed to the float32 parts) plus 4.5 GB of installed models;
     45 GB of coremltools temp compiles from crashed runs were deleted. The rest of the drop
     (from 156 GB) wasn't from this work.
   - ~~Music tempo and key in the app~~ Done, 2026-10-26 (owner approved the plan; see
     models/README "Tempo and key results"). Beat This! (`final0`) and S-KEY converted to Core
     ML with exact parity; spectrogram, chunking, peak picking, Phase 0's tempo summary and the
     key labels ported to Swift (`EarmarkCore/MusicAnalysis.swift`, tested against a Python
     fixture of generated drum loops), `MusicAnalyzer`/`MusicModelStore` (`EarmarkML`). On 300
     of the owner's songs vs Phase 0: BPM within 2% 99.0%, key 100%. Songs are decoded at
     44.1 kHz and halved with `HalfRate` (a filter shaped like soxr's; Apple's converter alone
     gave 88%). In the app: a lane in `AnalysisEngine` for songs with no analysis at all
     (Phase 0's are never redone; an import that lands meanwhile wins), one song at a time in
     one of the governor's worker slots, CPU at background priority while you use the Mac,
     all compute units only while idle (a song running with the GPU is cancelled and
     requeued on the CPU when you come back), saved every few seconds with source "Earmark"
     and the same filters as the Phase 0 import (BPM 20–400; 2, 3, 4 or 6 beats per bar);
     silent or < 2 s songs are saved with no tempo or key; unreadable files go to
     `Logs/errors.log`, say so in the detail pane and are tried again after a relaunch. The
     list, detail pane and the sidebar count update in place (`AppModel.updateSongs`,
     `songsVersion`), without reloading the library. Models: `~/Library/Application
     Support/Earmark/Models/BeatThis.mlpackage` and `SKey.mlpackage` (installed on the owner's
     Mac; compiled beside them on first use). Tested end to end with six generated files in a
     temporary music folder (removed afterwards; the database matched its backup): 123.0,
     106.5 (variable 98.8–113.2) and 90.0 BPM as made, silence and a 1 s file saved empty, a
     corrupt file logged. Not exercised: the gentle path while you work (the owner's setting
     waits for idle) and the GPU → CPU switch. Open: how the app gets the models (as for
     CLAP); a song whose file changes keeps its old analysis (as rescans always did); a
     20-minute song holds ~450 MB while analysed; tempo confidence and the key's runner-up
     are worked out but not stored (no columns).
   - ~~Tempo and key corrections by hand~~ Done, 2026-10-26 (owner approved the plan). Detail
     pane: a "Change" menu beside Tempo (Double, Half, Set Tempo…, Beats per Bar ▸, Revert)
     and Key (Use Relative Key, Set Key ▸ with Camelot codes, Revert); a corrected value says
     "Set by you · Phase 0 found 123.5 BPM", and Analysis "Phase 0 · tempo corrected by you".
     The list's row menu does the same for every selected song (Double/Halve Tempo, Use
     Relative Key, Set Key ▸, Beats per Bar ▸, Revert to Analysed Values). Edit ▸ Undo/Redo
     (the window's undo manager). Sidebar: Tempo and Key ▸ "Corrected by You". Stored in
     `songCorrection` (schema v7) by file path, no FK, like folder rules: survives rescans,
     removing and re-adding the folder, Phase 0 imports and Earmark's analysis, none of which
     touch it; the song table keeps what was analysed, for Revert. `SongCorrections` (core,
     7 tests): edits are pure functions (`SongRecord.correction(after:)`); a part set back to
     the analysed value (Double then Half, relative twice, a typed tempo equal to it) is no
     longer a correction. Double/Half scale the "Changes" range; a typed tempo hides it. On
     load the corrections are laid over the songs (`AppModel`, also after Earmark's analysis
     comes in), so the list, filters, Camelot, sorting, search and Find Songs That Mix use the
     user's values; `isAnalysed` ignores them. Set Tempo… is an alert whose field starts
     empty (an alert's text field ignores a starting value on macOS), so its message says
     the current tempo. The row menu now also opens without a click (VoiceOver), on the
     selection. Checked in the app on one of the owner's songs (every menu, undo/redo, the
     sidebar list, a relaunch), then reverted; the database matched its backup.
   - ~~Export and import of analysis files~~ Done, 2026-10-26 (owner approved the plan;
     format in `docs/analysis-file-format.md`). File ▸ Export Analysis… (a sheet: which
     libraries, "Include sound embeddings"; a folder picker that refuses folders inside any
     library; one `<name>.earmark-analysis.json` per library; also in each library's menu) and
     File ▸ Import Analysis… (Earmark files and Phase 0's music_analysis.json, which replaces
     the old Phase 0 item; the sidebar's button too). Core: `AnalysisFiles.swift`, 7 tests
     (another "Mac" with files moved, renamed and changed). Sounds match by fingerprint; songs
     by a fingerprint read at export (128 KB each) among local songs of the same size, else
     path and size. Imports only fill gaps; local results, folder categories and corrections
     win; stale versions and changed files are skipped. After an import the engine re-reads
     what's done (`AnalysisEngine.reloadStatus`) so nothing is analysed twice. Full size on
     copies of the owner's database (`earmark-parity analysis-files <copy> <out>`): SoundFX
     237 MB in 2.7 s (written a batch of 2,000 sounds at a time; built whole in memory it
     peaked at 1.2 GB, now 300 MB), import 5.9 s (~800 MB peak, the file is read whole);
     every value equal, all 57,654 vectors bit-exact; a second import adds nothing. Not
     driven by me: the folder and file pickers (out of process), so the owner should try one
     export and import. Folder categories and corrections were only tested in unit tests
     (the owner has none yet).
   - ~~Sound map~~ Done, 2026-10-26 (owner approved the plan and chose 8 colours). A List |
     Map switch above the sound list (also View ▸ Sound Map ⇧⌘M; the choice is remembered):
     one dot per sound of the sidebar's choice (all, a library, a category, Similar…), sounds
     that sound alike close together; a search dims the others without moving them. Colours:
     the 7 biggest categories (inside one category: its subcategories) from the dataviz
     reference palette, every other one grey, no category hollow grey. Only 3 of those colours
     pass the all-pairs colour-blindness check; the owner chose 8, so pointing at a dot names
     it and the legend lights one category up (click; the folded ones from a menu; Show All).
     Click selects (Auto-play as in the list), ⌘/⇧-click adds or removes, drag selects an
     area, double-click, Space and ↩ play, ← / → skip, Esc clears; pinch or scroll wheel zoom
     (⌘-scroll on a trackpad), two fingers or ⌥-drag move, Fit; Play on hover (off by default,
     after 120 ms). Back in the list, it scrolls to the selection. Help ▸ Keyboard Shortcuts
     has an "On the Sound Map" group. Code: `SoundMapView.swift` (state, legend, the AppKit
     canvas: Core Graphics, a grid for hit tests), `EarmarkCore/SoundMap.swift`.
     **Look** (owner, 2026-10-27: "the dots are too big… small dots, gradient colours blending
     into each other, small lines connecting the dots, everything really fine, tech style"):
     dots of 1.4 pt radius (up to 4 as you zoom; the pointer still picks them within 6 pt);
     each sound linked to its 3 nearest in the embedding space by 0.5 pt hairlines in the mix
     of the two dots' colours (`SoundMap.Map.links`, ~62,000 for the library; links longer
     than 3.5% of the map are left out, as are ones shorter than the dots); a glow of the
     categories' colours that blends where groups meet (`MapGlow`: the lit dots splatted on a
     512² field, Gaussian blur with vImage, colour = weighted average, made once per layout,
     search, highlight or appearance and stretched with zoom, ~17 ms). The glow was toned down
     the same day (owner: "dim it down… as soft as possible"): sigma 2.6% of the map, at most
     20% opacity in dark and 11% in light, easing in with a smoothstep so small groups on their
     own get no halo, dithered so the faint wash doesn't band. Each lit dot is shaded 30%
     towards the colour around it at a narrower 1.2% (grey ones 50%); grey recedes (0.40 in dark, 0.72 in light); a faint
     grid fixed to the map; near-black background in dark mode, white in light. Selected dots
     get a pip in the text colour in their middle (a ring too while ≤ 40), so a big selection
     reads as a stipple, not a patch. A drag that starts on a dot also selects an area. The
     pointer's ring, its label, the selection and the playing ring are drawn by an overlay
     view, so moving over dots doesn't redraw the map (~15 ms for the whole library; 0 draws
     of the map while hovering).
     Layout: a Swift port of umap-learn 0.5 with Phase 0's settings (cosine, 15 neighbours,
     min_dist 0.15, a/b from `find_ab_params`, 200 epochs from 10,000 sounds, else 500) on
     PE-AV + CLAP combined as Phase 0 did; PCA start instead of spectral and its own seeded
     random numbers (same sounds, same map; not Python's); under 20 sounds PCA only. 8 tests
     (6 for the layout and its links, 2 for loading the vectors).
     Against umap-learn (`models/parity_map.py`, share of the 15 nearest kept): Ambience 0.559
     vs 0.552, Designed 0.438 vs 0.439, all 28,827 sounds 0.323 vs 0.326 (11.5 s vs 23.1 s).
     In the app the whole library takes ~15 s in the background with a progress bar; a
     category's map a second or less. The last 8 layouts are kept for the session, so going
     back to one is instant. Memory: the vectors (177 MB) are loaded only while the map shows;
     with the all-sounds map Earmark is ~460 MB (peak ~480 MB) and back to ~265 MB in the list
     (it was 1.45 GB before the fixes under Gotchas). Checked in the app with real mouse
     events (`mouse` tool, CGEvent): selection, ⌘-click, area, scroll-wheel zoom, both pans,
     Fit, search dimming, the legend and its menu, a category map, Space, Play on hover,
     ⇧⌘M both ways, Music and back, the help window. Not checked: pinch (can't be made with
     CGEvent) and ← / → on a long sound (the list's code).
     **New sounds** (2026-10-27, second of the five features): sounds of the map's choice
     analysed since it was made are counted in the bar above it, "Add 37 New Sounds"; the
     button makes the map again with them (`SoundMapState.addNewSounds`: vectors read again,
     every cached layout dropped). Not automatic, so the map doesn't change under the pointer.
     A fresh layout rather than one grown from the old: it starts from the same seeded PCA,
     so the rest stays about where it was. Measured on the library with 5% new
     (`earmark-parity map-grow` while it existed, since removed): old dots moved a median 0.14
     (ambiences) and 0.24 (designed) of the map's spread; grown from the old map (new dots
     among their neighbours, UMAP again for 50–200 epochs at learning rate 0.1–1) 0.20–0.33,
     no steadier and no better at keeping neighbours. Small maps change more (a few hundred
     sounds). Sounds still waiting for analysis: "12 not analysed yet". Checked in the app by
     taking one sound's PE-AV row out while the map loaded, putting it back and pressing the
     button.
   - ~~Similarity groups~~ Done, 2026-10-27 (first of the five features built without a plan
     first). Inside each subcategory, sounds that sound alike are grouped and named; the
     sidebar shows them under the subcategory (when it has more than one), the list and the map
     show one when picked, the map colours a subcategory's sounds by group (legend: group
     names), the pointer's label and the detail pane name a sound's group (with the words most
     of its files share, "#sewer"). **Method** (`EarmarkCore/SoundGroups.swift`): Phase 0's
     space (PE-AV + CLAP combined, centred on the subcategory) laid out in 10 dimensions by UMAP
     (min_dist 0, `SoundMap.reduce`; PCA under 30 sounds), then **Ward's clustering into
     √(n/8) groups, 2–12** (under 20 sounds: one group; groups under 5 join their nearest).
     Phase 0 used HDBSCAN: ported exactly (`HDBSCAN.swift`, same labels as scikit-learn 1.9 on
     test data), and it behaves as Phase 0's on the real library (adjusted Rand index Swift vs
     Python 0.36–0.82, the same as Phase 0 against itself with another seed; `models/
     parity_groups.py`), but at this size it made 120 groups of whooshes and 356 of human
     footsteps, nearly all tiny, 5–15% left out (Phase 0 had only tried 243 whooshes). Ward on
     the same layout puts every sound in a group, keeps sizes even, and keeps as many of each
     sound's 10 nearest in its group as anything tried (92–97% on six large subcategories;
     HDBSCAN's tiny groups 56–68%). Ward matches scikit-learn's on test data. **Names**:
     Phase 0's: the AI words (99 descriptors, their PE-AV + CLAP text embeddings exported from
     Phase 0's caches, `Resources/group_words.bin`, `models/export_groups.py`) nearest the
     group's centre, less 0.6 × the subcategory's average and 0.3 × the library's, after
     "short"/"long" from the sounds' lengths; one word per family of near-synonyms (by hand:
     the embeddings don't tell synonyms apart); a duplicate name takes the next word.
     Keywords: Phase 0's TF-IDF of file names, FX names, descriptions and keywords, leaving out
     CatIDs, library/manufacturer/designer/pack words and any word most of the subcategory's
     groups share. Examples: footsteps "Long · Splashy · Watery #sewer", "Long · Crunchy ·
     Sparkly #weeds #leaves"; male voices "Long · Vocal · Breathy #tiredbreath". Not done:
     Phase 0's shape features (brightness, envelope; they'd need another pass over every file),
     so only length gives shape words.
     **Storage** (schema v8, `SoundGroupStore.swift`): `soundGroupSet` (per subcategory:
     version, sounds grouped, changed since, `edited`), `soundGroup` (Earmark's name, the
     owner's `userName`, words, position), `soundGroupMember` (sound id + fingerprint, no FK to
     sound). **Keeping them** (`SoundGroupPlan`, `GroupBuilder` in the app): after loading and
     every 3 minutes while analysis brings embeddings, subcategories with no groups are
     grouped; new sounds join the group with the nearest centre and gone ones leave; a
     subcategory is grouped afresh when a quarter of it changed or `SoundGroups.version` was
     bumped, **unless the owner changed its groups** (rename, move, new group, merge), which
     Earmark then never redoes by itself (Regroup … Automatically does, after asking). Whole
     library: 238 subcategories, 605 groups, 32 s on one core at background priority, peak
     303 MB (vectors in `PageBuffer`s; with plain arrays it was 481 MB and stayed 70 MB up).
     **The owner's changes**: detail pane "Move" menu (to another group, New Group…, Rename);
     list row menu (Move to Group ▸, New Group from Selection…); sidebar group menu (Rename…,
     Merge Into ▸, Regroup "…" Automatically…). Checked in the app (through accessibility, no
     mouse): sidebar, a group's list, a subcategory's map by group, the detail line, Rename,
     Move, New Group; the test changes were then undone (Human regrouped). Not checked in the
     app: the sidebar's and list's right-click menus (accessibility can't open them; same
     calls as the detail pane's, which are tested). Groups aren't in analysis files yet (made
     again on the other Mac; the owner's changes don't travel).
   - ~~Suggested categories for single sounds~~ Done, 2026-10-27 (third of the five).
     **Measured first** (`earmark-parity votes <copy> --truth local/folder_truth.tsv`): a
     sound's 15 nearest sounds in other folders (PE-AV + CLAP; its own folder doesn't vote,
     since one folder guess gave them all their category) voting for their categories name a
     file's own UCS category only 22% of the time (top 3 31%), and where that vote disagrees
     with Earmark's folder guess on the hand-checked folders (14,500 guessed sounds, guesses
     67% right) it is right only 20%, and 53% of those flags hit a correct guess: as Phase 0
     found across packs (7–9%), not usable alone. Voting only with files' own categories was
     worse. **What works:** let the vote choose only among the folder guess's runners-up
     (`FolderGuess.alternatives`) when it's clear (≥ 60% for one, < 10% for the current): 578
     hand-checked sounds flagged, the folder guess wrong for 71% of them, the vote right for 62%
     (the guess for 29%); 755 sounds in the library. Thresholds 0.5/0.7 give 913/610 sounds
     at 56%/69%. Since the owner wants categories automatic and corrected later, **Earmark
     applies these** (`SoundCategories.guesses`, `SoundGuesser` in the background: ~5 s, after
     the folder guesses and with new analysis; only when its inputs changed). Biggest moves
     on the library: Human Misc → Voices Male (327, the hand-checked folder says male voices),
     Footsteps Misc → Footsteps Human (119), Sports Equipment → Sports Ambience (47).
     **Storage** `soundCategory` (schema v9): sound id + fingerprint, CatID, `byOwner`, the
     vote's share and the folder guess it replaced. **Precedence** (`SoundCategories.apply`
     after `FolderRules.apply`): the owner's choice for a sound > the file's own > the owner's
     folder rule > Earmark's guess from the sound > Earmark's folder guess. **App:** sidebar
     "Guessed from the Sound" (worth a listen) and "Chosen by You"; detail pane "Guessed by
     Earmark from how it sounds" (help: the folder's guess and the vote) with a Change menu
     (For This Sound…, For Its Folder… where a folder's category can reach it, Use Its
     Folder's: …, Remove Your Category); list row menu Set Category… (several sounds at once)
     and Remove Your Category; the UCS chooser (Folder Categories' Other…) selects the only
     match left by a search, so Return chooses it. The owner's per-sound categories travel in
     analysis files (`category` on a sound; docs/analysis-file-format.md). Checked in the app
     (accessibility): the sidebar rows, a re-guessed sound's pane and menu, For This Sound… with
     the chooser, Chosen by You, Remove Your Category (Earmark's guess came back on its own);
     the test choice was removed. Not checked in the app: the list's row menu (right-click).
5. Phase 4:
   - ~~Resolve Studio bridge for a selected range~~ Done, 2026-10-27 (fourth of the five).
     The player's new button (detail pane, sounds and songs) and File ▸ Add to DaVinci Resolve
     Timeline (⌘T) put the file, or the waveform's selection, on the timeline open in Resolve:
     the original imported once into an "Earmark" bin and appended as a cut of it (in/out,
     no new file), audio only, at the playhead, on the first audio track free there for its
     length (stereo files on stereo tracks, mono on mono or stereo; locked tracks skipped; a
     new track of the file's kind if none), then the playhead moves to the cut's end so the
     next one follows. The status bar says where ("… track A2"); failures explain (Resolve
     closed or scripting off: Preferences ▸ System ▸ General ▸ External scripting using:
     Local; no project; no timeline; the free Resolve has no scripting). `ResolveBridge.swift`
     runs a small Python script with Resolve's own interpreter
     (`…/DaVinci Resolve.app/Contents/Applications/ResolvePython`, Resolve 21.1+; the request
     as JSON on stdin, one JSON line back). Checked against Resolve Studio 21.1.2 in a
     temporary project (made, used and deleted by script; Resolve quit afterwards, as it was
     before): imported audio takes the project's frame rate; `endFrame` is exclusive;
     fractional frames are rounded, so cuts are frame-accurate (the selection is rounded
     outwards); `recordFrame` counts from 00:00:00:00 (01:00:00:00 at 30 fps = 108000);
     `trackIndex` is 1-based; `mediaType` 2 = audio only; the "Earmark" bin is reused; drop-frame
     timecode is converted both ways (not tried in Resolve). From Earmark: a 36 s sound
     through the File menu (placed on A2 because A1 was busy at the playhead), and the no
     timeline and Resolve-closed messages. Not done: the free Resolve's fallback (an FCPXML
     with the cut) from the plan; the owner has Studio.
   - ~~Duplicates~~ Done, 2026-10-27 (fifth of the five). Sidebar "Duplicates" (under the
     libraries) lists sounds that are in the libraries more than once, each set together;
     the detail pane names the others: "Copies of this file" (byte-identical: the same
     fingerprint, anywhere) and "The same recording" (by the audio), with their folders, to
     play, drag or show. Earmark only shows them, never deletes. Format twins (MP3 beside the
     WAV) stay as before. **Threshold measured first** (`earmark-parity duplicates <copy>`,
     each sound's nearest, PE-AV + CLAP): byte-identical copies are cosine 1.0000; every pair at
     ≥ 0.999 (289) and 0.998–0.999 (10) had the same length, and they are the same recording
     reused under another name (Sound Ideas: a car loop in Automobiles and in Trucks, door and
     fire loops under several numbers, a splat in two packs); from 0.995 down, versions come
     in (dry and wet, construction-kit layers, takes). So `Duplicates`: cosine ≥ 0.998 and
     lengths within 1% (0.02 s for short sounds), joined into sets. On the library: 410 sounds
     are copies (204 sets) and ~550 more the same recording: 958 sounds. The near pairs come
     from `SoundGuesser`'s neighbour search (one search for both); copies from the fingerprints
     on every reload. Checked in the app (accessibility): the sidebar row, the grouped list,
     both detail-pane lists.

- **MCP server** (owner approved the plan, docs/mcp-plan.md, 2026-10-27): `earmark-mcp` in
  `Earmark.app/Contents/MacOS`, which MCP clients start (stdio; official MCP Swift SDK 0.12.x,
  pinned to the minor version). Tools: `library_overview`, `search_sounds`, `get_sound`,
  `find_similar`, `list_groups`, `show_in_earmark`, `resolve_status`, `add_to_resolve`; the
  server's instructions tell agents how to use them. Read-only for the libraries and Earmark's
  data, works with Earmark closed: it opens the database read-only (`LibraryDatabase(path:,
  readOnly: true)`, no migrations; tables missing from an older database read as empty) and
  reads it again when the app has saved (file dates, at most every 10 s). Code: `EarmarkMCP`
  (tools in `EarmarkTools`, definitions in `ToolList.swift`, `EarmarkServer`), shared pieces
  moved to the core for it: `SoundCatalog` (the sounds as the app shows them, the search),
  `SoundText` (names, format text, search text), `ResolveBridge`. **Database now in WAL mode**
  (GRDB `DatabasePool`, busy timeout 5 s) so the server reads while the app writes; the
  same-recording pairs are saved (`soundDuplicate`, schema v10) so the server sees them.
  **Resolve:** `add_to_resolve` takes items {sound_id, start, end, at (seconds from the
  timeline's start, or a timecode), track ("new": tracks named Earmark, the default for
  agents; "free"; a number)} and `preview`; the bridge now places several at once, can preview,
  reports Resolve's status, and puts the playhead back where the editor had it (appending moves
  it; ⌘T still moves it to the end of the cut). `show_in_earmark` opens `earmark://sound/<id>`
  (Info.plist URL type; a link that launches Earmark is shown once the library is read). Help ▸
  Connect an AI Agent… shows the setup line for Claude Code and the desktop app's config, with
  copy buttons. **Checked:** 4 protocol tests through the SDK's client (in-memory transport, a
  fake Resolve); a scripted stdio client on the owner's library (all tools; 1–2 s for the first
  load, then 0.01–0.2 s; errors read as messages); the server reading while the app started
  and wrote (6 rounds, no errors) and with Earmark closed; show_in_earmark with Earmark running
  and closed; in a temporary Resolve project (deleted, Resolve quit): status, preview and real
  placement (new Earmark tracks when busy, same track when free, a range's in point, a track
  number, a timecode), the preview matching the real cuts to the frame, the playhead left in
  place, and ⌘T afterwards. Not done: registering the server in the owner's Claude Code or
  desktop app (their config; the help window gives the lines).
- **App icon** (owner, 2026-10-27): `app/Icon/AppIcon.icon`, an Icon Composer file (Xcode's
  Icon Composer opens it): a white page with its top-right corner folded down (the earmark,
  violet to blue) and a waveform in the sound map's colours, on dark blue; the waveform is a
  Liquid Glass layer. `scripts/build-app.sh` compiles it with `actool` into `Assets.car` and an
  `AppIcon.icns` for older systems (`CFBundleIconName`/`CFBundleIconFile` AppIcon).
  `app/Icon/preview.png` is how macOS 27 draws it.

## Gotchas learned

- **macOS 27 keeps freed large memory blocks counted as the app's.** malloc keeps freed large
  blocks to use again; they stay in the footprint (compressed when memory is short), and
  `malloc_zone_pressure_relief` returns nothing (tested: a 177 MB block freed, footprint
  unchanged; `MallocLargeCache=0` does give it back). The sound map's first version left
  Earmark at 1.45 GB. Now its big buffers are `PageBuffer`s (mmap, unmapped when freed): the
  combined vectors (one buffer in id order, read from the database one sound at a time with
  `forEachVectors`) and the neighbour search's score blocks (64 rows at a time, 7 MB each).
  The map is bit-for-bit the same as before (old and new code compared on test data).
- **Both sidebars on screen at once** (about 1 launch in 8 with the sound map drawing at launch,
  never in 14 without): `SectionViews.sync` ran before SwiftUI had made the sidebar lists,
  found none, and nothing hid the other section's later. `LibraryView.syncOnceBuilt` tries
  again every 0.1 s until both exist (in 16 launches the second try was needed twice, and no
  overlap was left).
- **Since macOS 14 a view draws outside its bounds** (`clipsToBounds` defaults to false): the
  map's glow, stretched by zooming, covered the sidebar and the detail pane, and the dirty
  rectangle passed to `draw` can be the whole window. The map's views set `clipsToBounds`.
- **Drawing in a view is far faster than drawing into a bitmap.** AppKit hands a view's Core
  Graphics drawing to the GPU; the same 28,827 dots took 6 ms there and 540 ms in an
  off-screen `CGContext` (CPU). To avoid redrawing, split into views (the map's overlay)
  rather than caching a rendered image.
- **macOS 27's batched line drawing crashed the app** (2026-10-27): with a subcategory's map
  coloured by group, `CGContext.strokeLineSegments` (one call per colour pair) failed an
  assertion inside QuartzCore ("color_element_itr != _colors.end ()", cg-draw-lines.cpp) on its
  rendering queue, every time. The links are now a path per colour (`move`/`addLine`,
  `strokePath`): no crash, and the whole map still redraws in 14–15 ms.
- **Testing without the mouse:** when the owner is at the Mac, CGEvent clicks land on whatever
  window is in front. The scratchpad's `diag` has accessibility tools that work in the
  background: `axselect "<sidebar row>"` (sets the outline's selected rows; pressing a row
  only toggles its disclosure), `axrowselect <n>` (a row of the visible list), `axmenu
  "<menu button>" 1 "<item>"` (a SwiftUI Menu's item), `axresize w h` (forces a redraw).
  Right-click menus can't be opened this way (AXShowMenu fails on SwiftUI's rows).
- **Testing the map:** the computer-use tool's background click also sends a second
  mouse-down outside the view (at −251, −89), which cleared the selection; the canvas now
  ignores events outside itself. Use the scratchpad's `mouse` tool (CGEvent: click, ⌘/⌥
  modifiers, drag, line or pixel scroll) for the map. Don't attach lldb to the running app
  and then stop it: stopping lldb mid-expression killed Earmark (a breakpoint trap).

- **The app looked pre-macOS 27 (old window buttons and controls, no Liquid Glass)** because
  SwiftPM wrote the deployment target as the SDK in the binary (`otool -l … LC_BUILD_VERSION`
  said "sdk 14.0"), and macOS draws apps built for an old SDK in the old design. Apple: apps
  built with the 2027 SDK get the macOS 27 look automatically. `scripts/build-app.sh` now
  records the SDK actually used with `vtool -set-build-version macos 14.0 <xcrun sdk version>`
  (minimum stays 14.0). Check with `otool -l app/build/Earmark.app/Contents/MacOS/Earmark |
  grep -A4 LC_BUILD_VERSION`. On top of that (2026-10-26): the status bar sits under each
  list (`edgeBar`, `safeAreaBar` on macOS 26+) so the sidebar runs the window's height;
  tables don't draw the scroll edge effect, so bars keep the bar material; player buttons are
  round Liquid Glass (`.buttonStyle(.glass)`); the waveform turns grey in an inactive window
  (`controlActiveState`), as the system dims everything else; Folder Categories has its tabs
  in the toolbar. Menu icons: macOS 27 shows few by default, nothing to do.
- **Section switch** (owner, 2026-10-26: stuttered, then "remove the short pause too"):
  rebuilding a section (split view, tables, layout) took ~0.2 s of main thread. Now both
  sections stay built in one split view (`LibraryView`: each column a ZStack of both), the
  search field and auto-play button are shared and follow the section. `AppModel.show(_:)`
  (owner, 2026-10-26: "rough… make it fade, it can be a little slower"): the switch's pill
  (`switchSection`) slides while the shown section fades out (`sectionFaded`), the section
  changes while nothing shows (its layout, the one costly moment), then the new one fades in.
  SwiftUI parts fade with SwiftUI opacity; the AppKit lists and sidebars with Core Animation
  (`SectionViews.fade`), which runs off the main thread.
  Don't hide a section with `.disabled`, `.allowsHitTesting`, `.accessibilityHidden` or
  `.focused`, and don't give `.searchable` a binding or prompt that changes with the section:
  with SwiftUI tables, each changed the environment of every cell (each its own
  `NSHostingView`) and the switch went back to ~0.5 s. The search binding is `AppModel.search` (stable), the prompt
  "Search". The switch is a custom Liquid Glass control (`SectionSwitch`:
  `GlassEffectContainer`, a blue-tinted glass pill (no painted fill or gradient, and the
  same font weight on both segments: the owner found the bold and the gradient dated), the
  toolbar's shared glass hidden with `sharedBackgroundVisibility(.hidden)`); before macOS 26,
  a segmented picker. **The pill is one view** that moves and resizes to the chosen segment
  (frames from `onGeometryChange`). It used to be a pill per segment cross-faded with
  `matchedGeometryEffect`; going to Sound Effects (left) the new pill came in under the old
  one and the two glass shapes blended mid-way: a stutter in that direction only (owner,
  2026-10-26), with no dropped frames (measured). The section now changes only after the
  pill's slide (`SectionSwitch.slide`, 0.28 s): changing it mid-slide (the sound list's
  layout costs more than the songs') was the first suspect.
- **One blue hue** (owner, 2026-10-26: in dark mode the waveform, selected row and buttons
  were blues of different hues; "the angle" must match, brightness may differ). Defined in
  `SharedViews.swift`: `earmarkSelectionBlue` is the list selection's own colour
  (`selectedContentBackgroundColor`, #0064E1 light / #0059D1 dark) for things with white on
  them (selected rows, the section pill, Auto-play on, the player buttons);
  `earmarkBlue` is the same hue, lighter in dark mode (#388DFF, 4.6:1 on the dark
  background; the deep blue as text was 2.4:1 and hard to read) for blue text, symbols,
  buttons (`.tint` on all windows), the waveform (solid) and the playing mark. Both follow
  the system accent, as the selection does.
- **The big lists are AppKit tables** (`RecordTable.swift`; owner, 2026-10-26: "fix the 1–2 s
  freeze when the list changes a lot"). SwiftUI's `Table` went through every row on each
  change: clearing a search inserted the 28k rows one by one, AppKit building and measuring
  a row view for each (automatic row heights): ~1.5 s a change. Fixed row heights halved it,
  but SwiftUI's own pass over the rows (`TableRowForEachState`) still took ~0.4 s. Now
  `RecordTable` (an `NSViewRepresentable` around an `NSTableView` with plain text cells)
  reloads when the browser's `generation` changes: ~30–50 ms a change, only the rows on
  screen. It keeps what the SwiftUI table did: header sort (`KeyPathComparator`s, so
  `FastSort` and the filter keys are unchanged), column widths, order and hidden columns
  saved (`autosaveName`), a header menu to hide columns, multi-selection bound to the
  browser, the row menu (on the clicked row, or the selection if it's in it), double-click,
  Return and Space to play, dragging rows as file URLs (Resolve), type-to-find on the name.
  A reload with a new filter (scope, search, sort) scrolls to the selection or the top;
  one from new data keeps the scroll. Folder Categories still uses SwiftUI tables (small).
- **Clicks and keys with both sections built** (owner, 2026-10-26: "↑↓ and Space don't
  work"). SwiftUI's opacity doesn't stop AppKit sending the hidden section's views clicks,
  scrolling and keys, and SwiftUI hit-tests its views in the order they were made (the music
  ones last, so on top), whatever their order in AppKit or `zIndex`. So the hidden section's
  views are hidden in AppKit: the lists by `RecordTable` (`shown`), the sidebar and the BPM
  fields by `SectionViews`. Never hide a view that has the keyboard during SwiftUI's update:
  AppKit then looks for the next key view, and SwiftUI, asked from inside its update, never
  answered (the app hung at 100% CPU). Views are shown at once and hidden just after the
  update, once the keyboard has moved. The shown list takes the keyboard at launch and after
  a switch unless the search field or the sidebar has it; a key that reaches the old list
  first is passed on. The detail panes' own AppKit views (waveform, file drag) let clicks
  through while their section is hidden (`sectionShown`); SwiftUI controls at opacity 0
  don't take clicks. Each section's bars fade whole, bar material included
  (`edgeBar(_:shown:)`). Checked with real clicks and keys in both sections: rows, ↑↓,
  Space, Return, double-click, switching then keys at once, sidebar rows, BPM fields,
  scrolling, sorting, search and clearing it, the row and header menus, Find Similar Sounds
  (Match column), the detail pane's play and waveform. The owner checked dragging rows into
  Resolve: works.
- **Smoothness: the main thread was always busy while something played** (owner,
  2026-10-26: animations "in a slow frame rate", "the program is lagging"). Three causes,
  all measured with `sample`: (1) SwiftUI works out a window's (and each split view
  column's) minimum size by measuring all of its content after any change, and the detail
  pane's grid made that 10–20 ms, 40 times a second while the playhead moved: the window
  content and the detail column now use `fixedMinimumSize`, a layout that reports a fixed
  minimum without asking its content (it must also answer alignment queries itself, or a
  parent stack makes it lay the content out anyway). (2) The waveform redrew all its bars
  for each playhead move: the playhead is now its own layer. (3) Passing the playhead into
  `WaveformView` as a value rebuilt and re-laid out the whole detail pane on each tick (a
  representable's update is re-measured): the waveform now follows the player itself with a
  display link while playing, and the time labels are their own views over a fixed-width
  stand-in (`TickingText`). Playing went from ~100% to ~25% of the main thread.
- **Preview loudness** (owner: some sounds at −44 LUFS were barely audible). Preferences
  (⌘,, `Preferences.swift`): "Play sound effects at the same loudness", on by default, at
  −14 LUFS (streaming), −16 or −23 (EBU R128). `AppModel.previewGain` brings a sound to that
  level from its measured loudness (`SoundFacts`), keeping peaks below −1 dBFS; songs and
  unmeasured sounds play as they are. Only playback: files aren't changed and Resolve gets
  the original. `AudioPlayer` is now AVAudioEngine (player node → two EQ units as gain
  stages, each −96…+24 dB): AVAudioPlayer can't play above a file's own level. Ranges and
  seeks are scheduled segments; a segment's end, matched by `generation`, stops playback;
  an output device change restarts the engine where it was. Preferences also has auto-play
  and "While you use the Mac" (moved out of the Analysis menu).
- **Appearance** (owner, 2026-10-27). Preferences' first row: System, Light or Dark
  (`Appearance` in `Preferences.swift`, saved as `appearance`). It sets `NSApp.appearance`
  (nil for System), so every window and the sound map's AppKit canvas follow; the saved
  choice is applied in `applicationWillFinishLaunching`, before any window shows. Handy for
  testing too: no need to change the Mac's own setting to see the other look.
- **What's playing** (owner, 2026-10-26: after selecting another row, the playing one was
  lost; the owner chose the design). The playing row's name has a speaker before it, blue
  while playing, grey while paused, white on the selection (`RecordTable` `playing`,
  `RecordColumn.marksPlaying`; only the rows that change are redrawn). While the detail
  pane shows something else, `NowPlayingBar` sits at its top: name, time, play/pause, stop
  and Show, which selects it and scrolls to it (`reveal`), clearing the search, sidebar
  choice and music filters if they hide it. The playing item is found by its path
  (`AppModel.playingSound/playingSong`); the time is its own small view, as it changes 40
  times a second. Switching section still stops playback. The strip slides down from the
  top and the details slide with it (`DetailColumn`, 0.3 s; owner asked; smooth once the
  playback work above was gone). The details are
  usually new views (another row selected), so neither layout animation nor an insertion
  transition moves them (a `.transition` on the detail view didn't run at all): they're
  offset by the strip's height and animated back to 0 instead.
- **Keyboard shortcuts** (owner, 2026-10-26; `Shortcuts.swift`, each defined once and used by
  both the menus and Help ▸ Keyboard Shortcuts). In the list (bare keys, like Space, handled by
  `KeyTableView` so typing in the search field is untouched): ← / → move what's playing or paused
  5 s in a song, 1 s in a sound effect; ⇧← / ⇧→ 15 s / 5 s (`AudioPlayer.skip(by:)` stops past
  the end); with nothing playing the key goes to the table. Menus: Playback (Stop ⌘., Show Now
  Playing ⌘L, Auto-play On or Off ⇧⌘A for the section on screen), Song (Double/Halve Tempo
  ⌥⌘↑/⌥⌘↓, Use Relative Key ⌥⌘K, Revert; through the main window's undo manager, so Edit ▸ Undo
  takes them back), File ▸ Show in Finder ⌘R (⇧⌘R is Rescan All Folders), Edit ▸ Copy Path ⌥⌘C,
  Search ⌘F (`NSSearchToolbarItem.beginSearchInteraction`), Find Similar Sounds / Find Songs That
  Mix With This ⇧⌘F (the title follows the section). Help ▸ Keyboard Shortcuts is a window sized
  to its content (system font: monospaced drew ⌥⇧⌘ badly). Checked in the app: the arrow keys
  (0:00.1 → 0:06.1 on a sound, paused), Show Now Playing, Auto-play (restored), Search focus,
  Find Similar, Double Tempo then Undo (database checked), the help window. Not run: Copy Path
  (the test tool refuses clipboard menu items) and Show in Finder (would bring Finder forward);
  both reuse the row menu's code.
- **Auto-play button**: in the toolbar it sat halfway between the section switch and the
  search field, as SwiftUI puts flexible spaces on both sides of a toolbar item there
  (`ToolbarSpacer`, `.primaryAction` and moving it to the inspector's toolbar changed
  nothing). The owner chose to attach it to the switch: `AutoPlayToggle`, in the principal
  item with `SectionSwitch`, drawn like it (light glass, the blue pill while on).
- **Fixed: "Application performed a reentrant operation in its NSTableView delegate"**,
  logged once a few seconds after launch. Found with lldb (break on `NSLog`; the message
  comes from `-[NSTableRowHeightData _cacheRowSpansInRange:heightProvider:]`): SwiftUI's own
  sidebar list (`OutlineListCoordinator.diffRows` → `endUpdates`) inserting the sound
  sidebar's ~60 category rows into the list on screen when the library loaded (7 → 67 rows);
  AppKit's automatic row heights re-entered their cache while keeping the top row in place.
  No Earmark code on the stack. Now both sidebars are built only once the library has been
  read (`AppModel.hasLoaded`), so their rows arrive with the list, and `SectionViews` hides
  the other section's sidebar again once they exist. Checked: no warning in a minute after
  launch, nor when the Similar row is added and cleared. Finding which list: a breakpoint on
  `-[NSTableView endUpdates]` printing `numberOfRows` (after `expr -l objc -- @import AppKit`).
- **Sidebar rows added or removed while selected** (owner, 2026-10-26: "Similar to…" text
  doubled, its ✕ needed two clicks). Adding the Similar row and selecting it in the same
  update left a copy of the row drawn over it: the text twice, in the selected (bold) and
  plain styles, and the copy took the first click. Removing it while selected did the same
  (a stale highlighted row). So `SoundBrowser.showSimilar` selects the row on the next turn
  of the run loop, and `clearSimilar` deselects first and removes it on the next turn. This
  replaces rebuilding the whole sidebar with `.id` on clear, which also collapsed the
  categories you had opened.
- **Sorting** was ~3.4 s on the main thread for 28k sounds (`displayName` built a URL per
  comparison; localized compare). `FastSort` (`Display.swift`) builds the sort keys once,
  and `SoundBrowser.refresh` filters and sorts off the main thread.
- When measuring with `sample`, clicks made through the accessibility tools cost the app a
  lot themselves (AX queries, and layout they trigger): measure with the app acting on its own
  (a temporary launch argument that switches sections on a timer worked well). On the second
  monitor ("LU28R55 (1)") the computer-use tool's clicks landed ~180 px (screenshot pixels)
  above where it aimed; run Earmark's binary directly to read `NSLog` output.

- See `CLAUDE.md` "Gotchas" for Phase 0 (S-KEY writes `prediction/` folders if called on a
  directory; PE-AV text embeds bug; CLAP 10 s windowing; Beat This! checkpoint fallback;
  GitHub macOS runners fail any MPS allocation).
- SwiftPM's `Bundle.module` looks at the top of the .app, which breaks code signing; that's
  handled in `UCSCatalog.bundledResource`.
- The GRDB `sound.path` column is UNIQUE, so folders of the same kind can't overlap; the app
  refuses or offers to replace them.
- Phase 0 music confidence flags are miscalibrated; don't present them as errors.
- Views inside `Table` cells (and context menus) must not read `@Environment(AppModel.self)`:
  after rows are removed, the table can update a removed row's cell outside the window and
  SwiftUI traps ("no Observable object"). Pass the model in (`FolderMapView.swift`).
- The status bar used to be a `safeAreaInset` over the split view; the sidebar list ignores
  that inset (and `contentMargins`), so its last rows were hidden. Each list now has its own
  bar (`edgeBar`), so the sidebar runs the window's height.
- Testing SwiftUI menus: the computer-use background tools refuse menu buttons, and real
  clicks failed on the 3-display setup on 2026-10-25 (they landed on the desktop). UI
  scripting works: `osascript` → System Events → `click menu button …`, then
  `click menu item "…" of menu 1 of it`; table rows via `set selected of row N to true`.
  But System Events' `entire contents` timed out (2 min) with the song list in the window:
  find controls with a small Swift AX tool that skips `AXTable`/`AXOutline` (and never
  searches the menu bar). Only the table offers AXShowMenu, and it didn't open the row menu;
  on 2026-10-26 computer-use clicks on "LU28R55 (2)" didn't land at all, but CGEvent clicks
  posted from a Swift tool at global coordinates (points, that monitor at 0,0, ×1.758 from the
  screenshot frame) did. SwiftUI alerts are sheets that window screenshots don't show; reach
  them with `sheet 1 of window "Earmark"`.
- `SongRecord`'s bpm/key/beats fields hold the user's corrections in the app's memory
  (`analysed`/`correction` aren't stored, by `CodingKeys`). Never write a record from
  `AppModel.songs` back to the database: fetch it fresh, as `saveSongAnalysis` does, or the
  corrections would overwrite what was analysed.
