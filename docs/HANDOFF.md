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
    Resolve (the file URL); Space, Return or double-click plays; auto-play toggle.
  - `RecordTable.swift`: the sound and song lists, an AppKit table (see Gotchas).
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
   - music tempo/key in-app (Beat This! + S-KEY);
   - learning from the owner's labelled files (kNN gave 62% exact in Phase 0; zero-shot
     only 13–16%).
5. Phase 4: Resolve Studio bridge for sending only a selected range. Use the scripting
   API: import the original into the media pool, then `MediaPool.AppendToTimeline` with
   `startFrame`/`endFrame`. External scripting must be set to Local in Resolve
   preferences.

## Gotchas learned

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
  search field and auto-play button are shared and follow the section, and
  `AppModel.show(_:)` changes section at once while `SectionSwitch` animates its pill on its
  own. A switch costs ~80–100 ms of main thread, mostly SwiftUI working out the window's
  minimum size (`NSHostingView.minSize`) and laying out after the state change.
  Don't hide a section with `.disabled`, `.allowsHitTesting`, `.accessibilityHidden` or
  `.focused`, and don't give `.searchable` a binding or prompt that changes with the section:
  with SwiftUI tables, each changed the environment of every cell (each its own
  `NSHostingView`) and the switch went back to ~0.5 s. The search binding is `AppModel.search` (stable), the prompt
  "Search". The switch is a custom Liquid Glass control (`SectionSwitch`:
  `GlassEffectContainer`, a blue tinted glass pill moved with `matchedGeometryEffect`, the
  toolbar's shared glass hidden with `sharedBackgroundVisibility(.hidden)`); before macOS 26,
  a segmented picker. Blue details: `.tint(.blue)` on both windows, the play button
  `.glassProminent`, the waveform in system blue (the playhead in the text colour).
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
- **What's playing** (owner, 2026-10-26: after selecting another row, the playing one was
  lost; the owner chose the design). The playing row's name has a speaker before it, blue
  while playing, grey while paused, white on the selection (`RecordTable` `playing`,
  `RecordColumn.marksPlaying`; only the rows that change are redrawn). While the detail
  pane shows something else, `NowPlayingBar` sits at its top: name, time, play/pause, stop
  and Show, which selects it and scrolls to it (`reveal`), clearing the search, sidebar
  choice and music filters if they hide it. The playing item is found by its path
  (`AppModel.playingSound/playingSong`); the time is its own small view, as it changes 40
  times a second. Switching section still stops playback. The strip slides down from the
  top and the details slide with it (`DetailColumn`, 0.3 s; owner asked). The details are
  usually new views (another row selected), so neither layout animation nor an insertion
  transition moves them (a `.transition` on the detail view didn't run at all): they're
  offset by the strip's height and animated back to 0 instead.
- **Auto-play button**: in the toolbar it sat halfway between the section switch and the
  search field, as SwiftUI puts flexible spaces on both sides of a toolbar item there
  (`ToolbarSpacer`, `.primaryAction` and moving it to the inspector's toolbar changed
  nothing). The owner chose to attach it to the switch: `AutoPlayToggle`, in the principal
  item with `SectionSwitch`, drawn like it (light glass, the blue pill while on).
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
