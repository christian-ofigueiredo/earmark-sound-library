# Earmark for Windows and Linux

The same library as the Mac app, built with [Tauri](https://tauri.app): one window for both
systems, in the same design system (Brakwell and Tessel, dark). Reading the libraries, the
database, searching, categories, groups, Find Similar, the sound map, timeline files and DaVinci
Resolve all come from the Rust engine in `../engine`; `ui/` draws what `src-tauri/src/main.rs`
hands it. Searching, a sound's details, Find Similar, timeline files and Resolve go through the
same tools as the MCP server (`earmark_mcp`), so they answer as there.

## What it does now

- Sound Effects and Music, each with its libraries (Add Library…, right-click to remove one);
  All Sounds, Duplicates and the UCS categories and subcategories, with counts.
- The list (search as you type, a page at a time), the details pane (about, sound, file), play
  with ▶, Space or a double-click, Up and Down to move.
- Find Similar, Save as Timeline File (into Videos\Earmark or ~/Videos/Earmark, shown in the
  file manager), Add to DaVinci Resolve (Studio), Show in Folder.
- The sound map (List | Map), for everything or a category.
- Rescan All Folders, and **Import Analysis…**: an analysis file exported by the Mac app (File ▸
  Export Analysis…) brings its loudness, sound vectors, categories and song analysis, so Find
  Similar, the map, groups and duplicates work without analysing again.

| Mac | Windows and Linux |
|---|---|
| Analyses the sounds itself (Core ML) | Not yet: import an analysis file from the Mac. The engine runs the same models through ONNX (step 7), not yet wired into this app |
| MP3 and AAC lengths from macOS | From the engine's decoder (Symphonia) |
| Song titles, artists and albums from the tags | The file's name; length from the audio. Tags aren't read yet |
| Data in `~/Library/Application Support/Earmark` | `%APPDATA%\Earmark` on Windows, `~/.local/share/Earmark` on Linux, the same database |

## What has and has not been checked

- On a Mac (Tauri builds there too), against a copy of a real library's database (29,177 sounds,
  814 songs): the window draws the libraries, counts, categories and list, and
  `earmark-desktop --check` (the window's commands without the window, on the database
  `EARMARK_DATABASE` names) gives the same counts as the Mac app, searches, details, Find Similar
  and a category's map.
- GitHub builds the Windows installer and the Linux packages at every push.
- **Nobody has opened it on Windows or Linux yet**, and clicking through the window hasn't been
  automated: playing, the dialogs, scanning a library there, Resolve on Windows are untested.

## Downloads

The `Desktop` workflow builds them on every change to `desktop/` or `engine/`; they are under the
run's **Artifacts** on GitHub (Actions → Desktop → the latest run):

- **Earmark-Windows**: `Earmark_0.1.0_x64-setup.exe`, an installer for the current user (no admin).
- **Earmark-Linux**: `Earmark_0.1.0_amd64.AppImage` (runs as is) and `Earmark_0.1.0_amd64.deb`
  (Debian, Ubuntu). Not tested.

## Building

```bash
cd desktop
npm ci
npx tauri build            # or: npx tauri dev
```

Linux needs `libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev`.
