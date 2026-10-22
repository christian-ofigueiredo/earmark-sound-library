# Earmark: project notes

Earmark is an open-source (MIT) Mac app to browse and categorize sound effects and music.
The plan is in `docs/PLAN.md`; Phase 0 tools are in `phase0/`.

## Project principles (keep these)
- **Ask the owner before changing anything** (code, docs, repository, settings). Propose first, act after approval. Analysis the owner asks for is fine. Work on branches; merge to `main` only when approved.
- **Quality over speed. Use the best models available.** Prefer accuracy, ensembles and verification over shortcuts.
- Open source and public. New models, data or bundled code must have licenses that allow redistribution; record them in `THIRD_PARTY_NOTICES.md`. Don't commit test audio that isn't freely licensed (ESC-50 is CC BY-NC, so never add it).
- **Never write to, rename or modify original sound/music files.** All state lives in the app's database or a separate sidecar file. Phase 0 scripts enforce this with `ensure_output_outside_inputs`.
- Sound effects: group similar sounds (e.g. whooshes) like Soundly, using vendor metadata (BOOM etc.) first.
- Music: a separate window/tab; batch tempo + key for a folder. Both windows are built together from Phase 1.
- Analysis runs mainly when the Mac is idle (overnight); the app must say so. The owner edits in DaVinci Resolve on a 16 GB M1 Pro, with libraries on an external SSD.
- Phase 0 code keeps its `soundlab` name and `~/SoundLab` output folder so the owner's saved analyses stay valid.

## Phase 0 layout
- `phase0/lab`: the user-facing command (`./lab metadata|compare|group|music|serve|selftest`). `setup.sh` builds `.venv` with uv (Python 3.12).
- `phase0/soundlab/`: shared code. `audio.py` (read-only decode, soundfile → ffmpeg → afconvert), `riff.py` (chunk parser), `metadata.py` (normalise fields + UCS + vendor sheets), `embeddings.py` (PE-AV/CLAP + cache), `analysis.py` (per-file pipeline, multi-model), `features.py` (shape features), `grouping.py` (UMAP/HDBSCAN/naming), `music.py` (Beat This!, S-KEY, key utils), `report.py` (HTML), `testdata.py` (synthetic library for selftest).
- `phase0/data/ucs_v8.2.1.csv`: the official UCS list (public domain), converted from the UCS resources zip.

## Gotchas found while building
- S-KEY: `setup.sh` installs it from github.com/deezer/skey at a pinned commit with `--no-deps` (it pins torch 2.7/numpy 2.2), with a git fallback when archive downloads are blocked. Never call `skey.detect_key()` on a directory: it writes `prediction/` into the audio folder. Use `load_model_components` and run the model directly (see `music.KeyEstimator`).
- transformers 5.20: `PeAudioModel.from_pretrained("facebook/pe-av-*")` loads the audio+text towers fine (481 unexpected video keys are expected). `get_text_audio_embeds` is broken (no hidden states); `Embedder.embed_text` calls the text model directly.
- CLAP feature extractor uses `rand_trunc` for clips over 10 s, so always window audio to ≤10 s first.
- Beat This! checkpoints come from cloud.cp.jku.at, which returned 503 during development. `music._load_beat_model` falls back to the community copy `safe-models/beat-this-final0` (safetensors, verified to match the architecture). Beats sit on a 50 fps grid: `refine_peaks` + `fit_period` are required for accurate BPM.
- Clustering: centre and scale the embedding block per set (`analysis.similarity_space`). Raw cosine on PE-AV embeddings clusters worse.
- UCS from filenames/folders: only exact-case or all-caps CatIDs count (otherwise "rain_01.wav" or a folder named "test" are false hits).

## Testing
- `cd phase0 && python -m pytest`: fast, model-free tests (`tests/test_core.py`). These run on every push via `.github/workflows/checks.yml` with `requirements-ci.txt`.
- `./lab selftest` (or `--quick`) generates a synthetic library and checks every tool end to end with real models. `.github/workflows/mac-selftest.yml` runs it on a macOS arm64 runner (manual trigger). That runner reports MPS but fails any allocation ("MPS backend out of memory"), so it exercises the CPU fallbacks in `Embedder.__init__`/`_with_fallback` and `analyze_music.py`.
- Real-sound sanity set used in development: ESC-50 clips (CC BY-NC, test only, not bundled).
- Reports were checked in headless Chromium (Playwright) for JS errors and local-file audio playback.
