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
   SoundFX library (`engine/parity/compare_metadata.py`: every chunk, field, source and
   category, and the BWF time reference).
2. Scanning: listing audio files, fingerprints, format twins; music keys; Phase 0
   import.
3. The database: the same schema (migrations v1–v10, recorded in GRDB's
   `grdb_migrations` table, so both can open the same file), replacing sounds on
   rescan with ids kept.
4. Analysis maths: loudness (EBU Tech 3341 cases), CLAP features, similarity, HDBSCAN,
   Ward, groups and their names, the sound map, duplicates, categories and folder rules.
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
