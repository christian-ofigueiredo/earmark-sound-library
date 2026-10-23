"""Parity of the Core ML PE-AV large against Phase 0, on the owner's real files.

For a random sample of files with a Phase 0 PE-AV embedding (~/SoundLab/cache),
re-runs Phase 0's own decode → trim → normalise → windows → feature extractor,
runs the five Core ML parts (convert_peav.py) one after another per window, and
compares the file vectors with Phase 0's: cosine, and whether each file keeps
its 5 nearest neighbours in the sample. PyTorch isn't loaded (it would need
another 4.5 GB); convert_peav.py already checks each part against it.

    .venv/bin/python -I parity_peav.py --files 300
    .venv/bin/python -I parity_peav.py --reference   # also writes build/peav_reference.json
    .venv/bin/python -I parity_peav.py --fixture     # also writes the Swift test fixture

Reads the audio only; nothing is written next to it.
"""

from __future__ import annotations

import argparse
import faulthandler
import gc
import json
import pickle
import random
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "phase0"))
sys.path.insert(0, str(HERE))

from soundlab.analysis import prepare  # noqa: E402  (Phase 0's exact audio path)
from soundlab.audio import file_signature, pick_windows  # noqa: E402
from soundlab.embeddings import MAX_WINDOWS, SAMPLE_RATE, WINDOW_S  # noqa: E402

CACHE = Path.home() / "SoundLab" / "cache" / "pe-av-large.pkl"
PARTS = ["PEAVEmbed", "PEAVLayers0", "PEAVLayers1", "PEAVLayers2", "PEAVLayers3"]


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


def overlap(a, b) -> float:
    return float(np.mean([len(set(x) & set(y)) / len(x) for x, y in zip(a, b)]))


class CoreMLPEAV:  # all parts loaded at once: only for Macs with memory to spare
    def __init__(self, folder: Path, units):
        import coremltools as ct

        self.parts = [ct.models.MLModel(str(folder / f"{p}.mlpackage"), compute_units=units) for p in PARTS]

    def __call__(self, input_values: np.ndarray) -> np.ndarray:
        x = self.parts[0].predict({"input_values": input_values})["hidden_out"]
        for p in self.parts[1:-1]:
            x = p.predict({"hidden": x})["hidden_out"]
        return self.parts[-1].predict({"hidden": x})["embedding"][0]


def fixture(fe) -> dict:
    """Reflect-padding and lengths for a few short windows, for the Swift tests."""
    out = []
    for n in (960, 1919, 1920, 5000, 479_999):
        x = (np.sin(np.arange(n) * 0.01) * 0.5).astype(np.float32)
        iv = fe([x], sampling_rate=SAMPLE_RATE, return_tensors="np")["input_values"][0, 0]
        out.append({"length": n, "padded": int(iv.size), "tail": [float(v) for v in iv[-8:]],
                    "around_end": [float(v) for v in iv[max(0, n - 4): n + 4]]})
    return {"windows": out}


def main():
    faulthandler.enable()
    import coremltools as ct
    from transformers import PeAudioFeatureExtractor

    ap = argparse.ArgumentParser()
    ap.add_argument("--files", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--reference", action="store_true")
    ap.add_argument("--fixture", action="store_true")
    ap.add_argument("--variants", default="PEAV,PEAV-fp16")
    args = ap.parse_args()

    fe = PeAudioFeatureExtractor.from_pretrained("facebook/pe-av-large")
    if args.fixture:
        path = HERE.parent / "app" / "Tests" / "EarmarkCoreTests" / "Fixtures" / "peav_padding.json"
        path.write_text(json.dumps(fixture(fe)))
        print(f"wrote {path}")

    ref = phase0_vectors()
    if args.reference:
        out = HERE / "build" / "peav_reference.json"
        out.write_text(json.dumps({p: [float(x) for x in v] for p, v in ref.items()}))
        print(f"wrote {out} ({len(ref)} files)")
    paths = sorted(ref)
    random.Random(args.seed).shuffle(paths)
    paths = paths[: args.files]

    # Part by part, as the app will run it on a 16 GB Mac shared with Resolve: only
    # one part (≤ 1.1 GB in float32) is loaded at a time; each window's hidden state
    # waits on disk for the next part. (With three or more float32 parts loaded at
    # once, Core ML's CPU path crashed under memory pressure.)
    windows_of: list[list[int]] = []        # file index → window ids
    kept: list[str] = []
    for variant in args.variants.split(","):
        folder = HERE / "build" / variant
        if not folder.exists():
            print(f"{variant}: not converted")
            continue
        scratch = HERE / "build" / "peav_hidden" / variant
        scratch.mkdir(parents=True, exist_ok=True)
        seconds = 0.0
        for index, part in enumerate(PARTS):
            model = ct.models.MLModel(str(folder / f"{part}.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
            if index == 0:
                windows_of, kept, w = [], [], 0
                for p in paths:
                    x, err = prepare(Path(p))
                    if x is None:
                        print(f"skip {Path(p).name}: {err}")
                        continue
                    ids = []
                    for win in pick_windows(x, SAMPLE_RATE, WINDOW_S, MAX_WINDOWS):
                        iv = fe([win], sampling_rate=SAMPLE_RATE, return_tensors="np")["input_values"].astype(np.float32)
                        started = time.time()
                        h = model.predict({"input_values": iv})["hidden_out"]
                        seconds += time.time() - started
                        np.save(scratch / f"{w}.npy", np.array(h, copy=True))
                        ids.append(w)
                        w += 1
                    windows_of.append(ids)
                    kept.append(p)
            else:
                last = index == len(PARTS) - 1
                for i in range(w):
                    h = np.load(scratch / f"{i}.npy")
                    started = time.time()
                    out = model.predict({"hidden": h})
                    seconds += time.time() - started
                    np.save(scratch / f"{i}.npy", np.array(out["embedding" if last else "hidden_out"], copy=True))
            print(f"{variant}: {part} done", flush=True)
            del model
            gc.collect()
        E = np.stack([l2(np.stack([np.load(scratch / f"{i}.npy")[0] for i in ids]).mean(0)) for ids in windows_of])
        P = np.stack([ref[p] for p in kept])
        c = np.sort((E * P).sum(1))
        print(f"{variant:10s} vs Phase 0 ({len(kept)} files, {w} windows): cosine min {c[0]:.5f}  "
              f"p1 {c[len(c) // 100]:.5f}  median {c[len(c) // 2]:.6f}   top-5 neighbours kept "
              f"{overlap(neighbours(E), neighbours(P)):.1%}   {seconds / w:.2f} s/window (CPU, model time)", flush=True)
        for f in scratch.glob("*.npy"):
            f.unlink()


if __name__ == "__main__":
    main()
