"""Compares the Swift code and the Rust engine on the same real data. Only reads.

    python3 engine/parity/compare.py metadata <folder> [--limit N]
    python3 engine/parity/compare.py scan <folder>
    python3 engine/parity/compare.py twins <library.sqlite>
    python3 engine/parity/compare.py keys [<music_analysis.json>]
    python3 engine/parity/compare.py phase0 <music_analysis.json>

Runs the same mode of `earmark-parity` (Swift, app/.build/release) and `earmark-engine`
(Rust, engine/target/release) and prints every difference. Numbers must match within 1e-9
(relative), the rest exactly; a missing value and null are the same. Text compares as Swift's
String does, by canonical equivalence (Foundation's file URLs decompose accents: "é" as "e"
and a combining accent).
"""
import json, math, os, subprocess, sys, unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SWIFT = os.path.join(ROOT, "app/.build/release/earmark-parity")
RUST = os.path.join(ROOT, "engine/target/release/earmark-engine")
AUDIO = {".wav", ".wave", ".bwf", ".aif", ".aiff", ".aifc", ".mp3", ".m4a", ".flac", ".ogg", ".caf"}


def audio_files(folder, limit):
    out = []
    for d, dirs, names in os.walk(folder):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        for n in sorted(names):
            if not n.startswith(".") and os.path.splitext(n)[1].lower() in AUDIO:
                out.append(os.path.join(d, n))
                if limit and len(out) >= limit:
                    return out
    return out


def run(cmd, stdin=""):
    r = subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=True)
    return [json.loads(line) for line in r.stdout.splitlines()]


def diff(a, b, where, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            x, y = a.get(k), b.get(k)
            if x is None and y is None:
                continue
            if x is None or y is None:
                out.append(f"{where}/{k}: swift={x!r} rust={y!r}")
            else:
                diff(x, y, f"{where}/{k}", out)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{where}[{i}]", out)
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        if not math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-9):
            out.append(f"{where}: swift={a!r} rust={b!r}")
    elif isinstance(a, str) and isinstance(b, str):
        if unicodedata.normalize("NFC", a) != unicodedata.normalize("NFC", b):
            out.append(f"{where}: swift={a!r} rust={b!r}")
    elif a != b:
        out.append(f"{where}: swift={a!r} rust={b!r}")


def compare(swift, rust, label):
    if len(swift) != len(rust):
        print(f"{label}: swift has {len(swift)} rows, rust {len(rust)}")
        names = lambda rows: {r.get("path") or r.get("text") for r in rows}
        for p in sorted(names(swift) ^ names(rust))[:20]:
            print("    only in", "swift" if p in names(swift) else "rust", p)
        return 1
    bad = 0
    for s, r in zip(swift, rust):
        out = []
        diff(s, r, "", out)
        if out:
            bad += 1
            if bad <= 20:
                print(s.get("path") or s.get("text") or s.get("fileName") or "row")
                for line in out[:10]:
                    print("   ", line)
    print(f"{label}: {len(swift)} rows, {bad} with differences")
    return bad


def key_texts(phase0_file):
    """Every spelling the parser should know, some it shouldn't, and Phase 0's second opinions."""
    texts = []
    for note in "ABCDEFGabcdefg":
        for acc in ["", "#", "b", "♭", "♯", "B", " #"]:
            for mode in ["", "m", "M", "min", "maj", " minor", " Major", "moll", "dur", "mi", "x", " m "]:
                texts.append(f"{note}{acc}{mode}")
    for n in range(0, 14):
        for mode in "ABabdmDMx":
            texts += [f"{n}{mode}", f"0{n}{mode}", f"{n} {mode}"]
    texts += ["", " ", "nonsense", "H", "Cb minor", "E#", "B#m", "8 A", "  Am  ", "A\tm"]
    if phase0_file:
        tracks = json.load(open(phase0_file))["tracks"]
        texts += [t["key_second_opinion"] for t in tracks if t.get("key_second_opinion")]
    return texts


def main():
    mode, arg = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
    if mode == "metadata":
        limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 0
        paths = "\n".join(audio_files(arg, limit)) + "\n"
        bad = compare(run([SWIFT, "metadata"], paths), run([RUST, "metadata"], paths), "metadata")
    elif mode == "scan":
        bad = compare(run([SWIFT, "scan", arg]), run([RUST, "scan", arg]), "scan")
    elif mode == "twins":
        swift = run([SWIFT, "twins", arg])
        rust = run([RUST, "twins"], json.dumps(swift[0]))
        hidden = len(swift[0]["hidden"])
        bad = compare([{"alternates": swift[0]["alternates"], "hidden": swift[0]["hidden"]}],
                      [{"alternates": rust[0]["alternates"], "hidden": rust[0]["hidden"]}],
                      f"twins of {len(swift[0]['sounds'])} sounds ({hidden} hidden)")
    elif mode == "keys":
        texts = "\n".join(key_texts(arg)) + "\n"
        bad = compare(run([SWIFT, "keys"], texts), run([RUST, "keys"], texts), "keys")
    elif mode == "phase0":
        bad = compare(run([SWIFT, "phase0", arg]), run([RUST, "phase0", arg]), "phase0")
    else:
        sys.exit(__doc__)
    sys.exit(1 if bad else 0)


main()
