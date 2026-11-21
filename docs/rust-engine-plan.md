# The Rust engine: plan

Approved by the owner on 2026-10-29: "start porting it to Rust so we can have a new Mac
version and the Windows version". This is option B in ROADMAP.md: the engine moves to
Rust; the Mac keeps its SwiftUI interface; Windows and Linux share their own interface
(Tauri) on the same engine. Linux was added on 2026-11-20, marked untested.

## Where it lives

`engine/`, a Cargo workspace beside `app/`:

| Crate | What | Swift today |
|---|---|---|
| `earmark-core` | No I/O beyond reading files: UCS, metadata readers and normalising, scanning and fingerprints, music keys, loudness, CLAP features, similarity, HDBSCAN, groups, the sound map, duplicates, analysis files, timeline files, the analysis governor | `EarmarkCore` (most of it) |
| `earmark-db` | The library database (rusqlite), with the same schema and migrations, so it opens the database the Mac app already has | `LibraryDatabase`, `SoundGroupStore`… |
| `earmark-models` | Runs the models through ONNX Runtime (DirectML on Windows). The Mac keeps Core ML. | `EarmarkML` |
| `earmark-resolve` | The Resolve bridge (the same Python script, with Windows paths) | `ResolveBridge` |
| `earmark-mcp` | The MCP server (the official Rust SDK, `rmcp`) | `EarmarkMCP` |
| `earmark-ffi` | Swift bindings (UniFFI), built into an XCFramework the Swift package uses | none |

All dependencies must have licences that allow redistribution (MIT, Apache-2.0, BSD,
MPL-2.0). They go into `THIRD_PARTY_NOTICES.md` when the app first ships with them.

## The rule for every piece: the same results as Swift

Each piece is ported with its Swift tests, and it must match Swift:

- **Fixtures** both sides read: the existing ones in `app/Tests/EarmarkCoreTests/Fixtures`
  (CLAP features, HDBSCAN, Ward, music analysis, PE-AV padding), and new ones made by
  the Swift code (`earmark-parity dump …`) for things that have none yet, such as
  metadata.
- **Real files, read-only:** `earmark-parity` gets a mode that writes what Swift reads
  from a folder as JSON. A Rust tool does the same, and the two are compared. Run on the
  owner's SoundFX library, every difference is a bug in one of them.
- Floating-point results (loudness, features, embeddings) compare within the tolerance
  the Swift tests already use.

## Order

Each step ends with tests passing on macOS, Windows and Linux (GitHub Actions).

1. **Foundations:** the workspace, CI, UCS catalogue and CSV, read-only file access,
   XML flattening, the WAV/RF64/BW64/AIFF metadata reader, metadata normalising.
   **Done 2026-10-29:** the same results as Swift on all 29,166 files of the owner's
   SoundFX library (`engine/parity/compare.py`: every chunk, field, source and
   category, and the BWF time reference).
