#!/usr/bin/env python3
"""Which AI model understands *your* sound library best?

Uses the categories your vendors already put in the files (BOOM etc.) as the
answer key and measures, for each model (and for the models combined):

  1. AI categories      – does zero-shot UCS categorisation pick the vendor's
                          subcategory? (top-1 / top-3, and category level)
  2. Similar sounds     – are a sound's 5 nearest neighbours in the same
                          subcategory? (what "find similar" relies on)
  3. Sound families     – inside one subcategory, is the nearest sound from the
                          same family (same FX name without the take number,
                          e.g. "Whoosh Heavy Metal 01..05")? Measured for
                          several shape-feature weights, which tunes how the
                          whoosh groups are built.

Your sound folders are only read, never changed.

Example:
    python compare_models.py "/Volumes/SFX" --models pe-av-large,clap-general
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from soundlab import report as R
from soundlab.analysis import Analyzer, embedding_matrix, similarity_space
from soundlab.audio import DEFAULT_OUTPUT_ROOT, ensure_output_outside_inputs, find_audio_files
from soundlab.embeddings import MODELS
from soundlab.metadata import extract
from soundlab.zeroshot import UCS_TEXT_TAG, ucs_prompts

SHAPE_WEIGHTS = [0.0, 0.15, 0.3, 0.45]
FAMILY_JUNK = re.compile(r"\b(?:v|var|vers|version|take|tk|alt|variation|mono|stereo|ms|lr|st|mx|mix)\b")


def family_of(fields: dict, path: Path) -> str | None:
    """'Whoosh Heavy Metal 03' -> 'whoosh heavy metal'."""
    name = fields.get("fxname") or path.stem
    s = name.lower().replace("_", " ").replace("-", " ")
    s = re.sub(r"\(.*?\)|\[.*?\]", " ", s)
    s = re.sub(r"\b[a-z]?\d+[a-z]?\b", " ", s)  # 03, 3a, v2, t12
    s = FAMILY_JUNK.sub(" ", s)
    s = re.sub(r"[^a-z ]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s or None


def centred(E: np.ndarray) -> np.ndarray:
    E = E - E.mean(axis=0, keepdims=True)
    return E / (np.linalg.norm(E, axis=1, keepdims=True) + 1e-12)


def knn_same_label(E: np.ndarray, labels: list, k: int = 5) -> float:
    """Average share of each sound's k nearest neighbours with the same label."""
    X = centred(E)
    S = X @ X.T
    np.fill_diagonal(S, -np.inf)
    nn = np.argsort(-S, axis=1)[:, :k]
    lab = np.array(labels)
    return float(np.mean(lab[nn] == lab[:, None]))


