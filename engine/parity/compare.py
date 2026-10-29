"""Compares the Swift code and the Rust engine on the same real data. Only reads.

    python3 engine/parity/compare.py metadata <folder> [--limit N]
    python3 engine/parity/compare.py scan <folder>
    python3 engine/parity/compare.py twins <library.sqlite>
    python3 engine/parity/compare.py keys [<music_analysis.json>]
    python3 engine/parity/compare.py phase0 <music_analysis.json>
    python3 engine/parity/compare.py audio <library.sqlite> [--count N]
    python3 engine/parity/compare.py similar <library.sqlite> [--count N]
    python3 engine/parity/compare.py dupsets <library.sqlite>
    python3 engine/parity/compare.py db <library.sqlite> <sounds folder> <music folder> <music_analysis.json>

Runs the same mode of `earmark-parity` (Swift, app/.build/release) and `earmark-engine`
(Rust, engine/target/release) and prints every difference. Numbers must match within 1e-9
(relative), the rest exactly; a missing value and null are the same. Text compares as Swift's
String does, by canonical equivalence (Foundation's file URLs decompose accents: "é" as "e"
and a combining accent).
"""
import datetime, json, math, os, shutil, sqlite3, subprocess, sys, tempfile, unicodedata

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


TOLERANCE = 1e-9


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
        if not math.isclose(a, b, rel_tol=TOLERANCE, abs_tol=TOLERANCE):
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


def sample_sounds(db, count, where="1"):
    """Sound ids and paths spread evenly over the library (every format and pack)."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(f"SELECT id, path FROM sound WHERE {where} ORDER BY path").fetchall()
    con.close()
    step = max(1, len(rows) // count)
    return [r for r in rows[::step] if os.path.exists(r[1])][:count]


def audio_mode(db, count):
    """Loudness and CLAP's input from the same decoded audio, in batches (the decoded files are big)."""
    sounds = sample_sounds(db, count)
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    stored = dict(con.execute("SELECT s.path, f.loudness FROM sound s JOIN soundFacts f ON f.soundId = s.id").fetchall())
    con.close()
    bad, worst_clap, worst_stored, windows, n = 0, 0.0, 0.0, 0, 0
    for b in range(0, len(sounds), 20):
        work = tempfile.mkdtemp(prefix="earmark-audio-parity-")
        try:
            paths = "\n".join(p for _, p in sounds[b:b + 20]) + "\n"
            swift = run([SWIFT, "audio", work], paths)
            rust = run([RUST, "audio", work], "\n".join(json.dumps(r) for r in swift) + "\n")
            for sw, ru in zip(swift, rust):
                n += 1
                windows += len(sw["windows"])
                clap = ru.pop("clapWorst")
                if not isinstance(clap, float) or clap > 1e-4:
                    bad += 1
                    print(sw["path"], "CLAP features differ by", clap)
                worst_clap = max(worst_clap, clap if isinstance(clap, float) else math.inf)
                out = []
                diff(sw, ru, "", out)
                if out:
                    bad += 1
                    print(sw["path"])
                    for line in out[:5]:
                        print("   ", line)
                if stored.get(sw["path"]) is not None and ru["loudness"]["integrated"] is not None:
                    worst_stored = max(worst_stored, abs(stored[sw["path"]] - ru["loudness"]["integrated"]))
        finally:
            shutil.rmtree(work)
    print(f"audio: {n} files, {windows} windows; CLAP features within {worst_clap:.2g} dB of Swift's; "
          f"loudness within {worst_stored:.2g} LU of the app's stored values; {bad} with differences")
    return bad


def similar_mode(db, count):
    ids = "\n".join(str(i) for i, _ in sample_sounds(db, count, "id IN (SELECT soundId FROM soundEmbedding WHERE model = 'clap-general')")) + "\n"
    swift, rust = run([SWIFT, "similar", db], ids), run([RUST, "similar", db], ids)
    bad, swapped = 0, 0
    for s, r in zip(swift, rust):
        if s["ids"] == r["ids"] and all(math.isclose(a, b, abs_tol=1e-5) for a, b in zip(s["scores"], r["scores"])):
            continue
        # Neighbours whose scores are equal to float precision may come in either order, and a tie
        # for the last place may go either way: Swift adds with vDSP, Rust in a plain loop.
        close = len(s["scores"]) == len(r["scores"]) and all(math.isclose(a, b, abs_tol=1e-5) for a, b in zip(s["scores"], r["scores"]))
        differing = set(s["ids"]) ^ set(r["ids"])
        scores = dict(zip(s["ids"], s["scores"])) | dict(zip(r["ids"], r["scores"]))
        if close and all(abs(scores[i] - s["scores"][-1]) <= 1e-5 for i in differing):
            swapped += 1
            continue
        bad += 1
        if bad <= 5:
            print(s["id"], s["ids"][:6], r["ids"][:6], s["scores"][:3], r["scores"][:3])
    print(f"similar: {len(swift)} sounds × 20 neighbours, {swapped} with ties (within 1e-5) in another order, {bad} differing")
    return bad


