# Core ML models

Converts the models Phase 0 used to Core ML for the app, and checks that they
give the same results as Phase 0 on real files. The converted models are large
(CLAP: 271 MB) and aren't committed; `build/` and `.venv/` are git-ignored.

```bash
cd models
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python -I convert_clap.py            # build/CLAPAudio.mlpackage (full precision)
.venv/bin/python -I convert_clap.py --fp16     # build/CLAPAudio-fp16.mlpackage (for comparison)
.venv/bin/python -I parity_clap.py --files 300 --reference
.venv/bin/python -I convert_peav.py            # build/PEAV/*.mlpackage (5 parts, 4.2 GB)
.venv/bin/python -I convert_peav.py --fp16     # build/PEAV-fp16/ (for comparison)
.venv/bin/python -I parity_peav.py --files 300 --reference
.venv/bin/python -I convert_music.py           # build/BeatThis.mlpackage, build/SKey.mlpackage
.venv/bin/python -I parity_music.py --songs 20 # PyTorch vs Core ML on Phase 0's audio path
cd ../app
swift run -c release earmark-parity clap ../models/build/CLAPAudio.mlpackage ../models/build/clap_reference.json 300
swift run -c release earmark-parity peav ../models/build/PEAV ../models/build/peav_reference.json 300
swift run -c release earmark-parity music ../models/build <copy of library.sqlite> 300 7 all
swift run -c release earmark-parity map <copy of library.sqlite> map.json [CATEGORY]
../phase0/.venv/bin/python -I ../models/parity_map.py <copy of library.sqlite> map.json
```

`parity_clap.py` needs Phase 0's CLAP cache (`~/SoundLab/cache/clap-general.pkl`).
It re-runs Phase 0's own audio path on a sample of those files and compares
PyTorch and both Core ML models with Phase 0's vectors. `--reference` writes
`build/clap_reference.json` (file paths and Phase 0 vectors: library data, so
not committed) for `earmark-parity`, which runs the app's Swift pipeline
(AVFoundation decode → Phase 0 prep → features → Core ML) on the same files.
`--fixture` regenerates the Swift unit-test fixture
(`app/Tests/EarmarkCoreTests/Fixtures/clap_features.json`).

## CLAP results (2026-10-23, 300 random files from the owner's library)

| | Cosine to Phase 0 (min / p1 / median) | Top-5 neighbours kept | Speed per 10 s window |
|---|---|---|---|
| PyTorch (CPU) | 1.00000 / 1.00000 / 1.000000 | 100% | |
| **Core ML, full precision** | 1.00000 / 1.00000 / 1.000000 | 100% | 39 ms (CPU) |
| Core ML, half precision | 0.99998 / 0.99998 / 0.999996 | 99.4% | 21 ms (CPU + Neural Engine) |
| **App pipeline in Swift** (full precision) | 0.98756 / 0.99907 / 1.000000 | 99.9% | 0.38 s per file incl. decoding |

The app uses full precision: half precision changed some nearest neighbours,
and the plan only allows it when there's no loss. The Swift pipeline's few
lower cosines are short 96 kHz sounds: Apple's resampler and soxr differ by
tiny amounts, which can move the -60 dB trim point by a 5 ms frame, and a short
sound is repeated to fill 10 s, so the shift repeats. The worst of 300
(a 1.8 s punch) still has cosine 0.988.

Conversion notes:
- coremltools 9.0 with torch 2.14.1 (untested combination, works). Its `int`/`bool`
  casts reject 1-element NumPy arrays under NumPy 2; `convert_clap.py` patches them.
- CLAP's bicubic resize of 1001 → 1024 time frames isn't convertible; it is a fixed
  linear map along time, baked in as a 1024×1001 matrix (exact in float64).

## PE-AV large results (2026-10-23, 300 random files, 647 windows)

| | Cosine to Phase 0 (min / p1 / median) | Top-5 neighbours kept | Model time per window |
|---|---|---|---|
| **Core ML, full precision** | 1.00000 / 1.00000 / 1.000000 | 100% | 1.39 s (CPU) |
| Core ML, half precision | 0.97546 / 0.98497 / 0.999584 | 94.6% | 0.75 s (CPU) |
| **Core ML, full precision on the GPU** (`--units CPU_AND_GPU`) | 1.00000 / 1.00000 / 1.000000 | 100% | 0.44 s |

The app uses full precision: half precision changes 5% of nearest neighbours.

How it's converted (`convert_peav.py`):
- Only the audio tower's weights are read (1.13 B parameters of the 8.9 GB checkpoint;
  no text or video tower).
- Split into five models (codec encoder + class token; 4 × 7 transformer layers, the
  last with the output head) so conversion fits in memory. The parts chained in PyTorch
  equal the original encoder exactly.
