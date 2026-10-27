"""The app's sound map (SoundMap.swift, a Swift UMAP) against umap-learn with Phase 0's settings.

For the sounds a map was made of (`earmark-parity map <copy.sqlite> <out.json> [category]`),
runs umap-learn on the same vectors (PE-AV + CLAP combined as Phase 0 did) and scores both maps
the same way: the share of each sound's 15 nearest neighbours (cosine, in the embedding space)
that are among its 15 nearest on the map. Run with Phase 0's environment (it has umap-learn):

    ../phase0/.venv/bin/python -I parity_map.py <copy of library.sqlite> <swift map.json> [more maps…]

Reads the database copy only.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
import warnings

import numpy as np


def vectors(db: str, model: str) -> dict[int, np.ndarray]:
    rows = sqlite3.connect(db).execute("select soundId, vector from soundEmbedding where model = ? and vector is not null", (model,))
    return {i: np.frombuffer(v, dtype="<f4") for i, v in rows}


def combine(blocks: list[np.ndarray]) -> np.ndarray:
    """Phase 0's combine_blocks: each block L2-normalised, concatenated, / sqrt(k)."""
    return np.concatenate([b / (np.linalg.norm(b, axis=-1, keepdims=True) + 1e-12) for b in blocks], axis=-1) / np.sqrt(len(blocks))


def kept(X: np.ndarray, Y: np.ndarray, k: int = 15, block: int = 2048) -> float:
    from sklearn.neighbors import NearestNeighbors

    _, mine = NearestNeighbors(n_neighbors=k + 1).fit(Y).kneighbors(Y)
    total = 0.0
    for s in range(0, len(X), block):
        S = X[s:s + block] @ X.T
        for r in range(S.shape[0]):
            S[r, s + r] = -np.inf
        orig = np.argpartition(-S, k, axis=1)[:, :k]
        for r in range(S.shape[0]):
            total += len(set(orig[r]) & set(mine[s + r][1:])) / k
    return total / len(X)


def main():
    db, maps = sys.argv[1], sys.argv[2:]
    peav, clap = vectors(db, "pe-av-large"), vectors(db, "clap-general")
    import umap

    for path in maps:
        m = json.load(open(path))
        ids = m["ids"]
        X = combine([np.stack([peav[i] for i in ids]), np.stack([clap[i] for i in ids])]).astype(np.float32)
        swift = np.c_[m["x"], m["y"]]
        t = time.time()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            py = umap.UMAP(n_components=2, n_neighbors=min(15, len(X) - 1), min_dist=0.15, metric="cosine",
                           random_state=42).fit_transform(X)
        seconds = time.time() - t
        print(f"{path.split('/')[-1]}: {len(ids)} sounds. Neighbours kept: Swift {kept(X, swift):.3f} "
              f"({m['seconds']:.1f} s), umap-learn {kept(X, py):.3f} ({seconds:.1f} s)", flush=True)


if __name__ == "__main__":
    main()