def db_tables(path):
    """Every table's rows, in primary key order."""
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    out = {}
    for (name,) in con.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"):
        cols = [r[1] for r in con.execute(f'PRAGMA table_info("{name}")')]
        order = ", ".join(str(i + 1) for i in range(min(2, len(cols))))
        out[name] = (cols, con.execute(f'SELECT * FROM "{name}" ORDER BY {order}').fetchall())
    schema = con.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").fetchall()
    con.close()
    return out, schema


def compare_dbs(a, b, label, skip=lambda table, col: False):
    (ta, sa), (tb, sb) = db_tables(a), db_tables(b)
    bad = 0
    if sa != sb:
        print(f"{label}: schemas differ")
        for x in sorted(set(sa) ^ set(sb)):
            print("    ", "swift" if x in sa else "rust", x)
        bad += 1
    for name in sorted(set(ta) | set(tb)):
        (ca, ra), (cb, rb) = ta.get(name, ([], [])), tb.get(name, ([], []))
        keep = [i for i, c in enumerate(ca) if not skip(name, c)]
        # Rows by their key (the first two columns); doubles to within a few units in the last
        # place: Foundation's JSONDecoder, which reads the operations on the Swift side, can be off
        # by that much (207.67927437641723 came back as …725).
        def same(x, y):
            if isinstance(x, float) and isinstance(y, float):
                return math.isclose(x, y, rel_tol=1e-14, abs_tol=0)
            return x == y
        ka = {tuple(r[:2]): r for r in ra}
        kb = {tuple(r[:2]): r for r in rb}
        problems = []
        if ca != cb:
            problems.append(f"columns differ: {ca} / {cb}")
        for k in sorted(set(ka) | set(kb), key=repr):
            x, y = ka.get(k), kb.get(k)
            if x is None or y is None:
                problems.append(f"{k}: only in {'rust' if x is None else 'swift'}")
                continue
            cols = [ca[i] for i, (u, v) in enumerate(zip(x, y)) if keep and i in keep and not same(u, v)]
            if cols:
                problems.append(f"{k}: " + ", ".join(f"{c} swift={x[ca.index(c)]!r} rust={y[ca.index(c)]!r}" for c in cols))
        if problems:
            bad += 1
            print(f"{label}: table {name}: {len(problems)} rows differ")
            for p in problems[:8]:
                print("    ", p[:300])
    rows = sum(len(t[1]) for t in ta.values())
    print(f"{label}: {len(ta)} tables, {rows} rows, {bad} differing")
    return bad


def seconds(text):
    """A GRDB date ("2025-08-01 08:51:00.098", UTC) as seconds since 1970."""
    d = datetime.datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc)
    return d.timestamp()


