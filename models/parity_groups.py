"""The app's similarity groups (SoundGroups.swift) against Phase 0's `grouping.cluster` on the
same sounds and vectors (PE-AV + CLAP combined, centred per subcategory, no shape features).

    swift run -c release earmark-parity groups <copy.sqlite> <swift.json> [CatID,…]
    ../phase0/.venv/bin/python -I parity_groups.py <copy.sqlite> <swift.json> [CatID …] [--min-size N]

For each subcategory: groups and left-over sounds in each, and the adjusted Rand index between
the two (1 = the same groups), with Phase 0 run twice with different seeds as the baseline (UMAP
itself varies). Reads the database copy only.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
import warnings
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "phase0"))

from soundlab import grouping as G  # noqa: E402
from soundlab.analysis import similarity_space  # noqa: E402


def vectors(db: str, model: str) -> dict[int, np.ndarray]:
    rows = sqlite3.connect(db).execute("select soundId, vector from soundEmbedding where model = ? and vector is not null", (model,))
    return {i: np.frombuffer(v, dtype="<f4") for i, v in rows}


def combine(blocks):
    return np.concatenate([b / (np.linalg.norm(b, axis=-1, keepdims=True) + 1e-12) for b in blocks], axis=-1) / np.sqrt(len(blocks))


def main():
    args = sys.argv[1:]
    min_size = 5
    if "--min-size" in args:
        i = args.index("--min-size")
        min_size = int(args[i + 1])
        del args[i:i + 2]
    db, swift_path, wanted = args[0], args[1], set(args[2:])
    from sklearn.metrics import adjusted_rand_score as ari

    peav, clap = vectors(db, "pe-av-large"), vectors(db, "clap-general")
    for b in json.load(open(swift_path)):
        if wanted and b["catID"] not in wanted:
            continue
        ids = b["ids"]
        if len(ids) < 30:
            continue
        E = combine([np.stack([peav[i] for i in ids]), np.stack([clap[i] for i in ids])]).astype(np.float32)
        X = similarity_space(E, [], 0.0)
        t = time.time()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            py = G.cluster(X, min_size)
            py2 = G.cluster(X, min_size, seed=7)
        s = np.array(b["labels"])
        print(f"{b['catID']} {len(ids)}: Swift {s.max() + 1} groups / {(s < 0).sum()} left over; "
              f"Phase 0 {py.max() + 1} / {(py < 0).sum()} ({(time.time() - t) / 2:.1f} s); "
              f"ARI Swift–Phase 0 {ari(s, py):.2f}, Phase 0 seeds {ari(py, py2):.2f}", flush=True)


if __name__ == "__main__":
    main()
