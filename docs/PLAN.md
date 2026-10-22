# Earmark: build plan

Earmark is an open-source Mac app for sound-effect and music libraries,
similar in spirit to Soundly. It:
- browses your libraries and groups similar sounds;
- fills in missing categories;
- finds the tempo and key of every song;
- sends sounds to DaVinci Resolve.

**It never modifies the original files.**

## Decisions so far

| Topic | Decision | Why |
|---|---|---|
| Name | **Earmark** | Chosen from five candidates after a quick name check |
| Distribution | Open source (MIT), public on GitHub | Useful to other sound designers and editors. Bundled models and libraries must allow redistribution; the ones chosen so far do (MIT/Apache-2.0, see `THIRD_PARTY_NOTICES.md`) |
| Platform | Native Swift app, Apple Silicon. Phase 1 targets macOS 14+ so it runs on any recent Mac; the minimum may rise later for Apple's newer ML frameworks | Best audio stack; the Neural Engine runs the ML |
| Original files | Read-only, always. Enforced by the sandbox (`files.user-selected.read-only`) and read-only security-scoped bookmarks | Requirement: "it can't write or change anything in the original files" |
| Memory | Central SQLite database (GRDB) in the app's Application Support folder. Files identified by an audio fingerprint, so renames and moves keep their data | Fast search over 100k+ files |
| Sidecars | One JSON per library/music folder, exported/imported on demand. Phase 0's `music_analysis.json` and `groups.json` can be imported, so existing analysis isn't redone | Moving analysis between Macs without touching the libraries |
| Layout | **Sound effects and music both from Phase 1**: window/tab 1 for sound effects (categories → similarity groups, sound map, find similar), window/tab 2 for music (tempo + key for a folder) | Both already exist as Phase 0 code |
| Library location | Libraries on external drives (here, a ~1 GB/s USB SSD). Sounds on an unplugged drive show as offline and keep all their data | The test library lives on an external SSD |
| Analysis scheduling | **Runs mainly when the Mac is idle (e.g. overnight).** The app says so on first launch and shows progress. Analysis is pausable, uses low priority, and backs off when the user is working (e.g. editing or exporting in Resolve) | 16 GB M1 Pro shared with video editing; analysis during a Resolve export slowed from ~4 s to ~24 s per file in Phase 0 |
| Models | **PE-AV large + CLAP combined** for sound embeddings (best or tied on every Phase 0 measure; CLAP adds ~4% to the time). Beat This! for tempo, S-KEY for key. All run with Core ML on the Neural Engine, in half precision if a parity check shows no loss | Quality first; leaves the GPU to Resolve |
| Sending to Resolve | Drag files into Resolve as usual. **For a selected part of a sound, the cut is made in Resolve on the original file, not as a new file.** The owner uses **Resolve Studio**, so the app uses Resolve's scripting API (import the original into the media pool, then `AppendToTimeline` with start/end frames at the playhead on a chosen audio track). Users of the free version, which removed scripting in 21.1, get a small timeline file (FCPXML/OTIO) referencing the original with the cut. A trimmed copy stays available as a last resort | The owner's request; Studio confirmed |
| Quality vs speed | Quality first: best available models, ensembles where they help | Requirement |
| Way of working | The owner approves changes before they're made; development happens on branches and reaches `main` once approved | The owner's request |

## How sounds get their category

From Phase 0 on the real library (below), in this order of trust:

1. **The vendor's UCS category** (iXML, UCS filenames): 17% of the test library.
2. **Vendor categories and folders mapped to UCS once.** This is a short table the user confirms, e.g. Sound Ideas' 128 folders ("Footsteps/Concrete", "Hits & Impacts"). It would take the test library from 17% to ~84% categorised.
3. **Learned from the user's own categorised files.** The AI compares a sound's embedding with those examples and reaches 62% exact subcategory (82% in the top 3, 73% category) in Phase 0. That's ~4× better than guessing blind.
4. **Names and descriptions combined with the audio**, zero-shot against the 753 UCS subcategories (21% exact, 41% top-3). This is used only when nothing better exists. Junk descriptions (web addresses, binary) are ignored.

Uncertain results go to a review list with the top 3 suggestions. Every
confirmation or correction becomes a new example for step 3.

## Architecture

```
AudioIO        decode (AVFoundation; afconvert-class formats), resample, metadata readers
               (BWF bext, iXML incl. Soundminer USER/ASWG, RIFF INFO, ID3, XMP, acid/smpl)
LibraryCore    GRDB/SQLite + FTS5, FSEvents folder watching, fingerprints, offline volumes,
               sidecar import/export (incl. Phase 0 JSON)
Analysis       background pipeline (actors, resumable, idle-aware, low priority, pausable):
                 1 facts: duration, format, loudness, loop/one-shot, fingerprint
                 2 embeddings: PE-AV large + CLAP (Core ML) on ≤10 s windows, mean-pooled;
                   long files read only where the windows are
                 3 shape features: envelope, brightness + its movement, tonality, onsets
                 4 categories: vendor UCS → vendor mapping → learned from user labels
                   → text+audio zero-shot; review list
                 5 grouping per subcategory: centred embedding + shape → UMAP → HDBSCAN, named
                 6 music: Beat This! (tempo/beats/downbeats) + S-KEY (key)
Taxonomy       UCS v8.2.1 (bundled), vendor mappings, group names, user edits
Resolve        Studio (primary): scripting bridge, original file appended with in/out at the
               playhead; free: FCPXML/OTIO with in/out; fallback: trimmed copy in a permanent folder
AppUI          SwiftUI shell, AppKit NSTableView for 100k-row lists, Metal waveform + sound map,
               AVAudioEngine playback, drag & drop, keyboard-driven review
```

