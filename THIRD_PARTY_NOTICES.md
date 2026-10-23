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
| `CLAPAudio.mlpackage` (Core ML) | LAION CLAP `laion/larger_clap_general`, audio tower and projection, converted unchanged except that its bicubic time resize is written as the equivalent matrix multiply | Apache-2.0, as the original. Converted with coremltools (BSD-3-Clause), which isn't distributed. |

## Python libraries (installed by `setup.sh`, not distributed here)

Mostly permissive (BSD, MIT, Apache-2.0, ISC): PyTorch, transformers,
NumPy, SciPy, scikit-learn, umap-learn, librosa, nnAudio, beat-this,
openpyxl, tqdm. Notable exceptions:
- `mutagen` (tag reading) is GPL-2.0-or-later.
- `soundfile`/libsndfile and `soxr`/libsoxr are LGPL.

Anyone redistributing a bundled build should check these licenses.
