# Phase 0: test the AI on your own files

These tools answer one question before building the Earmark Mac app: **does this
approach work on your sound packs and songs?** Each tool reads your folders,
writes a report in `~/SoundLab`, and opens it in your browser.

**Your files are never changed.** Every tool opens audio read-only and refuses
to run if the output folder is inside a sound folder. Nothing is uploaded: all
analysis runs on your Mac. Model downloads are the only network use.

## What you need

- A Mac with Apple Silicon (M1 or later). macOS 14 or newer.
- 16 GB of memory or more is recommended. With 8 GB, add `--model pe-av-base`.
- About 15 GB of free disk space for the AI models (downloaded once).
- Internet for the first run.

## 1. Install (once)

Open **Terminal**, go to this folder and run the setup:

```bash
cd ~/Downloads/sound-library/phase0     # wherever you put this folder
./setup.sh
```

(If you see "permission denied", run `bash setup.sh` instead.)

This installs `uv` (a small Python installer) if you don't have it, then puts
Python 3.12 and every package into a `.venv` folder here. Nothing is installed
system-wide.

Then check everything works. This also downloads the AI models (~11 GB):

```bash
./lab selftest
```

It creates a small made-up library, runs all four tools on it, and should end
with `Everything works.`

## 2. See what metadata your packs already have

```bash
./lab metadata "/Volumes/SFX/BOOM Library" "/Volumes/SFX/Other Pack"
```

(Tip: type `./lab metadata ` and drag folders from Finder onto the Terminal
window to insert their paths.)

The report shows, per pack, how many files have a description, keywords and a
UCS category, and **every raw metadata field found**. This tells us exactly
what the app's importer must read. It only reads file headers, so it is fast,
even for 100,000 files.

## 3. Find the best AI model for your library

```bash
./lab compare "/Volumes/SFX"
```

This uses the categories your vendors already put in the files as an answer
key. It measures how well each model:
- picks the right category,
- puts similar sounds together, and
- recognises variations of the same sound (e.g. "Whoosh Heavy Metal 01…05").

It tests Meta's **PE-AV large** and LAION's **CLAP**, plus both combined. It
samples up to 40 files per subcategory (3,000 maximum), so expect roughly
30–60 minutes the first time. Results are cached, so later runs are fast.

The report ends with a recommendation, for example "use pe-av-large with
`--shape-weight 0.3`".

## 4. Group sounds (the Soundly-style view)

```bash
./lab group "/Volumes/SFX" --category WHOOSH
```

The tool works in three layers:
1. **Vendor categories first.** UCS categories come from the files' metadata or filenames.
2. **AI fills the gaps.** Files with no category get one from the audio (out of all 753 UCS subcategories), marked **AI** with a confidence.
3. **Similarity groups inside each category.** For example, inside "Whooshes" you might get *Short · Bright · Swooshing* or *Long · Dark · Wind gust*. The AI judges texture; length, envelope and brightness movement judge shape.

In the report, pick a category on the left. On the sound map, similar sounds
sit close together. Click a dot to play it and see its closest matches across
all your packs.

Useful options:

| Option | What it does |
|---|---|
| `--category WHOOSH` | Only some UCS categories. Accepts subcategory, category or CatID, comma-separated: `WHOOSH,SWISH` or `SWOOSHES` or `WHSH,DSGNWhsh`. This filter uses the vendor metadata, so files without a category aren't included. Run without it (e.g. with `--limit`) to see the AI place those. |
| `--match "metal"` | Only files whose name, description or keywords contain the text. |
| `--limit 2000` | A random sample, for a quick look at a big library. |
| `--model pe-av-large+clap-general` | Combine both models. Slower, sometimes better; `compare` tells you. |
| `--shape-weight 0.3` | How much length, envelope and brightness count, from 0 to 1. |
| `--fine` | More, smaller groups. |
| `--min-group-size 5` | The smallest group size. |
| `--group-within category` | Group inside whole categories instead of subcategories (`all` groups everything together). |