## Phase 0 (`phase0/`): proving it on real files

### On test data, in the build container

| Check | Result |
|---|---|
| PE-AV (small) zero-shot UCS on 72 real recordings (ESC-50, 12 kinds) | correct subcategory 83% top-1, 99% top-3 (counting closely equivalent subcategories) |
| CLAP general, same test | 74% / 93% |
| Grouping 72 real recordings into their 12 kinds | adjusted Rand index 1.00 (PE-AV small and CLAP) |
| Tempo on 6 synthetic songs (92–172 BPM) | all within ±0.03 BPM |
| Key on the same songs | S-KEY 6/6; classic profile method 70% MIREX score |

### On the owner's library (29,177 sound effects, 61 h; 1,688 songs)

| Check | Result |
|---|---|
| Metadata | UCS category 17% (Ocular Sounds and BOOM Cinematic Impacts via UCS filenames/iXML). Description field 80%, but Sound Ideas (67% of files) stores its 7 broad categories there; its real detail is in 128 folders. 613 descriptions are web addresses or binary junk |
| Zero-shot categories, 2,740 vendor-labelled files, exact UCS subcategory | both models 16% (top-3 32%), PE-AV 13%, CLAP 13% |
| Same, adding names/descriptions to the audio | 21% (top-3 41%, category 43%) |
| Learned from the user's labelled files (5-fold, variations of one sound kept together) | 62% exact, 82% top-3, 73% category (PE-AV and both; CLAP 59%) |
| Same, on a pack labelled in a style never seen | 7–9%: vendors use different UCS conventions; UCS has near-duplicates (DESIGNED/IMPACT vs DESIGNED/BOOM vs MUSICAL/PERCUSSION) |
| Find similar (5 nearest in the same subcategory) | 53–56%; same category 69–72% |
| Whoosh groups (243 labelled whooshes) | clear groups by character: very short whips (0.2 s), small whooshes (~2 s), BOOM lead-ins (~19 s), longer passes. Naming flaws: pack names leak into keywords ("ocular", "b00m"), "Falling" overused |
| Speed, M1 Pro 16 GB (PyTorch, partly during a Resolve export) | PE-AV large ~2.8 s/file, CLAP ~0.12 s/file; music ~11 s/song |
| Music, 1,688 songs | Owner spot-checked online: tempo correct; key correct or its relative major/minor. But the report's flags are miscalibrated: 83% flagged, "tempo changes" on 51%, a few impossible tempos (2.6/328 BPM), "1 beat per bar" on 238 songs, key-confidence threshold tuned on synthetic songs |

Lessons that carry into the app:
- **Centre embeddings per set before clustering.** It fixed PE-AV's grouping.
- **Shape-feature weight depends on scope.** It hurts across very different sounds and helps inside one subcategory. On the real library the differences were within noise; 0.3 inside a subcategory stays the default.
- **Learning from the user's own labels beats zero-shot by far.** But vendors label differently, so the review list and corrections are core features.
- **Most "uncategorised" sounds are categorised in the vendor's own words** (folders, description prefixes). Map those to UCS once.
- **Beat This! outputs a 20 ms grid.** BPM needs sub-frame peak interpolation plus a robust line fit.
- **Tempo "stability" and beats per bar need sanity rules**: plausible BPM range, beat density, consistent bar lengths. Key confidence must be calibrated on real songs. The main key error is relative major/minor, so show the relative key as the alternative.
- **Don't call S-KEY's `detect_key()` on a folder**: it writes into the music folder. Call the model directly.
- **transformers 5.20 `PeAudioModel.get_text_audio_embeds` forgets `output_hidden_states`.** Call the text model directly.
- **CLAP's feature extractor randomly crops clips longer than 10 s.** Window audio to ≤10 s first.
- **Long files: read only the analysis windows**, not the whole file (matters on external drives).

## Build phases

| Phase | Weeks | Result |
|---|---|---|
| 1. Foundation, both windows | 4–5 | Swift app: read-only library import from external drives, metadata readers, database, search, playback, waveforms. Music window lists songs and imports Phase 0 analysis. Builds and tests run on a GitHub Mac for every push |
| 2. Analysis engine | 4–5 | Core ML ports (PE-AV large + CLAP, Beat This!, S-KEY) with parity tests against Phase 0; idle/overnight scheduler; categorisation pipeline incl. vendor mappings and review list |
| 3. Grouping | 3–4 | Similarity groups, names, find similar, sound map |
| 4. Resolve and polish | 2–3 | Resolve bridge (Studio scripting or FCPXML), duplicates, speed on the full library |

About 3–4 months for one experienced Swift developer.

## Risks

- **Core ML conversion of PE-AV large.** The audio and text towers (~1.5B parameters) may need splitting or 8-bit palettisation. Must keep parity with the Python version. Fallback: CLAP alone (3–4 points worse in Phase 0, ~20× faster).
- **Memory.** 16 GB is shared with Resolve: run analysis only when idle, and load one model at a time.
- **Resolve scripting API is partly undocumented** (`trackIndex`/`recordFrame` keys) and Studio-only. Pin to tested Resolve versions and keep the FCPXML route as a fallback; external scripting must be enabled in Resolve's preferences (Local).
- **Fine-grained grouping quality.** It's judged by ear. The plan relies on the review tools (rename, merge, split, drag) and on remembering corrections.
- **Beat This! weights host.** JKU's server was intermittently down. Bundle the weights with the app (MIT) instead of downloading at runtime.
- **Training-data terms.** The model weights are MIT/Apache-2.0, but Beat This!'s authors note that some training audio is copyrighted. Keep `THIRD_PARTY_NOTICES.md` current.
