"""Compare the vectors the app stored with Phase 0's for the same files.

    .venv/bin/python -I check_app_embeddings.py            # CLAP
    .venv/bin/python -I check_app_embeddings.py pe-av-large

Reads Earmark's database (read-only) and build/clap_reference.json or
build/peav_reference.json (from parity_clap.py / parity_peav.py --reference).
Reports cosine and top-5 neighbour agreement.
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

import numpy as np

DB = Path.home() / "Library" / "Application Support" / "Earmark" / "library.sqlite"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "clap-general"
REF = Path(__file__).resolve().parent / "build" / ("peav_reference.json" if MODEL == "pe-av-large" else "clap_reference.json")


def main():
    ref = json.loads(REF.read_text())
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    rows = con.execute("""
        SELECT s.path, e.vector, e.error FROM soundEmbedding e JOIN sound s ON s.id = e.soundId
        WHERE e.model = ?""", (MODEL,)).fetchall()
    stored = len(rows)
    errors = sum(1 for _, v, err in rows if err)
    silent = sum(1 for _, v, err in rows if v is None and not err)
    pairs = [(p, np.frombuffer(v, dtype="<f4")) for p, v, err in rows if v is not None and p in ref]
    print(f"{stored} stored ({errors} errors, {silent} silent); {len(pairs)} also in Phase 0")
    if not pairs:
        return
    A = np.stack([v for _, v in pairs])
    B = np.stack([np.asarray(ref[p], dtype=np.float32) for p, _ in pairs])
    c = np.sort((A * B).sum(1))
    print(f"cosine to Phase 0: min {c[0]:.5f}  p1 {c[len(c) // 100]:.5f}  median {c[len(c) // 2]:.6f}")
    if len(pairs) > 5:
        def nb(E):
            S = E @ E.T
            np.fill_diagonal(S, -np.inf)
            return np.argsort(-S, axis=1)[:, :5]
        kept = np.mean([len(set(x) & set(y)) / 5 for x, y in zip(nb(A), nb(B))])
        print(f"top-5 neighbours kept: {kept:.1%}")


if __name__ == "__main__":
    main()
