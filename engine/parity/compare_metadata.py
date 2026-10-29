"""Compares what the Swift code and the Rust engine read from the same audio files.

    python3 engine/parity/compare_metadata.py <folder> [--limit N]

Lists the audio files under <folder> (read-only), runs `earmark-parity metadata` (Swift) and
`earmark-engine metadata` (Rust) on them and prints every difference. Numbers must match within
1e-9 (relative); everything else exactly.
"""
import json, math, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AUDIO = {".wav", ".wave", ".bwf", ".aif", ".aiff", ".aifc", ".mp3", ".m4a", ".flac", ".ogg", ".caf"}


def files(folder, limit):
    out = []
    for d, dirs, names in os.walk(folder):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        for n in sorted(names):
            if not n.startswith(".") and os.path.splitext(n)[1].lower() in AUDIO:
                out.append(os.path.join(d, n))
                if limit and len(out) >= limit:
                    return out
    return out


def run(cmd, paths):
    r = subprocess.run(cmd, input="\n".join(paths) + "\n", capture_output=True, text=True, check=True)
    return [json.loads(line) for line in r.stdout.splitlines()]


def diff(a, b, where, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(f"{where}/{k}: swift={a.get(k)!r} rust={b.get(k)!r}")
            else:
                diff(a[k], b[k], f"{where}/{k}", out)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{where}[{i}]", out)
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        if not math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12):
            out.append(f"{where}: swift={a!r} rust={b!r}")
    elif a != b:
        out.append(f"{where}: swift={a!r} rust={b!r}")


def main():
    folder = sys.argv[1]
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 0
    paths = files(folder, limit)
    swift = run([os.path.join(ROOT, "app/.build/release/earmark-parity"), "metadata"], paths)
    rust = run([os.path.join(ROOT, "engine/target/release/earmark-engine"), "metadata"], paths)
    assert len(swift) == len(rust) == len(paths), (len(swift), len(rust), len(paths))
    bad = 0
    for s, r in zip(swift, rust):
        out = []
        diff(s, r, "", out)
        if out:
            bad += 1
            if bad <= 20:
                print(s["path"])
                for line in out[:10]:
                    print("   ", line)
    print(f"{len(paths)} files, {bad} with differences")
    sys.exit(1 if bad else 0)


main()
