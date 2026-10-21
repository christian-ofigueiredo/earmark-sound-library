# Sound Library app: build plan

An open-source Mac app for sound-effect and music libraries, similar in spirit
to Soundly. It browses the libraries, groups similar sounds, and analyses music
tempo and key. **It never modifies the original files.**

## Decisions so far

| Topic | Decision | Why |
|---|---|---|
| Distribution | Open source (MIT), public on GitHub | Useful to other sound designers and editors. Bundled models and libraries must allow redistribution; the ones chosen so far do (MIT/Apache-2.0, see `THIRD_PARTY_NOTICES.md`) |
| Platform | Native Swift 6 app, macOS 26+, Apple Silicon only | Best audio stack, Neural Engine/GPU for the ML; macOS 27 drops Intel anyway |
| Original files | Read-only, always. Enforced by the sandbox (`files.user-selected.read-only`) and read-only security-scoped bookmarks | Requirement: "it can't write or change anything in the original files" |
| Memory | Central SQLite database (GRDB) in the app's Application Support folder. Files identified by an audio fingerprint, so renames and moves keep their data | Fast search over 100k+ files |
| Sidecars | One JSON per library/music folder, exported/imported on demand (format previewed by Phase 0's `music_analysis.json` / `groups.json`) | Moving analysis between Macs without touching the libraries |
| Layout | Window/tab 1: sound effects (categories → similarity groups, sound map, find similar). Window/tab 2: music (batch tempo + key on a folder) | What was asked for |
| Quality vs speed | Quality first: best available models, ensembles where they help | Requirement |

## Architecture

```
AudioIO        decode (AVFoundation; afconvert-class formats), resample, metadata readers
               (BWF bext, iXML incl. Soundminer USER/ASWG, RIFF INFO, ID3, XMP, acid/smpl)
LibraryCore    GRDB/SQLite + FTS5, FSEvents folder watching, fingerprints, sidecar import/export
Analysis       pipeline (actors, resumable, throttled on battery/thermal):
                 1 facts: duration, format, loudness, loop/one-shot, fingerprint
                 2 embedding: PE-AV audio encoder (Core ML) on ≤10 s windows, mean-pooled
                 3 shape features: envelope, brightness + its movement, tonality, onsets
                 4 categories: vendor UCS → else zero-shot vs 753 UCS prompts (precomputed text vectors)
                 5 grouping per subcategory: block-normalised embedding + shape → UMAP → HDBSCAN, named
                 6 music: Beat This! (tempo/beats/downbeats) + S-KEY (key) + classic second opinion
Taxonomy       UCS v8.2.1 (bundled), group names, user edits
AppUI          SwiftUI shell, AppKit NSTableView for 100k-row lists, Metal waveform + sound map,
               AVAudioEngine playback, drag to DAW/NLE (file promises), keyboard-driven review
```

The ML runs on-device. Models are converted from PyTorch with coremltools
(Core ML today; Apple's new Core AI framework once it's confirmed to run the
converted models). Text vectors for UCS categories and naming words are
precomputed, so the app only needs a text encoder for free-text search.

## Phase 0 (this repo's `phase0/`): prove it on real files

Python versions of every piece run on your own packs and songs.
Results so far, on test data in the build container:

| Check | Result |
|---|---|
| PE-AV (small) zero-shot UCS on 72 real recordings (ESC-50, 12 kinds) | correct subcategory 83% top-1, 99% top-3 (out of 753; counting closely equivalent subcategories as correct) |
| CLAP general, same test | 74% / 93% |
| Grouping 72 real recordings into their 12 kinds | adjusted Rand index 1.00 (PE-AV small and CLAP) |
| Grouping 40 synthetic SFX incl. files with no metadata | 1.00 |
| Tempo on 6 synthetic songs (92–172 BPM) | all within ±0.03 BPM after sub-frame beat refinement |
| Key on the same songs (major and minor, unambiguous cadences) | S-KEY 6/6; classic profile method 70% MIREX score |
| Tempo change 100 → 124 BPM | flagged "variable", range 100–124 |

Lessons that carry into the app:
- **Centre embeddings per set before clustering.** It fixed PE-AV's grouping (0.94 → 1.00).
- **Shape-feature weight depends on scope.** Across very different sounds it hurts; inside one subcategory it's what separates e.g. whoosh types. Defaults: 0.3 within a subcategory, 0.15 within a category, 0.1 across all. `compare_models.py` tunes it on vendor FX-name families.
- **Beat This! outputs a 20 ms grid.** BPM needs sub-frame peak interpolation plus a robust line fit, otherwise steady songs read ~2% off (128 → 130.7).
- **Don't call S-KEY's `detect_key()` on a folder:** it writes a `prediction/` folder into the music folder. Call the model directly.
- **transformers 5.20 `PeAudioModel.get_text_audio_embeds` forgets `output_hidden_states`.** Call the text model directly.
- **CLAP's feature extractor randomly crops clips longer than 10 s.** Window audio to ≤10 s first.

Still to answer with real libraries (see `phase0/README.md`):
1. How complete the vendor metadata is per pack (`inspect_metadata.py`).
2. PE-AV large vs CLAP vs both on the real library, and the best shape weight (`compare_models.py`).
3. Whether whoosh groups make sense to a sound designer's ear (`group_sounds.py --category WHOOSH`).
4. Tempo/key accuracy on the real music folder (`analyze_music.py --truth`).

## Build phases after Phase 0

| Phase | Weeks | Result |
|---|---|---|
| 1. Sound effects library | 4–5 | Read-only import, metadata readers, database, search, playback, waveforms |
| 2. Music window | 2–3 | Batch tempo/key (Core ML ports), table, corrections, filters, sidecar export |
| 3. Grouping | 4–5 | AI categories for gaps, similarity groups, find similar, sound map |
| 4. Polish | 2–3 | Duplicates, drag to DAW, speed on the full library |

About 3–4 months for one experienced Swift developer.

## Risks

- **Core ML conversion of PE-AV large.** The 1.5B-parameter audio and text towers may need splitting or 8-bit palettisation to run well. Fallbacks: pe-av-base, or CLAP (much smaller), if `compare` shows a small gap.
- **Fine-grained grouping quality.** It is judged by ear. The plan relies on the review tools (rename, merge, split, drag) and on remembering corrections.
- **Beat This! weights host.** JKU's server was down during Phase 0. Bundle the weights with the app (MIT) instead of downloading at runtime.
- **Training-data terms.** The model weights are MIT/Apache-2.0, but Beat This!'s authors note that some training audio is copyrighted. Keep `THIRD_PARTY_NOTICES.md` current so people redistributing builds can judge for themselves.
