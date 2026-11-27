# Third-party models, data and libraries

This repository's own code is MIT-licensed (see `LICENSE`). It bundles only
one third-party item, the UCS category list. Everything else below is
downloaded by `setup.sh` or on first use, under its own license.

## Bundled

| Item | License | Notes |
|---|---|---|
| `phase0/data/ucs_v8.2.1.csv`, the Universal Category System v8.2.1 list | Public domain | Converted from the official UCS resources (universalcategorysystem.com). UCS was created by Tim Nielsen, Justin Drury, Kai Paquin and contributors. |

## AI models (downloaded on first use)

| Model | Used for | License |
|---|---|---|
| Meta PE-AV (`facebook/pe-av-large`, `-base`, `-small`) | Sound embeddings, zero-shot categories | Apache-2.0 |
| LAION CLAP (`laion/larger_clap_general`, `laion/clap-htsat-fused`) | Sound embeddings (alternative) | Apache-2.0 |
| Beat This! `final0`–`final2` (CPJKU), or the community copy `safe-models/beat-this-final0` if the official server is down | Tempo, beats, downbeats | MIT. Its authors note that some training audio is copyrighted or under restrictive Creative Commons terms, and that users should judge whether this matters for their use. |
| S-KEY (Deezer), installed from github.com/deezer/skey at a pinned commit | Musical key | MIT |

## Converted models (made by `models/`, not in the repository)

| File | From | License |
|---|---|---|
| `PEAV/PEAVEmbed…PEAVLayers3.mlpackage` (Core ML, 5 parts) | Meta PE-AV large `facebook/pe-av-large`, audio tower and audio head only, converted unchanged except that its rotary position embedding is written as the equivalent pairwise rotation | Apache-2.0, as the original |
| `CLAPAudio.mlpackage` (Core ML) | LAION CLAP `laion/larger_clap_general`, audio tower and projection, converted unchanged except that its bicubic time resize is written as the equivalent matrix multiply | Apache-2.0, as the original. Converted with coremltools (BSD-3-Clause), which isn't distributed. |
| `BeatThis.mlpackage` (Core ML) | Beat This! `final0` (CPJKU), the network only (the spectrogram and peak picking are in the app's code), converted unchanged except that its attention and rotary position embedding are written out as the equivalent plain operations | MIT, as the original, with the same note about its training audio |
| `SKey.mlpackage` (Core ML) | S-KEY (Deezer) at the pinned commit with its constant-Q front end (nnAudio), converted unchanged except that its layer norm and final pooling are written out as the equivalent plain operations | MIT, as the original (nnAudio: MIT) |
| `CLAPAudio.onnx`, `PEAV/*.onnx` (5 parts), `BeatThis.onnx`, `SKey.onnx` (ONNX, made by `models/convert_onnx.py`) | The same four models and the same parts of them as the Core ML files above, for the systems without Core ML | As each original: Apache-2.0 (PE-AV, CLAP), MIT (Beat This!, S-KEY) |

## Data made with these models (in the repository)

| File | From | License |
|---|---|---|
| `app/Sources/EarmarkCore/Resources/group_words.bin` | Text embeddings of 99 English words that name similarity groups ("airy", "metallic", …), made with the text towers of PE-AV large and LAION CLAP by Phase 0 (`models/export_groups.py`) | Apache-2.0, as the models |

Earmark's HDBSCAN and Ward clustering (`HDBSCAN.swift`, `SoundGroups.swift`) follow
scikit-learn's (BSD-3-Clause); no scikit-learn code is included.

## Swift packages (built into the app by SwiftPM)

| Package | Used for | License |
|---|---|---|
| GRDB.swift (Gwendal Roué) | Earmark's database | MIT |
| MCP Swift SDK (`modelcontextprotocol/swift-sdk`) | The `earmark-mcp` server | MIT, moving to Apache-2.0 (see its LICENSE) |
| swift-nio, swift-log, swift-system, swift-atomics, swift-collections (Apple) | Used by the MCP Swift SDK | Apache-2.0 |
| eventsource (Mattt) | Used by the MCP Swift SDK | MIT |

## Rust crates (the engine in `engine/`, in the Mac app since step 8; not yet in a release)

| Crate | Used for | License |
|---|---|---|
| Symphonia 0.6 and its format and codec crates (16 crates) | Reading sound files where there's no Core Audio | MPL-2.0. Used unchanged. A build that includes it must say so and point to its source, github.com/pdeljanov/Symphonia. |
| UniFFI 0.32 (Mozilla: `uniffi`, `uniffi_core` and the crates that write the bindings) | The Mac app calling the engine (`earmark-ffi`); `uniffi_core` is built into the app | MPL-2.0. Used unchanged; its source is github.com/mozilla/uniffi-rs. |
| `ort` 2.0.0-rc.15 (pyke) | Calls ONNX Runtime | MIT or Apache-2.0 |
| ONNX Runtime (Microsoft), the library `ort` downloads when the engine is built | Runs the models where there's no Core ML | MIT |
| `webpki-roots` | Certificates for that download, at build time only | CDLA-Permissive-2.0 |
| The other crates (`rusqlite` with SQLite, `rmcp`, `serde` and what they use) | Database, MCP server, data formats | MIT, Apache-2.0, BSD, ISC or Zlib, or a choice that includes one of them |

## The Windows and Linux app (`desktop/`)

A drawn window (egui on wgpu and winit) on the engine above.

| Item | Used for | License |
|---|---|---|
| egui and eframe (and `epaint`, `egui-wgpu`, `egui-winit`) | Drawing the window | MIT or Apache-2.0 |
| wgpu, winit | The GPU and the window | MIT or Apache-2.0 |
| rodio, cpal (and Symphonia, already above) | Playing sounds | MIT or Apache-2.0; Symphonia MPL-2.0 |
| rfd | Folder and file dialogs | MIT |
| opener | Show in Folder | MIT or Apache-2.0 |
| image | The window icon and checking screenshots | MIT or Apache-2.0 |
| windows-sys, winresource (Windows) | The dark window frame; the .exe's icon | MIT or Apache-2.0; MIT |
| Brakwell | Titles, big numbers and the wordmark, as in the Mac app | As the Mac app's (see above) |
| Inter 4.1 (`assets/fonts/Inter.ttf`, made from the release's InterVariable.ttf by `tools/make-inter.py`: weights 300–700 at optical size 14, tabular digits, unreachable glyphs and hinting removed; `Inter-NOTE.txt`) | The interface's text (the Mac app uses the system font instead) | SIL Open Font License 1.1, Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter); the release's `LICENSE.txt` travels with the font, unchanged, as `assets/fonts/OFL.txt` |
| Inno Setup 6 (build tool; its setup and uninstall code is inside the Windows installer) | The Windows installer | Inno Setup License (free, redistribution allowed with the copyright notice kept), jrsoftware.org |

## Python libraries (installed by `setup.sh`, not distributed here)

Mostly permissive (BSD, MIT, Apache-2.0, ISC): PyTorch, transformers,
NumPy, SciPy, scikit-learn, umap-learn, librosa, nnAudio, beat-this,
openpyxl, tqdm. Notable exceptions:
- `mutagen` (tag reading) is GPL-2.0-or-later.
- `soundfile`/libsndfile and `soxr`/libsoxr are LGPL.

Anyone redistributing a bundled build should check these licenses.
