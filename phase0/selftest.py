#!/usr/bin/env python3
"""Check that everything is installed and working, using a small synthetic
library (made-up sound effects with vendor-style metadata, and songs with
known tempo and key). Also downloads the AI models on first run.

    python selftest.py            # uses the default (best) model, pe-av-large
    python selftest.py --quick    # smaller model, faster download
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from soundlab.audio import DEFAULT_OUTPUT_ROOT  # noqa: E402
from soundlab.report import timestamp  # noqa: E402


def run(step: str, args: list[str]) -> bool:
    print(f"\n=== {step}\n$ {' '.join(Path(a).name if a.endswith('.py') else a for a in args)}")
    t = time.time()
    proc = subprocess.run([sys.executable, *args], cwd=HERE)
    print(f"--- {step}: {'ok' if proc.returncode == 0 else 'FAILED'} ({time.time() - t:.0f}s)")
    return proc.returncode == 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="use pe-av-small instead of pe-av-large")
    ap.add_argument("--keep", action="store_true", help="keep the synthetic test files afterwards")
    args = ap.parse_args()

    from soundlab.testdata import make_music_library, make_sfx_library

    model = "pe-av-small" if args.quick else "pe-av-large"
    root = DEFAULT_OUTPUT_ROOT / f"selftest-{timestamp()}"
    lib, music, reports = root / "library", root / "music", root / "reports"
    print(f"Creating a synthetic test library in {root} …")
    truth_sfx = make_sfx_library(lib)
    make_music_library(music, root / "truth.csv")

    results = {}
    results["metadata"] = run("1. Metadata inspector", ["inspect_metadata.py", str(lib), "--out", str(reports / "metadata"), "--no-open"])
    results["groups"] = run("2. Sound grouping", ["group_sounds.py", str(lib), "--model", model, "--group-within", "all",
                                                  "--min-group-size", "4", "--out", str(reports / "groups"), "--no-open"])
    results["compare"] = run("3. Model comparison", ["compare_models.py", str(lib), "--models", f"{model},clap-general",
                                                     "--out", str(reports / "compare"), "--no-open"])
    results["music"] = run("4. Music tempo & key", ["analyze_music.py", str(music), "--truth", str(root / "truth.csv"),
                                                    "--out", str(reports / "music"), "--no-open"])

    checks = []
    try:
        lines = (reports / "metadata" / "metadata.jsonl").read_text().splitlines()
        with_ucs = sum(1 for line in lines if json.loads(line)["ucs"])
        checks.append(("metadata: UCS category read for the 30 files that have one", with_ucs == 30, f"{with_ucs}/40"))
    except Exception as e:  # noqa: BLE001
        checks.append(("metadata output", False, str(e)))
    try:
        from sklearn.metrics import adjusted_rand_score

        g = json.loads((reports / "groups" / "groups.json").read_text())
        labels = [truth_sfx[f["name"]] for f in g["files"]]
        ari = adjusted_rand_score(labels, [f["group"] for f in g["files"]])
        checks.append(("grouping: the 5 kinds of sound are separated", ari >= 0.8, f"agreement {ari:.2f} (1.0 = perfect)"))
    except Exception as e:  # noqa: BLE001
        checks.append(("grouping output", False, str(e)))
    try:
        m = json.loads((reports / "music" / "music_analysis.json").read_text())
        ev = m["evaluation"]["your checked values"]
        checks.append(("music: tempo within 4%", ev["bpm_acc"] >= 0.8, f"{ev['bpm_acc']:.0%} of {ev['bpm_n']}"))
        checks.append(("music: key exactly right", ev["key_exact"] >= 0.8, f"{ev['key_exact']:.0%} of {ev['key_n']}"))
        tm = m["models"]["tempo"]
        checks.append(("music: tempo models", True, tm))
    except Exception as e:  # noqa: BLE001
        checks.append(("music output", False, str(e)))

    print("\n================ SELF-TEST SUMMARY")
    for step, ok in results.items():
        print(f"  {'PASS' if ok else 'FAIL'}  ran {step}")
    for name, ok, detail in checks:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: {detail}")
    print(f"\nReports: {reports}")
    if not args.keep:
        import shutil

        shutil.rmtree(lib, ignore_errors=True)
        shutil.rmtree(music, ignore_errors=True)
    all_ok = all(results.values()) and all(ok for _, ok, _ in checks)
    print("\nEverything works." if all_ok else "\nSomething failed — see the messages above.")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