- Window lengths are flexible (1920–480000 samples, multiples of 1920), so short
  sounds are embedded at their own length as in Phase 0.
- RoPE is rewritten as a plain pairwise rotation: transformers' version builds 2×2
  matrices with `narrow`, which coremltools can't convert for a flexible length. Exact.

Running it: **one part at a time over a batch of windows** (`parity_peav.py`, and
`PeavEmbedder` in the app). With three or more float32 parts loaded at once, Core ML's
CPU path crashed (segmentation fault) while Resolve was open and swap was nearly full;
two parts or one at a time is fine. The app runs PE-AV on the GPU, only while the Mac
is idle: exact on the GPU too, and 3× faster than the CPU.

## Tempo and key results (2026-10-26)

`convert_music.py` makes `BeatThis.mlpackage` (Beat This! `final0`, the checkpoint Phase 0
ran; 78 MB) and `SKey.mlpackage` (S-KEY with its constant-Q front end; 0.3 MB). Both match
PyTorch: Beat This! within 0.00001 (logits), S-KEY 0.00000 (probabilities), and on 10 of the
owner's songs Phase 0's PyTorch path and the Core ML models give the stored BPM, beats per
bar and key exactly (`parity_music.py`).

The app's Swift pipeline (`EarmarkCore/MusicAnalysis.swift`, `EarmarkML/MusicAnalyzer.swift`),
300 random songs against the values Phase 0 stored (`earmark-parity music … 300 7 all`):

| | Result |
|---|---|
| BPM within 2% | **99.0%** (291/294); equal to 0.01: 93.9% |
| Key the same | **100%** (299/299); confidence |Δ| median 0.0003, max 0.012 |
| Steadiness / beats per bar the same | 100% / 100% |
| Speed (all compute units) | 0.6 s per minute of audio incl. decoding (CPU only: ~1 s) |

The three BPM differences are songs whose tempo varies (the median of the 8-beat tempos
moves with one beat more or less). One MP3 Apple's decoder can't read.

How it's converted and ported:
- Beat This!: its rotary embedding (an einsum) and attention (fused SDPA) are written out as
  the same plain operations, checked equal before converting. One fixed 1500-frame chunk:
  a flexible length converted but Core ML couldn't plan it. The spectrogram (torchaudio
  `MelSpectrogram`: `normalized="frame_length"` scales by 1/√1024, not the window's energy),
  chunking (`split_piece`, `keep_first`), peak picking (`Postprocessor(type="minimal")`) and
  Phase 0's `summarize_beats` are in Swift, tested against Python (`--fixture`).
- S-KEY: its layer norm over (C, H, W) and adaptive pooling to (12, 1) are written out
  (mean and variance over those axes; a mean over time), checked equal. Whole songs, flexible
  length (2 s–20 min).
- **The resampler mattered.** Apple's 44.1 → 22.05 kHz converter keeps 10.5–11 kHz ~12 dB
  louder than soxr "VHQ" (Phase 0), and Beat This!'s mel bands reach 11 kHz: with it, only 88%
  of songs were within 2% and 46% equal. The app decodes at 44.1 kHz (Apple's MP3 decoding
  matches libsndfile to −66 dB) and halves the rate with `HalfRate`, a 601-tap Kaiser
  low-pass fitted to soxr's response (0.01% RMS from soxr on music).
- `coremltools.convert` changes the PyTorch module's tensors in place: take reference
  outputs before converting (S-KEY's moved by 0.05 afterwards, the Core ML model didn't).

## Sound map results (2026-10-26)

The sound map (`EarmarkCore/SoundMap.swift`) is a Swift port of umap-learn 0.5 with Phase 0's
settings (cosine, 15 neighbours, min_dist 0.15) on PE-AV + CLAP combined as Phase 0 did. It
starts from PCA instead of umap-learn's spectral layout and has its own seeded random numbers,
so it gives the same map every time but not Python's. `earmark-parity map` writes the app's
map for a copy of the database (one UCS category, or everything); `parity_map.py` (Phase 0's
environment, which has umap-learn) runs umap-learn on the same vectors and scores both the
same way: the share of each sound's 15 nearest neighbours (cosine, in the embedding space)
that are among its 15 nearest on the map.

| Sounds | Swift | umap-learn |
|---|---|---|
| AMBIENCE, 537 | 0.559 (0.4 s) | 0.552 (5.5 s) |
| DESIGNED, 1,512 | 0.438 (1.0 s) | 0.439 (4.1 s) |
| All of SoundFX, 28,827 | 0.323 (11.5 s) | 0.326 (23.1 s) |
