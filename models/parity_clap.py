"""Parity of the Core ML CLAP against Phase 0, on the owner's real files.

For a random sample of files with a Phase 0 CLAP embedding (~/SoundLab/cache),
re-runs Phase 0's own decode → trim → normalise → windows → features, then
embeds each window with PyTorch (CPU) and the Core ML models (CPU + Neural
Engine, as the app runs them) and compares the file vectors with Phase 0's:
cosine, and whether each file keeps its 5 nearest neighbours in the sample.

    .venv/bin/python parity_clap.py --files 300
    .venv/bin/python parity_clap.py --fixture     # also writes the Swift test fixture
    .venv/bin/python parity_clap.py --reference   # also writes build/clap_reference.json
                                                  # (paths + Phase 0 vectors, for the app's
                                                  # end-to-end check; library data, not committed)

Reads the audio only; nothing is written next to it.
"""

from __future__ import annotations

import argparse
import json
import pickle
import random
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "phase0"))
sys.path.insert(0, str(HERE))

from soundlab.analysis import prepare  # noqa: E402  (Phase 0's exact audio path)
from soundlab.audio import file_signature, pick_windows  # noqa: E402
from soundlab.embeddings import MAX_WINDOWS, SAMPLE_RATE, WINDOW_S  # noqa: E402

CACHE = Path.home() / "SoundLab" / "cache" / "clap-general.pkl"


def l2(x):
    return x / np.maximum(np.linalg.norm(x, axis=-1, keepdims=True), 1e-12)


def phase0_vectors() -> dict[str, np.ndarray]:
    data = pickle.load(open(CACHE, "rb"))
    out = {}
    for k, v in data.items():
        if not k.startswith("emb|"):
            continue
        _, path, sig, _ = k.split("|")
        try:
            if file_signature(Path(path)) == sig:
                out[path] = np.asarray(v, dtype=np.float32)
        except FileNotFoundError:
            pass
    return out


def neighbours(E: np.ndarray, k: int = 5) -> np.ndarray:
    S = E @ E.T
    np.fill_diagonal(S, -np.inf)
    return np.argsort(-S, axis=1)[:, :k]


def overlap(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.mean([len(set(x) & set(y)) / len(x) for x, y in zip(a, b)]))


def fixture_signal() -> np.ndarray:
    """Formula-only test signal (Swift rebuilds it exactly): 0.5 s silence, 23 s of a
    chirp + tone + decaying clicks, 1 s silence. 48 kHz, float32."""
    sr = SAMPLE_RATE
    t = np.arange(int(23 * sr), dtype=np.float64) / sr
    body = 0.4 * np.sin(2 * np.pi * (200 * t + 40 * t ** 2)) + 0.2 * np.sin(2 * np.pi * 3000 * t) * np.exp(-0.1 * t)
    body += 0.5 * np.exp(-200 * (t % 2.0)) * np.sin(2 * np.pi * 800 * t)
    body[: int(3 * sr)] *= 0.01          # a quiet start, so one window is dropped as near-silent
    x = np.concatenate([np.zeros(sr // 2), body, np.zeros(sr)])
    return x.astype(np.float32)


def fixture(fe) -> dict:
    """Phase 0's prepare/windows and CLAP's features for fixture_signal(), so the
    Swift port can be checked without any audio files."""
    from soundlab.audio import peak_normalize, trim_silence

    x = fixture_signal()
    prepared = peak_normalize(trim_silence(x, SAMPLE_RATE))
    windows = pick_windows(prepared, SAMPLE_RATE, WINDOW_S, MAX_WINDOWS)
    short = prepared[: int(3.3 * SAMPLE_RATE)]          # a short window exercises repeat-padding
    out = {"prepared_length": int(prepared.size), "prepared_peak": float(np.abs(prepared).max()),
           "windows": [{"length": int(w.size), "first": float(w[0]), "rms": float(np.sqrt(np.mean(w ** 2)))}
                       for w in windows]}
    for name, w in (("long", windows[0]), ("short", short)):
        feats = fe([w], sampling_rate=SAMPLE_RATE, return_tensors="np")["input_features"][0, 0]   # (1001, 64)
        idx = list(range(0, feats.size, 97))
        out[name] = {"shape": list(feats.shape), "index": idx, "values": [float(feats.flat[i]) for i in idx],
                     "mean": float(feats.mean()), "std": float(feats.std())}
    return out


def main():
    import coremltools as ct
    import torch
    from convert_clap import AudioEmbedder, load_model
    from transformers import ClapFeatureExtractor

    ap = argparse.ArgumentParser()
    ap.add_argument("--files", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--fixture", action="store_true")
    ap.add_argument("--reference", action="store_true")
    args = ap.parse_args()

    fe = ClapFeatureExtractor.from_pretrained("laion/larger_clap_general")
    if args.fixture:
        path = HERE.parent / "app" / "Tests" / "EarmarkCoreTests" / "Fixtures" / "clap_features.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(fixture(fe)))
        print(f"wrote {path}")

    ref = phase0_vectors()
    if args.reference:
        out = HERE / "build" / "clap_reference.json"
        out.write_text(json.dumps({p: [float(x) for x in v] for p, v in ref.items()}))
        print(f"wrote {out} ({len(ref)} files)")
    paths = sorted(ref)
    random.Random(args.seed).shuffle(paths)
    paths = paths[: args.files]

    torch_model = AudioEmbedder(load_model()).eval()
    units = ct.ComputeUnit.CPU_AND_NE
    ml = {name: ct.models.MLModel(str(HERE / "build" / f"{name}.mlpackage"), compute_units=units)
          for name in ("CLAPAudio", "CLAPAudio-fp16")}

    rows = {"phase0": [], "torch": [], **{k: [] for k in ml}}
    window_cos = {k: [] for k in ml}
    for i, p in enumerate(paths):
        x, err = prepare(Path(p))
        if x is None:
            print(f"skip {Path(p).name}: {err}")
            continue
        windows = pick_windows(x, SAMPLE_RATE, WINDOW_S, MAX_WINDOWS)
        feats = [fe([w], sampling_rate=SAMPLE_RATE, return_tensors="np")["input_features"].astype(np.float32)
                 for w in windows]
        with torch.no_grad():
            t = np.concatenate([torch_model(torch.from_numpy(f)).numpy() for f in feats])
        rows["phase0"].append(ref[p])
        rows["torch"].append(l2(t.mean(0)))
        for name, m in ml.items():
            e = np.concatenate([m.predict({"melspec": f})["embedding"] for f in feats])
            window_cos[name].extend((e * t).sum(1))
            rows[name].append(l2(e.mean(0)))
        if (i + 1) % 50 == 0:
            print(f"{i + 1}/{len(paths)}")

    E = {k: np.stack(v) for k, v in rows.items()}
    nb = {k: neighbours(v) for k, v in E.items()}
    print(f"\n{len(E['phase0'])} files")
    for name in ("torch", *ml):
        c = (E[name] * E["phase0"]).sum(1)
        print(f"{name:15s} vs Phase 0: cosine min {c.min():.5f}  p1 {np.percentile(c, 1):.5f}  "
              f"median {np.median(c):.6f}   top-5 neighbours kept {overlap(nb[name], nb['phase0']):.1%}")
    for name in ml:
        c = (E[name] * E["torch"]).sum(1)
        w = np.array(window_cos[name])
        print(f"{name:15s} vs PyTorch: cosine min {c.min():.5f}  median {np.median(c):.6f}   "
              f"per window min {w.min():.5f}   top-5 kept {overlap(nb[name], nb['torch']):.1%}")


if __name__ == "__main__":
    main()