def family_precision(E: np.ndarray, feats: list[dict], catids: list[str], fams: list, weight: float) -> tuple[float, int]:
    """Within each subcategory: does the nearest sound belong to the same family?"""
    hits, total = 0, 0
    by_cat = defaultdict(list)
    for i, c in enumerate(catids):
        by_cat[c].append(i)
    for idx in by_cat.values():
        fam_counts = Counter(fams[i] for i in idx if fams[i])
        eligible = [i for i in idx if fams[i] and fam_counts[fams[i]] >= 2]
        if len(fam_counts) < 2 or len(eligible) < 4:
            continue
        idx = np.array(idx)
        X = similarity_space(E[idx], [feats[i] for i in idx], weight)
        X = X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-12)
        S = X @ X.T
        np.fill_diagonal(S, -np.inf)
        pos = {g: j for j, g in enumerate(idx)}
        for i in eligible:
            j = idx[int(np.argmax(S[pos[i]]))]
            hits += fams[j] == fams[i]
            total += 1
    return (hits / total if total else float("nan")), total


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folders", nargs="+", type=Path)
    ap.add_argument("--models", default="pe-av-large,clap-general",
                    help=f"comma-separated, from: {', '.join(MODELS)} (default pe-av-large,clap-general)")
    ap.add_argument("--max-per-subcategory", type=int, default=40, help="files per UCS subcategory (default 40)")
    ap.add_argument("--limit", type=int, default=3000, help="max files in total (default 3000)")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--device", default="auto")
    ap.add_argument("--half", action="store_true")
    ap.add_argument("--cache", type=Path, default=DEFAULT_OUTPUT_ROOT)
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    names = [m.strip() for m in args.models.split(",") if m.strip()]
    for n in names:
        if n not in MODELS:
            sys.exit(f"Unknown model {n}. Choose from {', '.join(MODELS)}")
    roots = [p.expanduser().resolve() for p in args.folders]
    out = ensure_output_outside_inputs(args.out or DEFAULT_OUTPUT_ROOT / f"compare-{R.timestamp()}", roots)
    ensure_output_outside_inputs(args.cache, roots)

    files = find_audio_files(roots)
    print(f"{len(files)} audio files. Reading metadata…")
    with ThreadPoolExecutor(max_workers=8) as pool:
        metas = dict(zip(files, pool.map(extract, files)))
    labelled = [f for f in files if metas[f]["ucs"]]
    if len(labelled) < 20:
        sys.exit(f"Only {len(labelled)} files have a vendor UCS category; need at least 20 to compare models.")
    by_cat = defaultdict(list)
    for f in labelled:
        by_cat[metas[f]["ucs"]["catid"]].append(f)
    rng = random.Random(42)
    sample = []
    for c, fs in sorted(by_cat.items()):
        fs = sorted(fs)
        rng.shuffle(fs)
        sample += fs[: args.max_per_subcategory]
    if len(sample) > args.limit:
        sample = rng.sample(sample, args.limit)
    sample.sort()
    print(f"Comparing on {len(sample)} files from {len({metas[f]['ucs']['catid'] for f in sample})} "
          f"UCS subcategories ({len(labelled)} files have vendor categories).")

    analyzer = Analyzer(names, args.cache, args.device, args.half)
    t0 = time.time()
    results, errors = analyzer.analyze(sample)
    sample = [f for f in sample if f in results]
    feats = [results[f]["feats"] for f in sample]
    catids = [metas[f]["ucs"]["catid"] for f in sample]
    cats = [metas[f]["ucs"]["category"] for f in sample]
    fams = [family_of(metas[f]["fields"], f) for f in sample]
    entries, prompts = ucs_prompts()
    entry_catid = np.array([e.catid for e in entries])
    entry_cat = np.array([e.category for e in entries])

    specs = [[n] for n in names] + ([names] if len(names) > 1 else [])
    rows = []
    for spec in specs:
        label = "+".join(spec)
        print(f"Scoring {label}…")
        E = embedding_matrix(results, sample, spec)
        T = analyzer.text(UCS_TEXT_TAG, prompts, spec)
        S = E @ T.T
        top = np.argsort(-S, axis=1)[:, :3]
        zs1 = float(np.mean(entry_catid[top[:, 0]] == np.array(catids)))
        zs3 = float(np.mean([c in entry_catid[t] for c, t in zip(catids, top)]))
        zcat = float(np.mean(entry_cat[top[:, 0]] == np.array(cats)))
        knn_sub = knn_same_label(E, catids)
        knn_cat = knn_same_label(E, cats)
        fam = {w: family_precision(E, feats, catids, fams, w) for w in SHAPE_WEIGHTS}
        secs = [analyzer.seconds[n] / analyzer.counts[n] for n in spec if analyzer.counts[n]]
        rows.append({"model": label, "zs_top1": zs1, "zs_top3": zs3, "zs_category": zcat,
                     "knn_subcategory": knn_sub, "knn_category": knn_cat,
                     "family": {str(w): v[0] for w, v in fam.items()}, "family_n": next(iter(fam.values()))[1],
                     "sec_per_file": float(sum(secs)) if secs else None})

    # overall score: equal parts categorisation, similarity, families (best weight)
    def best_family(r):
        vals = [v for v in r["family"].values() if v == v]
        return max(vals) if vals else float("nan")

    for r in rows:
        parts = [r["zs_top1"], r["knn_subcategory"]]
        bf = best_family(r)
        if bf == bf:
            parts.append(bf)
        r["score"] = float(np.mean(parts))
    best = max(rows, key=lambda r: r["score"])
    best_w = None
    vals = {float(w): v for w, v in best["family"].items() if v == v}
    if vals:
        best_w = max(vals, key=vals.get)

    (out / "compare_models.json").write_text(json.dumps({
        "files": len(sample), "rows": rows, "best": best["model"], "best_shape_weight": best_w,
        "errors": {str(k): v for k, v in errors.items()},
    }, indent=2), encoding="utf-8")

    def pct(v):
        return "–" if v is None or v != v else f"{v:.0%}"

    body = [R.cards([(f"{len(sample):,}", "files with vendor categories used"),
                     (str(len(set(catids))), "UCS subcategories"),
                     (best["model"], "best overall"),
                     ("–" if best_w is None else f"{best_w:g}", "best shape weight for families"),
                     (R.fmt_duration(time.time() - t0), "run time")])]
    body.append("<div class='note'>Higher is better everywhere. <b>AI categories</b>: the AI picks the vendor's UCS "
                "subcategory out of 753 with no hints. <b>Similar sounds</b>: share of each sound's 5 nearest "
                "neighbours from the same subcategory. <b>Families</b>: inside a subcategory, the closest sound is a "
                "variation of the same recording/design (same FX name).</div>")
    body.append("<div class='scroll'><table><thead><tr><th>Model</th><th>AI category top-1</th><th>top-3</th>"
                "<th>category level</th><th>Similar: same subcategory</th><th>same category</th>" +
                "".join(f"<th>Families, shape {w:g}</th>" for w in SHAPE_WEIGHTS) +
                "<th>Seconds per file</th><th>Overall</th></tr></thead><tbody>")
    for r in sorted(rows, key=lambda r: -r["score"]):
        star = " ★" if r is best else ""
        spf = "–" if r["sec_per_file"] is None else f"{r['sec_per_file']:.2f}"
        body.append(f"<tr><td><b>{R.esc(r['model'])}</b>{star}</td><td>{pct(r['zs_top1'])}</td><td>{pct(r['zs_top3'])}</td>"
                    f"<td>{pct(r['zs_category'])}</td><td>{pct(r['knn_subcategory'])}</td><td>{pct(r['knn_category'])}</td>" +
                    "".join(f"<td>{pct(r['family'][str(w)])}</td>" for w in SHAPE_WEIGHTS) +
                    f"<td>{spf}</td><td><b>{pct(r['score'])}</b></td></tr>")
    body.append("</tbody></table></div>")
    fam_n = rows[0]["family_n"] if rows else 0
    body.append(f"<p class='muted'>Families measured on {fam_n:,} sounds (subcategories with at least two named "
                "families). Seconds per file only counts files analysed in this run (cached files are free). "
                "Combined models use both embeddings; their time is the sum.</p>")
    rec = [f"Use <b>{R.esc(best['model'])}</b> for grouping (best overall)."]
    if best_w is not None:
        rec.append(f"For groups inside a subcategory, run group_sounds.py with <span class='mono'>--shape-weight {best_w:g}</span>.")
    body.append("<h2>Recommendation</h2><p>" + " ".join(rec) + "</p>")
    worst = Counter()
    E = embedding_matrix(results, sample, best["model"].split("+"))
    T = analyzer.text(UCS_TEXT_TAG, prompts, best["model"].split("+"))
    top1 = entry_catid[np.argmax(E @ T.T, axis=1)]
    for c, p in zip(catids, top1):
        if c != p:
            worst[(c, p)] += 1
    if worst:
        from soundlab import ucs

        body.append("<h2>Most common AI category mix-ups (best model)</h2><table><thead><tr><th>Vendor says</th>"
                    "<th>AI says</th><th>Files</th></tr></thead><tbody>")
        for (c, p), n in worst.most_common(25):
            body.append(f"<tr><td>{R.esc(ucs.lookup_catid(c).label)}</td><td>{R.esc(ucs.lookup_catid(p).label)}</td><td>{n}</td></tr>")
        body.append("</tbody></table>")
    html_path = out / "compare_models.html"
    R.write_and_open(html_path, R.page("Model comparison", f"{len(sample):,} files from your library", "\n".join(body)),
                     open_it=not args.no_open)
    print("\nResults:")
    for r in sorted(rows, key=lambda r: -r["score"]):
        print(f"  {r['model']:<28} AI category {pct(r['zs_top1']):>4} (top-3 {pct(r['zs_top3'])}), "
              f"similar {pct(r['knn_subcategory'])}, families {pct(best_family(r))}, overall {pct(r['score'])}")
    print(f"Best: {best['model']}" + (f", shape weight {best_w:g}" if best_w is not None else ""))
    print(f"Report: {html_path}")


if __name__ == "__main__":
    main()