2. Scanning: listing audio files, fingerprints, format twins; music keys; Phase 0
   import. **Done 2026-10-29**, the same results as Swift (`engine/parity/compare.py`):
   - scanning the SoundFX library (29,177 files) and the music folder (1,688 songs):
     the list and its order, sizes, dates, fingerprints, technical facts, metadata;
   - format twins of the library's 29,177 sounds (350 hidden copies);
   - 3,276 key spellings (every note, accidental and mode, Camelot, Open Key, nonsense,
     and Phase 0's second opinions), with names, Camelot codes and neighbours;
   - both of the owner's Phase 0 music_analysis.json files (1,688 and 6 songs).
   MP3/AAC lengths still come from AVFoundation in the app; in Rust they arrive with
   audio decoding (step 7).
3. The database: the same schema (migrations v1–v10, recorded in GRDB's
   `grdb_migrations` table, so both can open the same file), replacing sounds on
   rescan with ids kept. **Done 2026-10-29** (`engine/crates/earmark-db`, rusqlite):
   libraries, sounds, songs, loudness facts, embeddings, Phase 0 and Earmark's song
   analysis. `compare.py db` runs the same operations in Swift and Rust on two copies of
   the owner's database: 297 moved files, 543 removed and restored, a copy, the library
   removed and added again, a song rescan with accented names in both Unicode forms, the
   Phase 0 import and saved analysis. The results are identical (16 tables, 148,247
   rows), new databases have the same schema, and each opens the other's. What it took
   to match Swift exactly:
   - **Names as Foundation spells them.** `URL.lastPathComponent` and folders come out
     decomposed as the Mac file system writes them (HFS+: "é" as "e" + accent, except
     U+2000–U+2FFF, U+F900–U+FAFF, U+2F800–U+2FAFF), while the path stays as given
     (`earmark_core::paths`).
   - **Text compared as Swift compares it**, by canonical equivalence (paths when
     matching, file names in the Phase 0 import).
   - **Dates rounded as Foundation rounds them**: to the nearest millisecond, halves up,
     after going through seconds since 2001 (checked on 40,000 times).
   Where Swift's result depends on its dictionaries' order (several moved files with
   the same content), Rust goes by path, so it's the same every time.
   The tables for groups, categories, folder rules, corrections and duplicates are
   created here; the code that fills them comes with step 4.
4. Analysis maths: loudness (EBU Tech 3341 cases), CLAP features, similarity, HDBSCAN,
   Ward, groups and their names, the sound map, duplicates, categories and folder rules.
   - **4a, done 2026-10-29:** loudness, Phase 0's audio preparation, CLAP's features,
     PE-AV's padding, similarity, duplicates. On 200 of the owner's files decoded by
     Swift: CLAP features identical to the bit, loudness identical to the stored values;
     2,000 sounds' neighbours and the duplicate sets identical.
   - **4b, done 2026-10-29:** the sound map (UMAP), HDBSCAN, Ward, groups, their names,
     when to regroup, and the group tables. Identical to the bit on the owner's library:
     the whole map (28,827 sounds) and every subcategory's groups and names (238
     subcategories, 605 groups). What it took:
     - **Accelerate on the Mac.** Swift's products go through vDSP, which adds in its
       own order, and UMAP's 200–500 rounds magnify the last bit. Rust calls the same
       vDSP functions on macOS (`analysis::linalg`); elsewhere plain loops, as Swift's
       code without Accelerate.
     - **Where matrices sit.** vDSP's sums depend on the matrix's place in memory
       (moving it by one float changed 167 of 206 products). The map and groups get
       page-aligned buffers as the app's `PageBuffer`; the similarity index sits where a
       Swift array's storage does (`linalg::Floats`). `earmark-parity map` now uses a
       `PageBuffer` as the app does.
     - **Swift's `Float.pi`** is π rounded toward zero (3.1415925), not to the nearest
       float, so the map's random normals use it.
     Where Swift's Ward picks between equally small groups in its dictionary's order, Rust
     takes the lowest point (no case on the owner's library).
   - **4d, done 2026-10-29:** folder rules and Earmark's folder suggestions, category
     votes and per-sound guesses, song corrections, and the music maths around the models
     (Beat This!'s input and chunks, the half-rate filter, beat tracking, S-KEY's labels),
     with their tables. On the owner's library, identical to Swift (`compare.py
     categories`): all 29,177 sounds' categories, the suggestions for all 214 open folders,
     the 755 per-sound guesses and 508 near-duplicate pairs from the vote. Song corrections
     and the music maths pass the Swift tests and Python's fixtures. On 30 of the owner's
     songs with Swift's Core ML outputs (`compare.py music`; `MusicAnalyzer.logits` and
     `keyProbabilities` are public for it): the half-rate audio and spectrograms identical
     to the bit (the filter's multiply-adds are fused, as Swift's SIMD `addProduct`), and
     the beats, tempo, bars and key identical. Text is split into characters as Swift's
     `Character` does (grapheme clusters, `unicode-segmentation`), so decomposed accents
     and Hangul make the same words. The record types moved into earmark-core
     (`records`, `dates`), as the analysis works on them.
5. Analysis files and timeline files. **Done 2026-10-30**
   (`earmark_core::analysis_file`, `earmark_core::timeline_file`,
   `earmark_db::analysis_files`), with the Swift tests. On the owner's library:
   - `compare.py anafiles`: both languages' exports are identical once parsed (28,827
     sounds, 1,688 songs). Each language imported each's files into a copy with no
     analysis, and all four results are identical (16 tables, 147,858 rows, the 57,654
     embeddings bit-exact). The owner has no folder rules, per-sound choices or corrections
     yet, so the check adds some to its copy first. Files aren't byte-identical: Swift
     writes "/" as "\\/" and orders keys its own way; both read both.
   - `compare.py timeline`: 600 cases over all 10 frame rates, including odd names and
     failures: the file's text identical to the byte. Rust also writes Windows paths as
     file URLs (`file:///C:/…`), which only unit tests cover so far.
6. The Resolve bridge and the MCP server. **Done 2026-10-30** (`earmark-resolve`,
   `earmark-mcp` with `rmcp` 3.8, and the catalog in `earmark_db::catalog`), with the Swift
   tests, through the SDK's own client.
   - `compare.py mcp` starts the Swift and Rust servers on the owner's library, as a client
     does, and asks both the same things, read-only: all 9 tools' definitions, then 4,938
     calls (the whole list page by page, every category, subcategory and group, 3,000 sounds'
     details, 600 searches for similar sounds, wrong arguments, timeline files in a stand-in
     home folder). No differences; 4,928 answers are identical to the byte, and the ones seen
     differing only spell a tiny number differently (`e-06` and `e-6`). Saved timeline files
     are identical. All those calls took Swift 246 s and Rust 11.5 s, mostly in sorting.
   - **Names sort as Foundation sorts them** (`text::StandardKey`, for
     `localizedStandardCompare`): spaces, punctuation, symbols, digits, letters; numbers by
     value; accents and then case only between otherwise equal names. `compare.py names`: all
     54,356 of the library's names and 16,461 made-up ones in the same places, and the same
     capitals as `String.capitalized`. Letters outside the Latin alphabet follow Unicode's
     order, which may differ from Foundation's within a script; the owner's names don't show it.
   - **The bridge's script** is the Swift one (`bridge.py`; a test holds them together), so
     what Resolve Studio 21.1.2 was checked against still holds. `resolve_status` and
     `add_to_resolve` previews give the same answers from both servers in Resolve Studio
     (`compare.py mcp`, when Resolve is open). Placing for real, checked 2026-10-30 in the
     LABORATORY project at 30 fps, with the owner's OK: the same stereo and mono files through
     both servers, each on a new timeline (whole files, a part, by seconds and by timecode,
     new and free tracks, a busy track, a track that doesn't exist, a one-frame range). What
     Resolve then held was identical: tracks, kinds, every clip's place, in-point and file, no
     video, the playhead back where it was. The answers differed only in the test timelines'
     names. Not covered: paths with accents (none of the library's online sounds has one),
     files of more than two channels (none in the library), and other frame rates.
   - **Windows, not yet run:** `ResolvePython.exe` where Resolve's documentation says it is;
     no console window; the request read as UTF-8 (`PYTHONUTF8`), as Python would otherwise
     use the system's code page; `earmark://` opened with `rundll32`; the database in
     `%APPDATA%\Earmark`, timeline files in `Videos\Earmark`. CI builds and tests the code on
     Windows, but without Resolve there.
   - The server stays on protocol versions from 2024-11-05 to 2025-11-25 (what `rmcp` 3.8
     answers), each tried over stdio.
   - Licences: all the new dependencies are MIT, Apache-2.0, BSD or Zlib, or offer one of
     them. `unicode-normalization` and `unicode-ident` also carry Unicode-3.0, which allows
     redistribution though it isn't named in the list above.
7. **Done:** audio decoding (Symphonia) and the models (ONNX), with the same parity checks
   as the Core ML conversion. Only Windows and Linux use these; the Mac stays on Core Audio
   and Core ML.
   - `earmark-audio` reads sound files with Symphonia and changes their sample rate with
     its own resampler. `earmark-models` runs CLAP, PE-AV, Beat This! and S-KEY through
     ONNX Runtime (`ort`). The ONNX files are made by `models/convert_onnx.py` from the same
     weights as the Core ML ones, and aren't in the repository.
   - **Decoding, against Apple's decoder** (`compare.py decode`, on the owner's library):
     200 WAV files identical sample for sample. MP3 (48 sounds) and AAC (11) decode to the
     same sound within rounding (signal-to-noise 46 dB at worst, 70 dB median for MP3;
     61 dB at worst for AAC); one MP3 comes out 576 samples earlier and 1,105 frames
     longer, the encoder's padding, which Apple's decoder trims. 14 songs: 57 dB at worst.
     Symphonia also read two MP3 files that Apple's decoder couldn't.
   - **The resampler** is the weakest part: on files resampled to 48 kHz the median is
     70 dB, but the worst WAV is 23 dB and 14 of 189 differ by one frame in length.
   - **Sound vectors** (`compare.py embed`), against the vectors the Mac app stored:
     with the same audio samples, CLAP (198 sounds) and PE-AV (40 sounds) give cosine
     1.000000 on every sound. With Symphonia and the resampler, CLAP's worst is 0.9858
     (1st percentile 0.9937, median 1.000000) and 99.9% of each sound's five nearest
     neighbours stay the same; PE-AV's worst is 0.9998 on its 40 sounds. So what differs
     is the audio going in, not the models.
   - **Tempo and key** (`compare.py tempo`), 56 songs, 223 minutes: tempo within 2% on all
     56 (within 0.01 BPM on 52), the same key on all 56 (confidence differs by 0.0005 at
     most), the same steadiness on all 56. **Beats per bar differ on 6 of 56**, not looked
     into yet.
   - **ONNX Runtime picks a device by itself** unless told otherwise (Core ML on a Mac), so
     the engine now asks for the processor every time, except when the graphics card is
     chosen on Windows. The numbers above are on the processor, the path Windows and Linux
     use: the 223 minutes of music took 6 minutes (they had taken 4 h 45 min and 13 GB of
     memory through Core ML, on a busy Mac).
   - **Not run:** the real models on Windows or Linux (CI builds and tests there with
     tiny stand-in models, which exercise ONNX Runtime but not the models); DirectML (the graphics card on Windows); FLAC, Ogg and ALAC files, which
     the library sample didn't have; PE-AV on more than 40 sounds.
   - Licences: Symphonia is MPL-2.0 (used unchanged), `ort` MIT or Apache-2.0, ONNX Runtime
     MIT; see `THIRD_PARTY_NOTICES.md`.
8. **Done 2026-11-21: the Mac app runs on the engine**, piece by piece, behind the same Swift
   types. It ships as an alpha, so Mac users test the new engine before Windows exists. After
   the last piece, the owner's database rescanned through the engine (build 118) is identical,
   every row of every table, to a backup taken before the switch.
   - **How it's built:** `engine/crates/earmark-ffi` is the engine as the app calls it;
     UniFFI writes its Swift side. `scripts/build-engine.sh` builds it into
     `app/Engine/EarmarkFFI.xcframework` (a static library) and
     `app/Sources/EarmarkEngine/Generated/`, neither in the repository; `build-app.sh` and
     CI run it before `swift build`. The `EarmarkEngine` target turns the engine's answers
     into the app's own types. Records with many fields cross as JSON in the shape Swift's
     `Codable` types read (the shape the parity checks compare), so the app keeps its types.
   - **The way back:** `defaults write io.github.christian-ofigueiredo.Earmark swiftEngine
     -bool YES` makes the app use its Swift code again, until step 8 is finished.
   - **8a, scanning (2026-11-20):** reading a sound library's files goes through the engine,
     with the app's AVFoundation reader still giving MP3 and AAC lengths. On the owner's
     SoundFX library (29,177 files), `earmark-parity enginescan` finds Swift's and the
     engine's results identical, dates to the bit, in the same time (about 13 s each). What
     it took:
     - **Dates as Foundation makes them**, from the file system's seconds and nanoseconds,
       which the engine now passes alongside its date (2,841 files differed in the last bit
       before).
     - **The real path on the Mac.** Foundation's folder walk starts from the folder's real
       path: links in the folders above it resolved, names spelled as on disk ("soundfx" as
       "SoundFX", accents as the disk stores them), and nothing listed when the folder
       itself is a link. The engine now does the same on the Mac (`scan::walked_root`);
       elsewhere it keeps the path as given. The new Swift tests
       (`EarmarkEngineTests`) found this; the owner's library, on a plain path, couldn't.
   - **8b, music folders (2026-11-20):** the engine lists a music folder's songs with their size
     and date (`read_songs`), and the app's AVFoundation reader (`MusicFiles.songFile`, now in
     `EarmarkML`) gives title, artist, album and length, as for sound files' MP3 lengths. On
     the owner's music folder (814 songs) `earmark-parity enginemusic` finds the two readings
     identical. The engine has no tag reader of its own yet; Windows and Linux will need one
     (Symphonia reads ID3, MP4 and Vorbis tags) before step 9.
   - **8c, the MCP server (2026-11-20):** the app ships the engine's `earmark-mcp` (built by
     `scripts/build-engine.sh`) as `Contents/MacOS/earmark-mcp`, where agents already start it;
     the Swift server stays beside it as `earmark-mcp-swift`, for an agent pointed there if the
     Rust one misbehaves. `compare.py mcp` on the owner's library again, read-only: all 9
     tools and 4,941 calls with no differences (4,931 identical to the byte, the rest only
     spelling a tiny number `e-6` instead of `e-06`), the same 7 timeline files, and the Resolve
     previews; all calls took Swift 231 s and Rust 15 s. Neither server's code changed since
     step 6.
   - **8d, the sound map and similarity groups (2026-11-20):** `EngineAnalysis` gives
     `SoundMap.map`, `SoundGroups.cluster` and `SoundGroups.names` through the engine, and the
     map view and `GroupBuilder` use it. The engine reads the app's rows where they are (their
     address) instead of a copy: a library's map is 177 MB of floats, and vDSP's sums depend on
     where a matrix sits, so the app's own page-aligned buffer gives the same results to the
     bit. `earmark-parity engineanalysis` on the owner's library: the whole map identical
     (28,827 points, 65,064 links; Swift 12 s, engine 14 s), and all 238 subcategories' groups
     and names identical (33 s and 32 s). `EarmarkEngineTests` check small sets and cancelling.
   - **8e, Find Similar, the guesses' neighbours and duplicates (2026-11-21):**
     `EngineSimilarityIndex` (the engine's index behind a `SoundNeighbourIndex` protocol that
     Swift's `SimilarityIndex` also meets, so the folder suggestions take either) and
     `EngineDuplicates` (the neighbour search behind Earmark's guesses, read in place as in 8d;
     near and byte-identical pairs; the sets). `earmark-parity engineneighbours` on the owner's
     library: every sound's 100 nearest identical, scores to the bit (28,827 sounds; Swift 92 s,
     engine 74 s), the 60 nearest of every sound identical (4 s each), and the same 508 near
     pairs, 209 byte-identical pairs and 470 sets. Swift lists byte-identical pairs in its
     dictionary's order, which changes from run to run; the engine lists them in the order the
     fingerprints first appear, the same pairs.
   - **8f, Earmark's category guesses (2026-11-21):** `EngineCategories` gives the
     neighbours' votes, the per-sound guesses and every folder's suggestions (with the
     engine's Find Similar index), and `SoundGuesser`, `FolderGuesser` and the folder map use
     it. `earmark-parity enginecategories` on the owner's library: all 28,827 sounds' votes,
     the 755 guesses, the 4,948 labels and the 7 shared descriptions identical; the
     suggestions for all 291 folders the same categories, order, words and shares, with about
     10 differing only in a score's last digit. That last digit isn't the engine's: Swift adds
     a folder's scores in its dictionaries' order, which changes from run to run, and two Swift
     runs differ the same way on about 9 folders. The engine gives the same answer every time.
   - **8g, loudness (2026-11-21):** `EngineLoudnessMeter` measures the chunks the app decodes
     (AVFoundation stays the Mac's decoder), reading them in place: copied across the bridge,
     the engine's meter was three times slower than Swift's, in place it's as fast. On 1,000 of
     the owner's files, picked evenly, `earmark-parity engineloudness` finds every loudness and
     peak identical (the meters took Swift 4.2 s, engine 4.0 s).
   - **8h, timeline files (2026-11-21):** `EngineTimeline` writes File ▸ Save as Timeline File…
     through the engine (agents' `save_timeline_file` already did, since 8c). `earmark-parity
     enginetimeline`: 721 files from the owner's sounds, at all 10 frame rates and six start
     timecodes (one not a timecode), whole sounds and parts, placed at times, none, and a part
     shorter than a frame: all identical, text and placements, and the 171 failures with the
     same message.
   - **8i, the app's Resolve bridge (2026-11-21):** ⌘T (Add to DaVinci Resolve Timeline) goes
     through the engine's bridge (`EngineResolve`), the same script and answers as
     `ResolveBridge.add`, as agents' `add_to_resolve` already did since 8c. `earmark-parity
     engineresolve` asks both for 40 previews of the owner's sounds (tracks free, new, 1, 2 and
     99; at the playhead, seconds, timecodes and a bad one; whole sounds and parts). Resolve
     wasn't open when it ran, so what it showed is that both fail alike, with the same message;
     previews with Resolve open, and placing for real, aren't checked for this piece (the
     script and the engine's side were checked in Resolve Studio in step 6).
   - **8j, the database (2026-11-21):** the app opens its library database through the engine
     (`EngineLibraryDatabase`, over `earmark_db`) behind a `LibraryStore` protocol that Swift's
     `LibraryDatabase` also meets; analysis-file export and import come with it. Records cross as
     JSON in the engine's shape, dates converted with GRDB's own code so they're the same to the
     bit; vectors cross as bytes (a list of floats crossed one number at a time, 40 times
     slower). The app's engine uses the system's SQLite, the one GRDB uses (earmark-db's
     `bundled` feature is off for earmark-ffi, built on its own by `build-engine.sh`): two copies
     of SQLite in one process opening the same file can lose each other's locks. The MCP server,
     its own process, keeps SQLite built in.
     - `earmark-parity enginedbread`, on the owner's database opened read-only by both: every
       read the app makes identical (libraries, 29,177 sounds, facts, both models' statuses and
       vectors, each sound's vectors, near duplicates, 814 songs, corrections, choices, rules,
       guesses, 597 groups, and both libraries' analysis files with and without vectors, whose
       keys Swift writes in a changing order, so compared sorted).
     - `compare.py enginedb`, on two copies of it cleared of analysis: the same operations
       through each (an analysis file imported, rescans with moved, removed and copied files, the
       library removed and added, facts, embeddings, near duplicates, the owner's categories and
       Earmark's guesses, folder rules and guesses, groups made, changed, renamed, merged,
       dropped and regrouped, songs rescanned with accented names, Phase 0's analysis, Earmark's,
       and corrections): the same answers, and all 16 tables, 145,549 rows, identical except the
       times each side stamps itself (a library added, a choice made, a set grouped, an import).
     - **First real rescan, then a fix:** the database stayed intact, but 2,709 sounds' and 115
       songs' lengths (AVFoundation's, for MP3 and AAC) changed in their last bit:
       `serde_json` without its `float_roundtrip` feature can read a decimal number one unit
       off. The feature is on now (a test checks such numbers), the write comparison scans with
       AVFoundation's lengths as the app does, and a second rescan restores the exact values.
   - Still in Swift on the Mac: decoding (AVFoundation) and the models (Core ML), by design, and
     applying the owner's rules and choices to the sounds in memory (`FolderRules.apply`,
     `SoundCategories.apply`), which the engine has but the app doesn't call through it yet.
9. The Windows and Linux app (Tauri), as ROADMAP.md describes. The Linux package is
   marked untested: CI builds and tests it, but no one tries it on a Linux desktop.

Until step 8 the Mac app doesn't use Rust at all, so nothing changes for testers.
Features added to Swift meanwhile (such as timeline files) are ported in their step.

## What's decided, and why

- **UniFFI** for the Swift bindings: it generates the Swift side from the Rust types, so
  the two can't drift apart. It's Mozilla's, MPL-2.0.
- **rusqlite** with SQLite bundled, so Windows needs nothing installed.
- **ONNX Runtime** through the `ort` crate on Windows. The Mac stays on Core ML, which is
  tested and fast on Apple's GPU.
- **The database stays compatible:** after step 8, the Mac app keeps its existing library
  and analysis, with nothing to redo.
