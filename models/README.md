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
cd ../app
swift run -c release earmark-parity clap ../models/build/CLAPAudio.mlpackage ../models/build/clap_reference.json 300
swift run -c release earmark-parity peav ../models/build/PEAV ../models/build/peav_reference.json 300
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
