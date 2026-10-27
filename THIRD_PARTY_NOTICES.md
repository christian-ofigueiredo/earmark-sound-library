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

## Python libraries (installed by `setup.sh`, not distributed here)

Mostly permissive (BSD, MIT, Apache-2.0, ISC): PyTorch, transformers,
NumPy, SciPy, scikit-learn, umap-learn, librosa, nnAudio, beat-this,
openpyxl, tqdm. Notable exceptions:
- `mutagen` (tag reading) is GPL-2.0-or-later.
- `soundfile`/libsndfile and `soxr`/libsoxr are LGPL.

Anyone redistributing a bundled build should check these licenses.
