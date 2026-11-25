# Earmark for Windows and Linux, drawn

The Windows and Linux app as a drawn window (egui on wgpu and winit), no web view: the owner's
rule for every app is native Swift on the Mac and Rust with a drawn interface elsewhere. Same
features as the earlier Tauri window, on the same Rust engine (`../../engine`).

- `src/backend.rs`: what the window shows and does (libraries, list, details, Find Similar, map,
  scanning and analysing in the background, timeline files, DaVinci Resolve), through the same
  tools as the MCP server.
- `src/analysis.rs`: loudness, the two models' vectors (ONNX Runtime) and the groups.
- `src/ui.rs`: the window. `src/look.rs`: Earmark's own pieces (segments, keys of a set width).
- `src/theme.rs` and `src/frame.rs`: the family's design system and the dark window frame
  (`#131314` through DWM on Windows, never the system accent), **shared as they are with
  Aspect**. Change them there first and copy them over, so the apps keep one look. `theme.rs`
  leaves out Aspect's `advice`, the one piece tied to that app.
- `src/player.rs`: playing a sound (rodio).

Run it: `cargo run --release`. On a copy of a database: `EARMARK_DATABASE=/path/copy.sqlite`.
For checking without driving the window: `--check` (the calls, printed), `--analyse`, and
`--shot file.png [--select] [--music] [--map] [--size 1400x900]` (opens the window, saves what it
draws, quits).