Analysis results are cached in `~/SoundLab/cache`, so re-running with
different grouping options takes seconds.

**Speed:** the first analysis with `pe-av-large` takes roughly 0.3–1 s per file
on an M-series Mac. That's about an hour for 5,000 files. Start with
`--category` or `--limit`.

## 5. Tempo and key for a music folder

```bash
./lab music "/Users/you/Music/Library Songs"
```

For every song you get:
- **BPM**, from Beat This!. Three trained versions are averaged, and the beat grid is fitted to about ±0.05 BPM for steady songs. Songs that change tempo are flagged, with their range.
- **Beats per bar.**
- **Key**, from S-KEY, shown both as a name and in Camelot notation (8A, 9B…).
- **A second-opinion key** from a classic method. When the two disagree and S-KEY isn't confident, the song is flagged for a listen.
- **The BPM/key already in the song's tags** (if any), for comparison.

You can filter the report by BPM range or "mixes with" (Camelot neighbours),
and play every song.

**Measure accuracy on your music:** listen to some songs in the report, then:
1. Fix any wrong BPM or key (use ½× and 2× for half/double tempo).
2. Tick the songs you've checked.
3. Click **Download checked songs (CSV)**.
4. Run `./lab music "<same folder>" --truth ~/Downloads/checked_songs.csv`.

The report then shows how often tempo and key were right.

The results are also saved as `music_analysis.json`. That file is a preview of
the sidecar the app will keep. It includes every beat and downbeat time.

## If something goes wrong

| Problem | Fix |
|---|---|
| Sounds don't play in Safari | Use Chrome, or `./lab serve ~/SoundLab/<report folder>/<name>_report.html` (a local, read-only server for that report's files) |
| "Killed" or the Mac runs out of memory | Add `--model pe-av-base` (or `--half`) |
| `Refusing to run: the output folder … is inside your sound folder` | Working as intended. Pick another `--out` or leave the default (`~/SoundLab`) |
| A file "couldn't be analysed" | It's listed at the end of the report with the reason. AAC/ALAC files are decoded with macOS's own `afconvert`; installing `ffmpeg` (Homebrew) adds more formats |
| "the official Beat This! download server was unreachable" | Their server (JKU) was down. A community copy of the main tempo model was used instead. Run again later to get all three |

Remove everything the tools created: `rm -rf ~/SoundLab`, plus the model
downloads in `~/.cache/huggingface` and `~/.cache/torch`.

## What the results decide

After steps 2–5, these files answer the Phase 0 questions:

- `metadata_report.html` (or just the numbers at the top)
- `compare_models.json`
- the "Compared with your checked values" line from the music report

Together they decide which model the app ships with, what its importer must
read, and whether the key detector needs an upgrade. Results from other
people's libraries help too: share them by opening a GitHub issue. Share
the numbers only, never the audio.

## Models used

| Purpose | Model | Source | License |
|---|---|---|---|
| Sound embeddings, AI categories (default) | PE-AV large (Meta, Dec 2025) | `facebook/pe-av-large` | Apache-2.0 |
| Sound embeddings (alternative) | LAION CLAP general / fused | `laion/larger_clap_general`, `laion/clap-htsat-fused` | Apache-2.0 |
| Tempo, beats, downbeats | Beat This! final0–2 (CPJKU, ISMIR 2024) | github.com/CPJKU/beat_this | MIT (code and weights) |
| Key | S-KEY (Deezer, ICASSP 2025) | github.com/deezer/skey (pinned commit) | MIT |
| Categories | UCS v8.2.1 (82 categories, 753 subcategories) | universalcategorysystem.com | Public domain |

The models are downloaded on first use; none are stored in this repository.
Beat This!'s authors note that some of its training audio is copyrighted.
See `../THIRD_PARTY_NOTICES.md` for details, including library licenses.
