# The Rust engine: plan

Approved by the owner on 2026-10-29: "start porting it to Rust so we can have a new Mac
version and the Windows version". This is option B in ROADMAP.md: the engine moves to
Rust; the Mac keeps its SwiftUI interface; Windows gets its own interface on the same
engine.

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
5. Analysis files and timeline files.
6. The Resolve bridge and the MCP server.
7. Audio decoding (Symphonia) and the models (ONNX), with the same parity checks as the
   Core ML conversion. Only Windows uses these at first.
8. **The Mac app switches to the engine**, piece by piece, behind the same Swift types.
   It ships as an alpha, so Mac users test the new engine before Windows exists.
9. The Windows app (Tauri), as ROADMAP.md describes.

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
