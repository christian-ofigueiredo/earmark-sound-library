# Earmark for Windows and Linux

The same library as the Mac app, as a drawn window (egui on wgpu and winit) — no web view. The
owner's rule for every app: native Swift on the Mac, Rust with a drawn interface on Windows and
Linux, and a window frame in the app's dark grey (`#131314`), never the system's accent colour.
(Until 2026-11-25 this was a Tauri web window; it's in the git history.)

Reading the libraries, the database, searching, categories, groups, Find Similar, the sound map,
timeline files and DaVinci Resolve all come from the Rust engine in `../engine`. Searching, a
sound's details, Find Similar, timeline files and Resolve go through the same tools as the MCP
server (`earmark_mcp`), so they answer as there.

## The files

- `src/backend.rs`: what the window shows and does, scanning and analysing in the background.
- `src/analysis.rs`: loudness, both models' vectors (ONNX Runtime), the similarity groups.
- `src/ui.rs`: the window.
- `src/theme.rs`: the family's common design system, **shared as it is by the four apps**
  (Aspect, Earmark, Graticule, Offload). Offload keeps the original
  (`~/Documents/Offload/desktop/src/theme.rs`): change it there and copy it over unchanged, so
  the apps keep one look. Earmark uses its default measures (`Style::EARMARK`).
- `src/frame.rs`: the window frame in the theme's ground (on Windows the caption, border and caption text are set
  through DWM), the same file as Aspect's.
- `src/player.rs`: playing a sound (rodio).
- `installer/earmark.iss`: the Windows installer (Inno Setup).
- `assets/fonts`: Tessel and Brakwell, the variable fonts; the theme picks each weight.

## What it does

- Sound Effects and Music, each with its libraries (Add Library…; right-click one to read it
  again or remove it); All Sounds, Duplicates and the UCS categories and subcategories, with
  counts.
- The list (search as you type), the details pane (about, sound, file), play with the round
  key, Space or a double-click, Up and Down to move.
- Find Similar, Save as Timeline File (into Videos\Earmark or ~/Videos/Earmark, shown in the file
  manager), Add to DaVinci Resolve (Studio), Show in Folder.
- The sound map (List | Map), for everything or a category; hover names a sound, a click selects
  it.
- **Analyse**: loudness for every sound, then, when the models are in the data folder's `Models`
  (`CLAPAudio.onnx` and the `PEAV` folder that `models/convert_onnx.py` makes, about 4.5 GB; on
  Windows `%APPDATA%\Earmark\Models`), both models' vectors, then the similarity groups with
  their names. The key stops it.
- **Light and dark**, as on the Mac: the settings key next to the search field (or Ctrl+,) picks
  System, Light or Dark. System follows Windows' or the desktop's setting. The window frame takes
  the app's own ground (dark grey or Seashell), never the system's accent colour.
- Rescan All Folders, and **Import Analysis…**: an analysis file exported by the Mac app (File ▸
  Export Analysis…) brings its loudness, sound vectors, categories and song analysis.

| Mac | Windows and Linux |
|---|---|
| Analyses the sounds itself (Core ML), models downloaded with the app | Same models through ONNX Runtime, once their files are put in the data folder by hand; or import an analysis file from the Mac. Earmark's category guesses aren't made here yet |
| MP3 and AAC lengths from macOS | From the engine's decoder (Symphonia) |
| Song titles, artists and albums from the tags | The file's name; length from the audio. Tags aren't read yet |
| Data in `~/Library/Application Support/Earmark` | `%APPDATA%\Earmark` on Windows, `~/.local/share/Earmark` on Linux, the same database |

## Checking without driving the window

On a copy of a database (`EARMARK_DATABASE=/path/copy.sqlite`):

- `earmark-desktop --check`: the window's calls, printed.
- `earmark-desktop --analyse`: the analysis without the window.
- `earmark-desktop --shot file.png [--select] [--music] [--map] [--light|--dark] [--settings]
  [--size 1400x900]`: opens the
  window, saves what it draws and quits.

## What has and has not been checked

- On a Mac, against a copy of the owner's database: `--check` gives the same counts as the Tauri
  window did (28,827 sounds, 814 songs, 958 in duplicates, 59 categories, DOORS' map 291 points);
  screenshots of the list with a sound's details, the Music section and the whole map (28,827
  points, about 25 s to make).
- The Windows frame code type-checks for Windows.
- **Not yet:** running it on Windows or Linux (the dark frame on his PC, playing, dialogs,
  Resolve), and clicking through the window anywhere.

## Downloads

The `Desktop` workflow builds them on every change to `desktop/` or `engine/`, under the run's
**Artifacts** (Actions → Desktop → the latest run):

- **Earmark-Windows-Installer** (`Earmark-Setup-<version>.exe`): installs for your user only, no
  administrator rights needed, into `%LOCALAPPDATA%\Programs\Earmark`, with a Start menu entry and
  an uninstaller (Settings ▸ Apps). Uninstalling leaves the library's data in `%APPDATA%\Earmark`.
  Made with Inno Setup (`installer/earmark.iss`), which GitHub's Windows runners already have.
- **Earmark-Windows** (`Earmark.exe`): the same program on its own, runs as is.
- **Earmark-Linux** (`earmark`): built on Ubuntu 24.04, needs a 2024 distribution or later.

**Not signed yet.** There is no code-signing certificate, so Windows SmartScreen warns the first
time the installer or the program is opened ("Windows protected your PC" → More info → Run
anyway).

## Building

```bash
cd desktop
cargo run --release
```

Linux needs `libasound2-dev` and `pkg-config`.
