"""Data the app's similarity groups need from Phase 0 (run with Phase 0's environment):

    ../phase0/.venv/bin/python -I export_groups.py

1. The words groups are named with (Phase 0's `grouping.DESCRIPTORS`) and their text embeddings
   from PE-AV large and CLAP, as Phase 0 made them (its caches in ~/SoundLab/cache, prompts
   "w", "a w sound", "w sound effect"). The app has only the audio towers, so these are
   computed once here: app/Sources/EarmarkCore/Resources/group_words.bin (float32,
   little-endian: 99 × 1024 PE-AV, then 99 × 512 CLAP) and the words in SoundGroups.swift.
2. Test fixtures for the Swift HDBSCAN and Ward: synthetic points (blobs, and noise for
   HDBSCAN) and sklearn's labels, app/Tests/EarmarkCoreTests/Fixtures/hdbscan.json, ward.json.

Nothing here comes from the owner's library: the words are fixed English words, the points random.
"""

from __future__ import annotations

import json
import pickle
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
APP = HERE.parent / "app"
sys.path.insert(0, str(HERE.parent / "phase0"))

from soundlab import grouping as G  # noqa: E402


def words() -> None:
    cache = Path.home() / "SoundLab" / "cache"
    blocks = []
    for model, dims in (("pe-av-large", 1024), ("clap-general", 512)):
        data = pickle.load(open(cache / f"{model}.pkl", "rb"))
        v = np.asarray(data["text::descriptors-v1"], dtype=np.float32)
        assert v.shape == (len(G.DESCRIPTORS), dims), v.shape
        blocks.append(v)
    out = APP / "Sources" / "EarmarkCore" / "Resources" / "group_words.bin"
    out.write_bytes(b"".join(b.astype("<f4").tobytes() for b in blocks))
    print(f"{out}: {len(G.DESCRIPTORS)} words")
    print("let words = [" + ", ".join(json.dumps(w) for w in G.DESCRIPTORS) + "]")


def hdbscan_fixture() -> None:
    from sklearn.cluster import HDBSCAN

    rng = np.random.default_rng(7)
    cases = []
    for n_blobs, per, d, mcs in ((6, 40, 10, 5), (12, 15, 10, 5), (4, 60, 3, 8)):
        centres = rng.normal(0, 4, (n_blobs, d))
        spreads = rng.uniform(0.3, 1.2, n_blobs)
        pts = np.concatenate([c + rng.normal(0, s, (per, d)) for c, s in zip(centres, spreads)])
        noise = rng.uniform(pts.min(), pts.max(), (per, d))
        X = np.concatenate([pts, noise]).astype(np.float32)
        X = X[rng.permutation(len(X))]
        ms = max(2, mcs // 2)
        labels = HDBSCAN(min_cluster_size=mcs, min_samples=ms, cluster_selection_method="eom").fit_predict(X)
        cases.append({"dimensions": d, "minClusterSize": mcs, "minSamples": ms,
                      "points": [float(v) for v in X.ravel()], "labels": [int(v) for v in labels]})
        print(f"case: {len(X)} points, {labels.max() + 1} clusters, {(labels < 0).sum()} noise")
    out = APP / "Tests" / "EarmarkCoreTests" / "Fixtures" / "hdbscan.json"
    out.write_text(json.dumps({"cases": cases}))
    print(out)


def ward_fixture() -> None:
    from sklearn.cluster import AgglomerativeClustering

    rng = np.random.default_rng(11)
    cases = []
    for n_blobs, per, d, k in ((6, 30, 10, 6), (9, 25, 10, 5), (3, 50, 4, 7)):
        centres = rng.normal(0, 3, (n_blobs, d))
        X = np.concatenate([c + rng.normal(0, rng.uniform(0.5, 1.5), (per, d)) for c in centres]).astype(np.float32)
        X = X[rng.permutation(len(X))]
        labels = AgglomerativeClustering(n_clusters=k, linkage="ward").fit_predict(X)
        cases.append({"dimensions": d, "groups": k, "points": [float(v) for v in X.ravel()],
                      "labels": [int(v) for v in labels]})
        print(f"ward case: {len(X)} points, sizes {sorted(np.bincount(labels).tolist(), reverse=True)}")
    out = APP / "Tests" / "EarmarkCoreTests" / "Fixtures" / "ward.json"
    out.write_text(json.dumps({"cases": cases}))
    print(out)


if __name__ == "__main__":
    words()
    hdbscan_fixture()
    ward_fixture()
