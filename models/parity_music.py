"""Parity of the Core ML tempo and key models (convert_music.py) with Phase 0's PyTorch path.

Default: for a random sample of songs in Earmark's database, runs Phase 0's exact tempo and
key code (phase0/soundlab/music.py) twice, once with the PyTorch models and once with the
Core ML ones, and compares BPM, beats per bar, steadiness and key. Phase 0's own decode is
used for both, so only the models differ. (The app's Swift pipeline is checked against the
values Phase 0 stored with `earmark-parity music`.)

    .venv/bin/python -I parity_music.py --songs 20
    .venv/bin/python -I parity_music.py --fixture    # writes the Swift test fixture (generated signals only)

Reads the audio only; nothing is written next to it.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "phase0"))
sys.path.insert(0, str(HERE))

from soundlab import music  # noqa: E402  (Phase 0's tempo and key code)

SR = 22050
MAX_SECONDS = 20 * 60   # as phase0/analyze_music.py
DB = Path.home() / "Library" / "Application Support" / "Earmark" / "library.sqlite"
FIXTURE = HERE.parent / "app" / "Tests" / "EarmarkCoreTests" / "Fixtures" / "music_analysis.json"


def drums(seconds: float, bpm0: float, bpm1: float, per_bar: int) -> np.ndarray:
    """A drum loop with a chord under it: kick on every beat (louder on the first of the bar),
    snare on the off beats, hats on eighths; the tempo glides from bpm0 to bpm1.
    MusicAnalysisTests.drums() makes the same signal."""
    n = int(seconds * SR)
    t = np.arange(n, dtype=np.float64) / SR
    bpm = bpm0 + (bpm1 - bpm0) * t / seconds
    phase = (bpm0 * t + 0.5 * (bpm1 - bpm0) * t * t / seconds) / 60   # beats since the start
    k = np.floor(phase)
    since = (phase - k) * 60 / bpm                                     # seconds since the beat
    eighth = (2 * phase - np.floor(2 * phase)) * 30 / bpm
    accent = np.where(k % per_bar == 0, 1.0, 0.6)
    kick = np.sin(2 * np.pi * 55 * since) * np.exp(-30 * since) * accent
    snare = np.where(k % 2 == 1, np.sin(2 * np.pi * 1800 * since + 40 * np.sin(2 * np.pi * 370 * since)), 0) \
        * np.exp(-40 * since) * 0.3
    hats = np.sin(2 * np.pi * 7000 * eighth + 30 * np.sin(2 * np.pi * 1130 * eighth)) * np.exp(-80 * eighth) * 0.15
    chord = 0.1 * np.sin(2 * np.pi * 220 * t) + 0.1 * np.sin(2 * np.pi * 277.18 * t)
    return (kick + snare + hats + chord).astype(np.float32)


def f32(v) -> float:
    """A float32 written so it reads back exactly."""
    return float(f"{float(v):.9g}")


def fixture() -> dict:
    from beat_this.inference import aggregate_prediction, split_piece, split_predict_aggregate
    from beat_this.model.postprocessor import Postprocessor
    from beat_this.preprocessing import LogMelSpect

    out: dict = {}
    spect_fn = LogMelSpect()
    x = drums(40, 123, 123, 4)
    with torch.no_grad():
        spect = spect_fn(torch.from_numpy(x)).numpy()
    rng = np.random.default_rng(0)
    idx = np.sort(rng.choice(spect.size, 3000, replace=False))
    out["spectrogram"] = {"shape": list(spect.shape), "index": idx.tolist(),
                          "values": [f32(v) for v in spect.reshape(-1)[idx]], "mean": float(spect.mean(dtype=np.float64))}

    # Chunks: where they start, and which chunk each frame's prediction comes from.
    out["chunk_starts"] = {str(n): split_piece(torch.zeros(n, 1), 1500, 6, True)[1].tolist()
                           for n in (10, 1488, 1489, 1493, 1494, 1500, 2976, 2977, 4000, 60001)}
    n = 4000
    chunks, starts = split_piece(torch.zeros(n, 1), 1500, 6, True)
    preds = [{"beat": torch.arange(1500, dtype=torch.float32) + 10000 * (i + 1),
              "downbeat": torch.zeros(1500)} for i in range(len(chunks))]
    beat, _ = aggregate_prediction(preds, starts, n, 1500, 6, "keep_first", "cpu")
    out["aggregate"] = {"frames": n, "beat": beat.tolist()}

    # Beat This! (final0) on two loops, then Phase 0's postprocessing and summary.
    model, _ = music._load_beat_model("final0", "cpu")
    out["songs"] = []
    for name, (seconds, bpm0, bpm1, per_bar) in {"steady": (40, 123, 123, 4), "ramp": (45, 96, 116, 3)}.items():
        x = drums(seconds, bpm0, bpm1, per_bar)
        with torch.inference_mode():
            spect = spect_fn(torch.from_numpy(x))
            pred = split_predict_aggregate(spect=spect, chunk_size=1500, border_size=6,
                                           overlap_mode="keep_first", model=model)
            beat_p, down_p = torch.sigmoid(pred["beat"].float()), torch.sigmoid(pred["downbeat"].float())
            logit = lambda p: torch.log(p.clamp(1e-6, 1 - 1e-6)) - torch.log1p(-p.clamp(1e-6, 1 - 1e-6))  # noqa: E731
            beats, downbeats = Postprocessor(type="minimal")(logit(beat_p), logit(down_p))
        prob = beat_p.numpy()
        summary = music.summarize_beats(np.asarray(beats), np.asarray(downbeats), prob, fps=50)
        out["songs"].append({
            "name": name,
            "beat_logits": [f32(v) for v in pred["beat"].numpy()],
            "downbeat_logits": [f32(v) for v in pred["downbeat"].numpy()],
            "peaks": [float(b) for b in beats], "downbeats": [float(d) for d in downbeats],
            "refined": [float(b) for b in music.refine_peaks(np.asarray(beats, float), prob, 50)],
            "bpm": summary["bpm"], "bpm_range": summary.get("bpm_range"), "stability": summary["stability"],
            "beats_per_bar": summary.get("beats_per_bar"), "confidence": summary["tempo_confidence"],
        })
        print(f"{name}: {len(beats)} beats, {summary['bpm']} BPM, {summary['stability']}, "
              f"{summary.get('beats_per_bar')} per bar, confidence {summary['tempo_confidence']}")

    from skey.key_detection import key_map
    out["key_labels"] = [key_map[i] for i in range(24)]

    # The app's 44.1 → 22.05 kHz filter (HalfRate), designed with scipy, on a sweep to 20 kHz.
    import soxr
    from scipy.signal import firwin
    taps = firwin(601, 10540, window=("kaiser", 22.0), fs=44100)
    t = np.arange(2 * 44100) / 44100
    sweep = (0.5 * np.sin(2 * np.pi * (100 * t + 5000 * t * t))).astype(np.float32)
    half = np.convolve(sweep.astype(np.float64), taps)[300:300 + len(sweep)][::2]
    ref = soxr.resample(sweep, 44100, 22050, quality="VHQ")
    out["half_rate"] = {"taps": [f32(v) for v in taps], "index": list(range(0, len(half), 7)),
                        "values": [f32(half[i]) for i in range(0, len(half), 7)], "length": len(half)}
    print(f"half rate vs soxr on the sweep: rms Δ / rms {np.sqrt(np.mean((half - ref) ** 2) / np.mean(ref ** 2)):.1e}")
    return out


def coreml_models():
    import coremltools as ct

    beat = ct.models.MLModel(str(HERE / "build" / "BeatThis.mlpackage"))
    key = ct.models.MLModel(str(HERE / "build" / "SKey.mlpackage"))
    return beat, key


class CoreMLBeat(torch.nn.Module):
    """Stands in for the PyTorch Beat This! inside split_predict_aggregate."""

    def __init__(self, ml):
        super().__init__()
        self.ml = ml

    def forward(self, chunk):
        n = chunk.shape[1]
        x = np.zeros((1, 1500, 128), np.float32)
        x[:, :n] = chunk.numpy()
        got = self.ml.predict({"spect": x})
        return {"beat": torch.from_numpy(got["beat"][:, :n]), "downbeat": torch.from_numpy(got["downbeat"][:, :n])}


class CoreMLKey:
    def __init__(self, ml, labels):
        self.ml, self.labels = ml, labels

    def __call__(self, x):
        peak = float(np.max(np.abs(x))) or 1.0
        p = self.ml.predict({"audio": (x / peak).astype(np.float32)[None]})["probs"][0]
        order = np.argsort(-p)
        return {"key": self.labels[order[0]], "confidence": float(p[order[0]]),
                "margin": float(p[order[0]] - p[order[1]]), "runner_up": self.labels[order[1]]}


def compare(n_songs: int, seed: int, paths_file: str | None) -> None:
    import soxr

    from soundlab.audio import load_audio

    stored = {p: (bpm, pc, minor) for p, bpm, pc, minor in sqlite3.connect(DB).execute(
        "select path, bpm, keyPitchClass, keyMinor from song where bpm is not null or keyPitchClass is not null")}
    if paths_file:
        paths = [line.split("\t")[1] for line in Path(paths_file).read_text().splitlines() if line.startswith("SONG\t")]
    else:
        paths = sorted(p for p in stored if os.path.exists(p))
        random.Random(seed).shuffle(paths)
    tempo = music.TempoEstimator("cpu", ensemble=False)
    key = music.KeyEstimator("cpu")
    beat_ml, key_ml = coreml_models()
    tempo_ml = music.TempoEstimator("cpu", ensemble=False)
    tempo_ml.models = [CoreMLBeat(beat_ml)]
    key_coreml = CoreMLKey(key_ml, key.labels)
    same_bpm = same_key = same_bar = done = 0
    for p in paths[:n_songs]:
        x, sr = load_audio(Path(p), sr=44100, max_seconds=MAX_SECONDS)
        if x.size < sr * 2 or float(np.max(np.abs(x))) < 1e-5:
            continue
        x22 = soxr.resample(x, sr, SR, quality="VHQ").astype(np.float32)
        a, b = tempo(x22), tempo_ml(x22)
        ka, kb = key(x22), key_coreml(x22)
        done += 1
        same_bpm += a["bpm"] == b["bpm"]
        same_bar += a.get("beats_per_bar") == b.get("beats_per_bar")
        same_key += ka["key"] == kb["key"]
        print(f"{Path(p).name[:40]:40} BPM {a['bpm']} / {b['bpm']} (stored {stored.get(p, (None,))[0]}, "
              f"{len(a['beats'])} beats)  bar {a.get('beats_per_bar')} / "
              f"{b.get('beats_per_bar')}  key {ka['key']} {ka['confidence']:.3f} / {kb['key']} {kb['confidence']:.3f}",
              flush=True)
    print(f"\n{done} songs: same BPM {same_bpm}, same beats per bar {same_bar}, same key {same_key}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--songs", type=int, default=20)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--fixture", action="store_true")
    ap.add_argument("--paths", help="the SONG lines of `earmark-parity music … --songs` (the same songs)")
    args = ap.parse_args()
    if args.fixture:
        FIXTURE.write_text(json.dumps(fixture()))
        print(f"wrote {FIXTURE} ({FIXTURE.stat().st_size // 1024} KB)")
        return
    compare(args.songs, args.seed, args.paths)


if __name__ == "__main__":
    main()
