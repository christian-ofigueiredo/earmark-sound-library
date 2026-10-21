"""Fast checks that need no AI models (run on every push by GitHub Actions)."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from soundlab import ucs
from soundlab.audio import ensure_output_outside_inputs, find_audio_files, load_audio, trim_silence
from soundlab.features import FEATURE_NAMES, feature_matrix, shape_features
from soundlab.metadata import extract
from soundlab.music import camelot, key_relation, mirex_score, parse_key, summarize_beats
from soundlab.testdata import SR, make_sfx_library, sfx_airy_swish, sfx_beep

HERE = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def sfx_library(tmp_path_factory):
    root = tmp_path_factory.mktemp("library")
    truth = make_sfx_library(root)
    return root, truth


# ---------------------------------------------------------------- safety

def test_refuses_output_inside_sound_folder(tmp_path):
    lib = tmp_path / "library"
    lib.mkdir()
    with pytest.raises(SystemExit):
        ensure_output_outside_inputs(lib / "reports", [lib])
    assert ensure_output_outside_inputs(tmp_path / "reports", [lib]).is_dir()


def test_tools_never_write_into_the_library(sfx_library, tmp_path):
    root, _ = sfx_library
    before = {p: (p.stat().st_size, p.stat().st_mtime_ns) for p in root.rglob("*")}
    proc = subprocess.run([sys.executable, str(HERE / "inspect_metadata.py"), str(root), "--out", str(tmp_path / "m"),
                           "--no-open"], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    after = {p: (p.stat().st_size, p.stat().st_mtime_ns) for p in root.rglob("*")}
    assert before == after


# ---------------------------------------------------------------- metadata

def test_metadata_reads_ixml_bext_filenames_and_sheets(sfx_library, tmp_path):
    root, truth = sfx_library
    files = find_audio_files([root])
    assert len(files) == len(truth) == 40
    pack_a = next(f for f in files if "Pack A" in str(f))
    rec = extract(pack_a)
    assert rec["ucs"]["source"].startswith("iXML")
    assert rec["fields"]["description"] and rec["fields"]["keywords"]
    assert rec["raw"]["fields"]["bext"]["Originator"] == "SelfTest Audio"
    pack_b = next(f for f in files if "Pack B" in str(f))
    assert extract(pack_b)["ucs"]["source"] == "UCS filename"
    pack_c = next(f for f in files if "Pack C" in str(f))
    assert extract(pack_c)["ucs"] is None

    out = tmp_path / "meta"
    subprocess.run([sys.executable, str(HERE / "inspect_metadata.py"), str(root), "--out", str(out), "--no-open"],
                   check=True, capture_output=True)
    rows = [json.loads(line) for line in (out / "metadata.jsonl").read_text().splitlines()]
    b_rows = [r for r in rows if "Pack B" in r["path"]]
    assert all(r["sources"].get("description") == "vendor spreadsheet" for r in b_rows)
    assert sum(1 for r in rows if r["ucs"]) == 30


@pytest.mark.parametrize("stem,expected", [
    ("WHSH_Heavy Whoosh 01_SLAB_Lib", "WHSH"),
    ("AMBFORST_Birds_SLAB_Lib", "AMBForst"),   # all caps accepted
    ("rain_01", None),                         # ordinary word, not UCS
    ("Test_take", None),
])
def test_ucs_filename_rules(stem, expected):
    parsed = ucs.parse_ucs_filename(stem)
    assert (parsed["catid"] if parsed else None) == expected


def test_ucs_list_is_complete():
    entries = ucs.load_ucs()
    assert len(entries) == 753
    assert len({e.category for e in entries.values()}) == 82


# ---------------------------------------------------------------- audio + features

def test_load_trim_and_resample(sfx_library):
    root, _ = sfx_library
    f = find_audio_files([root])[0]
    x, sr = load_audio(f, sr=22050)
    assert sr == 22050 and x.dtype == np.float32 and len(x) > 0
    padded = np.concatenate([np.zeros(SR), np.ones(SR // 10, dtype=np.float32) * 0.5, np.zeros(SR)])
    assert len(trim_silence(padded, SR)) < SR // 5


def test_shape_features_tell_noise_from_tones():
    rng = np.random.default_rng(0)
    swish = shape_features(sfx_airy_swish(rng).astype(np.float32), SR)
    beep = shape_features(sfx_beep(rng).astype(np.float32), SR)
    assert beep["tonality"] > 0.6 > swish["tonality"]
    assert swish["centroid_hz"] > 2000
    M = feature_matrix([swish, beep, swish])
    assert M.shape == (3, len(FEATURE_NAMES)) and np.isfinite(M).all()


# ---------------------------------------------------------------- music

@pytest.mark.parametrize("text,label", [
    ("Am", (9, True)), ("A minor", (9, True)), ("C#m", (1, True)), ("Dbmaj", (1, False)),
    ("B♭m", (10, True)), ("8A", (9, True)), ("08B", (0, False)), ("1d", (0, False)), ("1m", (9, True)),
    ("G", (7, False)), ("nonsense", None), ("", None),
])
def test_parse_key(text, label):
    assert parse_key(text) == label


def test_camelot_and_scoring():
    assert camelot(0, False) == "8B" and camelot(9, True) == "8A" and camelot(6, False) == "2B"
    assert mirex_score((7, False), (0, False)) == 0.5        # a fifth above
    assert mirex_score((9, True), (0, False)) == 0.3         # relative minor
    assert mirex_score((0, True), (0, False)) == 0.2         # parallel
    assert key_relation((9, True), (0, False)) == "relative"


@pytest.mark.parametrize("bpm", [92.0, 128.0, 140.0, 172.0])
def test_tempo_is_precise_despite_the_20ms_grid(bpm):
    fps = 50
    period = 60.0 / bpm
    true_beats = 0.37 + period * np.arange(int(30 / period))
    n = int((true_beats[-1] + 1) * fps)
    t = np.arange(n) / fps
    prob = np.zeros(n)
    for b in true_beats:  # activation peaks centred on the true (off-grid) beat times
        prob = np.maximum(prob, np.exp(-0.5 * ((t - b) / 0.012) ** 2))
    grid = np.round(true_beats * fps) / fps  # what the model's peak picking returns
    out = summarize_beats(grid, grid[::4], prob, fps)
    assert out["stability"] == "steady"
    assert abs(out["bpm"] - bpm) < 0.1, out["bpm"]
    assert out["beats_per_bar"] == 4