def db_mode(source, sounds_root, music_root, phase0_file):
    work = tempfile.mkdtemp(prefix="earmark-db-parity-")
    try:
        bad = 0
        # A new database from each: the same schema and migrations.
        run([SWIFT, "db-new", f"{work}/new-swift.sqlite"])
        run([RUST, "db-new", f"{work}/new-rust.sqlite"])
        bad += compare_dbs(f"{work}/new-swift.sqlite", f"{work}/new-rust.sqlite", "new database")
        # Each opens the other's.
        run([SWIFT, "db-ops", f"{work}/new-rust.sqlite"], "[]")
        run([RUST, "db-ops", f"{work}/new-swift.sqlite"], "[]")

        for name in ("swift", "rust"):
            subprocess.run(["sqlite3", f"file:{source}?mode=ro", f".backup {work}/{name}.sqlite"], check=True)
        con = sqlite3.connect(f"{work}/swift.sqlite")
        songs = con.execute("SELECT path, fileSize, modifiedAt, title, artist, album, duration, id FROM song ORDER BY path").fetchall()
        con.close()
        scanned = run([RUST, "scan", sounds_root])

        # Scans of the library: moved, removed, restored, then the library removed and added again.
        by_fp = {}
        for s in scanned:
            by_fp.setdefault(s["fingerprint"], []).append(s)
        unique = [s for s in scanned if len(by_fp[s["fingerprint"]]) == 1]
        moved = {s["path"] for s in unique[::97]}
        removed = {s["path"] for s in scanned[::53]} - moved
        def mutated():
            out = []
            for s in scanned:
                if s["path"] in removed:
                    continue
                if s["path"] in moved:
                    s = dict(s, path=sounds_root.rstrip("/") + "/Moved Here/" + os.path.basename(s["path"]))
                out.append(s)
            return sorted(out, key=lambda s: s["path"])
        # A copy at a new path of a file that's still there: a new sound.
        copy = dict(unique[5], path=sounds_root.rstrip("/") + "/Copies/" + os.path.basename(unique[5]["path"]))
        ops = [
            {"op": "replaceSounds", "path": sounds_root, "root": sounds_root, "scanned": scanned},
            {"op": "replaceSounds", "path": sounds_root, "root": sounds_root, "scanned": mutated()},
            {"op": "replaceSounds", "path": sounds_root, "root": sounds_root, "scanned": sorted(scanned + [copy], key=lambda s: s["path"])},
            {"op": "removeLibrary", "path": sounds_root},
            {"op": "addLibrary", "kind": "sounds", "path": sounds_root},
            {"op": "replaceSounds", "path": sounds_root, "root": sounds_root, "scanned": scanned},
        ]
        # The music folder: a rescan with some songs gone, new ones (accented names, in both
        # Unicode forms), one listed under the other form of its path, then Phase 0 and Earmark's
        # own analysis.
        files = [{"path": p, "fileSize": size, "modified": seconds(m), "title": t, "artist": a, "album": al, "duration": d}
                 for p, size, m, t, a, al, d, _ in songs]
        accented = [f for f in files if not f["path"].isascii()]
        kept = [f for i, f in enumerate(files) if i % 41 != 0]
        if accented:
            kept = [f for f in kept if f is not accented[0]] + [dict(accented[0], path=unicodedata.normalize("NFD", accented[0]["path"]))]
        kept += [{"path": music_root.rstrip("/") + "/Nova/Canção é Ótima.mp3", "fileSize": 1234, "modified": 1700000000.123456,
                  "title": "Canção", "artist": None, "album": None, "duration": 201.5},
                 {"path": unicodedata.normalize("NFD", music_root.rstrip("/") + "/Nova/Ação.mp3"), "fileSize": 99,
                  "modified": 1600000000.9999, "title": None, "artist": "Ü", "album": None, "duration": None}]
        ids = [r[7] for r in songs[::50]]
        ops += [
            {"op": "replaceSongs", "path": music_root, "root": music_root, "files": kept},
            {"op": "applySongAnalysis", "file": phase0_file},
            {"op": "saveSongAnalysis", "results": [{"songId": i, "analysis": {"bpm": 120.5, "beatsPerBar": 4, "source": "Earmark",
                                                    "key": {"pitchClass": 9, "minor": True}, "keyConfidence": 0.7}} for i in ids]},
        ]
        text = json.dumps(ops)
        out_swift = subprocess.run([SWIFT, "db-ops", f"{work}/swift.sqlite"], input=text, capture_output=True, text=True, check=True).stdout
        out_rust = subprocess.run([RUST, "db-ops", f"{work}/rust.sqlite"], input=text, capture_output=True, text=True, check=True).stdout
        if [json.loads(l) for l in out_swift.split()] != [json.loads(l) for l in out_rust.split()]:
            print("answers differ:", out_swift.split(), out_rust.split())
            bad += 1
        print(f"operations: {len(scanned)} sounds, {len(moved)} moved, {len(removed)} removed; {len(songs)} songs; answers {out_rust.split()[:1]}")
        # The library added again gets the time it was added: the only thing allowed to differ.
        bad += compare_dbs(f"{work}/swift.sqlite", f"{work}/rust.sqlite", "after the operations",
                           skip=lambda t, c: t == "library" and c == "addedAt")
        return bad
    finally:
        shutil.rmtree(work)


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
    elif mode == "audio":
        bad = audio_mode(arg, int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 200)
    elif mode == "similar":
        bad = similar_mode(arg, int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 2000)
    elif mode == "dupsets":
        # Similarities are 32-bit floats, which Swift prints with fewer digits.
        global TOLERANCE
        TOLERANCE = 1e-6
        bad = compare(run([SWIFT, "dupsets", arg]), run([RUST, "dupsets", arg]), "duplicate sets")
    elif mode == "db":
        bad = db_mode(arg, sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        sys.exit(__doc__)
    sys.exit(1 if bad else 0)


main()
