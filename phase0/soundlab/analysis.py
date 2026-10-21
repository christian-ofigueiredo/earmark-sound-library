"""Per-file analysis shared by group_sounds.py and compare_models.py:
AI embeddings (one or more models) + shape features, cached."""

from __future__ import annotations

import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from tqdm import tqdm

from .audio import AudioLoadError, file_signature, load_audio, peak_normalize, pick_windows, trim_silence
from .embeddings import MAX_WINDOWS, MODELS, SAMPLE_RATE, WINDOW_S, Cache, Embedder
from .features import feature_matrix, shape_features

MAX_SECONDS = 600.0


def parse_models(spec: str) -> list[str]:
    """'pe-av-large' or an ensemble 'pe-av-large+clap-general'."""
    names = [s.strip() for s in spec.split("+") if s.strip()]
    for n in names:
        if n not in MODELS:
            raise SystemExit(f"Unknown model '{n}'. Choose from: {', '.join(MODELS)} (combine with '+')")
    return names


def prepare(path: Path):
    """Decode + trim + normalize (runs in worker threads)."""
    try:
        x, sr = load_audio(path, sr=SAMPLE_RATE, max_seconds=MAX_SECONDS)
    except (AudioLoadError, Exception) as e:  # noqa: BLE001
        return None, str(e)
    x = trim_silence(x, sr)
    if x.size < int(0.02 * sr) or float(np.max(np.abs(x))) < 1e-6:
        return None, "silent or too short"
    return peak_normalize(x), None


class Analyzer:
    def __init__(self, model_names: list[str], cache_root: Path, device: str = "auto", half: bool = False):
        self.names = model_names
        self.caches = {n: Cache(cache_root, n) for n in model_names}
        self.feat_cache = self.caches[model_names[0]]
        self.device, self.half = device, half
        self._embedders: dict[str, Embedder] = {}
        self.seconds = defaultdict(float)  # embedding time per model (this run)
        self.counts = defaultdict(int)

    def embedder(self, name: str) -> Embedder:
        if name not in self._embedders:
            self._embedders[name] = Embedder(name, self.device, self.half)
        return self._embedders[name]

    def analyze(self, files: list[Path]) -> tuple[dict, dict]:
        """{path: {'embs': {model: vec}, 'feats': dict}}, {path: error}"""
        results, errors, todo = {}, {}, []
        for p in files:
            sig = file_signature(p)
            embs = {n: self.caches[n].get(Cache.emb_key(p, sig)) for n in self.names}
            feats = self.feat_cache.get(Cache.feat_key(p, sig))
            if feats is not None and all(v is not None for v in embs.values()):
                results[p] = {"embs": embs, "feats": feats}
            else:
                todo.append((p, sig, embs, feats))
        if results:
            print(f"{len(results)} files already analysed (cache), {len(todo)} to go.")
        if todo:
            for n in self.names:
                if any(t[2][n] is None for t in todo):
                    self.embedder(n)
        chunk = 16
        with ThreadPoolExecutor(max_workers=4) as pool, tqdm(total=len(todo), unit="file", desc="Analysing") as bar:
            for s in range(0, len(todo), chunk):
                part = todo[s:s + chunk]
                for (p, sig, embs, feats), (x, err) in zip(part, pool.map(lambda t: prepare(t[0]), part)):
                    bar.update(1)
                    if x is None:
                        errors[p] = err
                        continue
                    try:
                        windows = None
                        for n in self.names:
                            if embs[n] is None:
                                windows = windows or pick_windows(x, SAMPLE_RATE, WINDOW_S, MAX_WINDOWS)
                                t0 = time.perf_counter()
                                embs[n] = self.embedder(n).embed_audio(windows).astype(np.float32)
                                self.seconds[n] += time.perf_counter() - t0
                                self.counts[n] += 1
                                self.caches[n].put(Cache.emb_key(p, sig), embs[n])
                        if feats is None:
                            feats = shape_features(x, SAMPLE_RATE)
                            self.feat_cache.put(Cache.feat_key(p, sig), feats)
                    except Exception as e:  # noqa: BLE001
                        errors[p] = f"analysis failed: {e}"
                        continue
                    results[p] = {"embs": embs, "feats": feats}
                if s % (chunk * 20) == 0:
                    self.save()
        self.save()
        return results, errors

    def text(self, tag: str, prompts_per_label: list[list[str]], names: list[str] | None = None) -> np.ndarray:
        """Label embeddings for the (combined) model, cached per model."""
        parts = []
        for n in names or self.names:
            k = f"text::{tag}"
            v = self.caches[n].get(k)
            if v is None:
                print(f"Preparing {len(prompts_per_label)} text descriptions for {n} ({tag}, one-time)…")
                v = self.embedder(n).embed_labels(prompts_per_label)
                self.caches[n].put(k, v)
                self.caches[n].save()
            parts.append(v)
        return combine_blocks(parts)

    def save(self) -> None:
        for c in self.caches.values():
            c.save()


def combine_blocks(vectors: list[np.ndarray]) -> np.ndarray:
    """Concatenate L2-normalized vectors from several models so that cosine
    similarity of the result is the average of the per-model similarities."""
    if len(vectors) == 1:
        return vectors[0]
    k = len(vectors)
    return np.concatenate([v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-12) for v in vectors], axis=-1) / np.sqrt(k)


def embedding_matrix(results: dict, files: list[Path], names: list[str]) -> np.ndarray:
    return np.stack([combine_blocks([results[f]["embs"][n] for n in names]) for f in files]).astype(np.float32)


def _block_normalize(B: np.ndarray) -> np.ndarray:
    """Centre on the set and scale to unit average spread."""
    B = B - B.mean(axis=0, keepdims=True)
    return B / np.sqrt((B ** 2).sum(axis=1).mean() + 1e-12)


def similarity_space(E: np.ndarray, feats: list[dict], shape_weight: float) -> np.ndarray:
    """Vectors for grouping a set of sounds: AI embedding and shape features
    each centred and scaled on *this* set, then mixed so shape_weight is the
    share of the spread that comes from shape features."""
    w = float(np.clip(shape_weight, 0.0, 1.0))
    parts = [np.sqrt(1 - w) * _block_normalize(E.astype(np.float64))]
    if w > 0 and len(E) > 2:
        parts.append(np.sqrt(w) * _block_normalize(feature_matrix(feats)))
    return np.hstack(parts).astype(np.float32)
