"""Compares the Swift code and the Rust engine on the same real data. Only reads.

    python3 engine/parity/compare.py metadata <folder> [--limit N]
    python3 engine/parity/compare.py scan <folder>
    python3 engine/parity/compare.py twins <library.sqlite>
    python3 engine/parity/compare.py keys [<music_analysis.json>]
    python3 engine/parity/compare.py phase0 <music_analysis.json>
    python3 engine/parity/compare.py audio <library.sqlite> [--count N]
    python3 engine/parity/compare.py similar <library.sqlite> [--count N]
    python3 engine/parity/compare.py dupsets <library.sqlite>
    python3 engine/parity/compare.py map <library.sqlite> [category]
    python3 engine/parity/compare.py groups <library.sqlite>
    python3 engine/parity/compare.py categories <library.sqlite>
    python3 engine/parity/compare.py music <library.sqlite> <models folder> [--count N]
    python3 engine/parity/compare.py timeline <library.sqlite>
    python3 engine/parity/compare.py anafiles <library.sqlite>
    python3 engine/parity/compare.py db <library.sqlite> <sounds folder> <music folder> <music_analysis.json>
    python3 engine/parity/compare.py names <library.sqlite> [--count N]
    python3 engine/parity/compare.py mcp <library.sqlite> [--count N]

Runs the same mode of `earmark-parity` (Swift, app/.build/release) and `earmark-engine`
(Rust, engine/target/release) and prints every difference. Numbers must match within 1e-9
(relative), the rest exactly; a missing value and null are the same. Text compares as Swift's
String does, by canonical equivalence (Foundation's file URLs decompose accents: "é" as "e"
and a combining accent).
"""
import datetime, json, math, os, random, shutil, sqlite3, struct, subprocess, sys, tempfile, time, unicodedata

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
        # 32-bit similarities: Swift prints them with fewer digits than Rust.
        if where.endswith("/similarity") and f32(a) == f32(b):
            return
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


def f32(v):
    return struct.unpack("f", struct.pack("f", v))[0]


def backup(db, work):
    """A copy to work on (Swift's map and groups modes open their database to write)."""
    copy = os.path.join(work, "copy.sqlite")
    subprocess.run(["sqlite3", f"file:{db}?mode=ro", f".backup {copy}"], check=True)
    return copy


def map_mode(db, category):
    """The sound map, to the bit (the app's maps: matrices page-aligned, as its PageBuffer)."""
    work = tempfile.mkdtemp(prefix="earmark-map-parity-")
    try:
        copy, extra = backup(db, work), [category] if category else []
        subprocess.run([SWIFT, "map", copy, f"{work}/swift.json"] + extra, check=True, capture_output=True)
        subprocess.run([RUST, "map", copy, f"{work}/rust.json"] + extra, check=True, capture_output=True)
        a, b = json.load(open(f"{work}/swift.json")), json.load(open(f"{work}/rust.json"))
        A, B = [f32(v) for v in a["x"] + a["y"]], [f32(v) for v in b["x"] + b["y"]]
        same = sum(p == q for p, q in zip(A, B))
        print(f"map{' of ' + category if category else ''}: {len(a['ids'])} sounds, {same} of {len(A)} coordinates identical")
        return int(a["ids"] != b["ids"] or same != len(A))
    finally:
        shutil.rmtree(work)


def groups_mode(db):
    work = tempfile.mkdtemp(prefix="earmark-groups-parity-")
    try:
        copy = backup(db, work)
        subprocess.run([SWIFT, "groups", copy, f"{work}/swift.json"], check=True, capture_output=True)
        subprocess.run([RUST, "groups", copy, f"{work}/swift.json", f"{work}/rust.json"], check=True, capture_output=True)
        a, b = json.load(open(f"{work}/swift.json")), json.load(open(f"{work}/rust.json"))
        bad = 0
        for x, y in zip(a, b):
            if x["catID"] != y["catID"] or x["labels"] != y["labels"] or x["names"] != y["names"]:
                bad += 1
                if bad <= 5:
                    print(x["catID"], "differs")
        print(f"groups: {len(a)} subcategories, {sum(len(x['ids']) for x in a)} sounds, "
              f"{sum(len(x['names']) for x in a)} groups; {bad} subcategories differ")
        return bad + int(len(a) != len(b))
    finally:
        shutil.rmtree(work)


def music_mode(db, models, count):
    """The music maths on songs Swift decoded and ran the models on, a few at a time."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute("SELECT path FROM song ORDER BY path").fetchall()
    con.close()
    step = max(1, len(rows) // count)
    paths = [r[0] for r in rows[::step] if os.path.exists(r[0])][:count]
    bad, n, half_exact, spect_exact = 0, 0, 0, 0
    for b in range(0, len(paths), 5):
        work = tempfile.mkdtemp(prefix="earmark-music-parity-")
        try:
            swift = run([SWIFT, "musicsteps", models, work], "\n".join(paths[b:b + 5]) + "\n")
            rust = run([RUST, "musicsteps", work], "\n".join(json.dumps(r) for r in swift) + "\n")
            for sw, ru in zip(swift, rust):
                n += 1
                half, spect = ru.pop("halfRate"), ru.pop("spectrogram")
                half_exact += isinstance(half, dict) and half["differ"] == 0
                spect_exact += isinstance(spect, dict) and spect["differ"] == 0
                out = []
                diff(sw, ru, "", out)
                if out or not (isinstance(half, dict) and half["differ"] == 0) or not (isinstance(spect, dict) and spect["differ"] == 0):
                    bad += 1
                    print(sw["path"], "half rate", half, "spectrogram", spect)
                    for line in out[:5]:
                        print("   ", line)
        finally:
            shutil.rmtree(work)
    print(f"music: {n} songs; half-rate audio identical in {half_exact}, spectrograms identical in {spect_exact}; "
          f"{bad} with differences")
    return bad


def timeline_mode(db):
    """The same clips, every frame rate: the file's text must match to the byte."""
    import random
    random.seed(29)
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute("SELECT path, fileName, duration, sampleRate, channels FROM sound WHERE duration > 0 ORDER BY path").fetchall()
    con.close()
    rates = ["23.976", "24", "25", "29.97", "29.97 DF", "30", "50", "59.94", "59.94 DF", "60"]
    odd = ["/tmp/Ação & Co/x (1) [a];b?c#d%e+f=g~h!i'j,k.wav", '/Vol/한글 ﬁ/é́ "q" <r>.wav', "/Vol/name with\ttab.wav"]
    cases = []
    for n in range(600):
        clips = []
        for _ in range(random.randint(1, 8)):
            path, name, length, rate, channels = random.choice(rows)
            start = random.uniform(0, length) if random.random() < 0.4 else None
            end = (start or 0) + random.uniform(0, length) if random.random() < 0.4 else None
            at = random.uniform(0, 600) if random.random() < 0.4 else None
            if random.random() < 0.1:
                path = random.choice(odd)
                name = os.path.basename(path)
            reference = random.choice([0, 0, random.randint(0, int(86400 * rate))])
            text = lambda v: None if v is None else repr(v)
            clips.append({"path": path, "name": name, "length": repr(length), "sampleRate": int(rate), "channels": channels or 2,
                          "timeReference": reference, "start": text(start), "end": text(end), "at": text(at)})
        rate = rates[n % len(rates)]
        stamp = random.choice(["01:00:00:00", "00:00:00:00", "10:59:59:10", "01:00:00;00", "00:01:00;02", "bad", "1:00:00"])
        cases.append({"clips": clips if n % 97 else [], "rate": rate, "start": stamp, "name": random.choice(["Test", "A & B", "Som é <bom>"])})
    text = json.dumps(cases)
    swift, rust = run([SWIFT, "timeline"], text), run([RUST, "timeline"], text)
    bad = sum(s != r for s, r in zip(swift, rust)) + abs(len(swift) - len(rust))
    for s, r in zip(swift, rust):
        if s != r and bad <= 3:
            print("swift:", (s.get("xml") or s.get("failure"))[:1500], "\nrust: ", (r.get("xml") or r.get("failure"))[:1500])
    made = sum("xml" in s for s in swift)
    print(f"timeline: {len(swift)} cases, {made} files, {len(swift) - made} failures; {bad} differ (text compared to the byte)")
    return bad


def anafiles_mode(db):
    """Each language exports; each imports each's files into a copy with no analysis."""
    work = tempfile.mkdtemp(prefix="earmark-anafile-parity-")
    try:
        source = backup(db, work)
        # The owner's choices, on the copy, so those paths run even on a library that has none.
        con = sqlite3.connect(source)
        when = "2026-10-30 12:00:00.000"
        for lib, folder in con.execute("SELECT libraryId, folder FROM sound WHERE folder != '' GROUP BY libraryId, folder ORDER BY folder LIMIT 5").fetchall():
            con.execute("INSERT OR REPLACE INTO folderRule VALUES (?, ?, 'AMBForst', ?)", (lib, folder, when))
        for sid, fp in con.execute("SELECT id, fingerprint FROM sound ORDER BY path LIMIT 40").fetchall():
            con.execute("INSERT OR REPLACE INTO soundCategory VALUES (?, ?, 'DOORWood', 1, NULL, NULL, 1, ?)", (sid, fp, when))
        for i, (path,) in enumerate(con.execute("SELECT path FROM song ORDER BY path LIMIT 40").fetchall()):
            con.execute("INSERT OR REPLACE INTO songCorrection VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        (path, 120.5 + i, 120.0 + i, 121.0 + i, i % 12, i % 2, 4, when))
        con.commit()
        con.close()
        files = {}
        for name, tool in (("swift", SWIFT), ("rust", RUST)):
            os.makedirs(f"{work}/{name}")
            subprocess.run([tool, "anafile-export", source, f"{work}/{name}"], check=True, capture_output=True)
            files[name] = sorted(os.listdir(f"{work}/{name}"))
        bad = 0
        if files["swift"] != files["rust"]:
            print("different files:", files)
            bad += 1
        for f in files["swift"]:
            a, b = (json.load(open(f"{work}/{n}/{f}")) for n in ("swift", "rust"))
            out = []
            if a != b:
                diff(a, b, "", out)
                print(f, "differs:", out[:5])
                bad += 1
            print(f"{f}: {len(a.get('sounds') or a.get('songs') or [])} entries, parsed files {'identical' if not out else 'differ'}")
            del a, b
        # A copy with no analysis, as Swift's clearAnalysisForTesting.
        cleared = f"{work}/cleared.sqlite"
        shutil.copy(source, cleared)
        con = sqlite3.connect(cleared)
        for table in ("soundFacts", "soundEmbedding", "folderRule", "songCorrection", "soundCategory"):
            con.execute(f"DELETE FROM {table}")
        con.execute("UPDATE song SET bpm = NULL, bpmLow = NULL, bpmHigh = NULL, tempoStability = NULL, beatsPerBar = NULL, "
                    "keyPitchClass = NULL, keyMinor = NULL, keyConfidence = NULL, analysisSource = NULL")
        con.commit()
        con.close()
        results, reports = {}, {}
        for origin in ("swift", "rust"):
            for name, tool in (("swift", SWIFT), ("rust", RUST)):
                target = f"{work}/{origin}-to-{name}.sqlite"
                shutil.copy(cleared, target)
                paths = [f"{work}/{origin}/{f}" for f in files[origin]]
                reports[(origin, name)] = run([tool, "anafile-import", target] + paths)
                results[(origin, name)] = target
        reference = results[("swift", "swift")]
        print("swift's file into swift:", reports[("swift", "swift")])
        now = {"analyzedAt", "createdAt", "correctedAt"}
        for key, target in results.items():
            if reports[key] != reports[("swift", "swift")]:
                print(key, "report differs:", reports[key])
                bad += 1
            if key != ("swift", "swift"):
                bad += compare_dbs(reference, target, f"{key[0]}'s files into {key[1]}", skip=lambda t, c: c in now)
        return bad
    finally:
        shutil.rmtree(work)


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


class McpServer:
    """A server over stdin/stdout, as an MCP client starts it."""

    def __init__(self, binary, database, home):
        env = dict(os.environ, EARMARK_DATABASE=database, HOME=home, CFFIXED_USER_HOME=home)
        self.process = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=env, text=True, encoding="utf-8")
        self.next = 0
        self.seconds = 0.0
        self.first = None

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params=None):
        self.next += 1
        self.send({"jsonrpc": "2.0", "id": self.next, "method": method, **({"params": params} if params is not None else {})})
        started = time.monotonic()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError(f"the server went away on {method}")
            answer = json.loads(line)
            if answer.get("id") == self.next:
                self.seconds += time.monotonic() - started
                if method == "tools/call" and self.first is None:
                    self.first = time.monotonic() - started
                return answer

    def initialize(self, version):
        answer = self.request("initialize", {"protocolVersion": version, "capabilities": {},
                                             "clientInfo": {"name": "compare", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return answer["result"]

    def call(self, name, arguments):
        answer = self.request("tools/call", {"name": name, "arguments": arguments})
        if "error" in answer:
            return {"rpcError": answer["error"]}
        return answer["result"]

    def stop(self):
        self.process.stdin.close()
        self.process.wait(timeout=20)


def mcp_calls(swift, count):
    """The calls to make, chosen from what the library holds. None changes anything."""
    random.seed(7)
    overview = json.loads(swift.call("library_overview", {})["content"][0]["text"])
    subs = [x for c in overview["categories"] for x in c["subcategories"]]
    calls = [("library_overview", {})]
    # The whole list, to check its order, and the first page of each filter.
    total = json.loads(swift.call("search_sounds", {"limit": 1})["content"][0]["text"])["total"]
    calls += [("search_sounds", {"limit": 200, "offset": o}) for o in range(0, total, 200)]
    for c in overview["categories"]:
        calls.append(("search_sounds", {"category": c["category"], "limit": 200}))
    for x in subs:
        calls.append(("search_sounds", {"category": x["catID"], "limit": 200}))
        calls.append(("list_groups", {"subcategory": x["catID"]}))
    for lib in overview["libraries"]:
        calls.append(("search_sounds", {"library_id": lib["id"], "limit": 50}))
    for source in ["file", "folder", "guess", "owner", "none", "nonsense"]:
        calls.append(("search_sounds", {"source": source, "limit": 200}))
    for query in ["door", "door wood slam", "DOOR", "footsteps gravel", "wind", "água", "água", "café", "whoosh 01",
                  "#", "1", "  ", "zzzzqqq", "metal hit", "explosion", "é", "ñ", "01 02"]:
        calls.append(("search_sounds", {"query": query, "limit": 200}))
    calls += [("search_sounds", {"min_length": 10, "max_length": "20", "limit": 200}),
              ("search_sounds", {"max_length": 0.2, "limit": "200"}),
              ("search_sounds", {"query": "door", "offset": 5, "limit": 3}),
              ("search_sounds", {"query": "door", "offset": -5, "limit": 0}),
              ("search_sounds", {"query": "door", "limit": 100000}),
              ("search_sounds", {"query": "door", "offset": 100000})]
    # Every group, and sounds picked from all over the library.
    ids, group_ids = [], set()
    for o in range(0, total, 200):
        rows = json.loads(swift.call("search_sounds", {"limit": 200, "offset": o})["content"][0]["text"])["sounds"]
        ids += [r["id"] for r in rows]
        group_ids |= {r["groupId"] for r in rows if "groupId" in r}
    calls += [("search_sounds", {"group_id": g, "limit": 200}) for g in sorted(group_ids)]
    sample = random.sample(ids, min(count, len(ids)))
    calls += [("get_sound", {"sound_id": i}) for i in sample]
    calls += [("find_similar", {"sound_id": i, "limit": 30}) for i in sample[: count // 5]]
    calls += [("find_similar", {"sound_id": sample[0]}), ("find_similar", {"sound_id": str(sample[0]), "limit": "1000"})]
    # What agents get wrong.
    calls += [("get_sound", {}), ("get_sound", {"sound_id": 99999999}), ("get_sound", {"sound_id": "x"}),
              ("get_sound", {"sound_id": 1.5}), ("find_similar", {"sound_id": 99999999}),
              ("list_groups", {}), ("list_groups", {"subcategory": "nonsense"}), ("list_groups", {"subcategory": "footsteps / human"}),
              ("show_in_earmark", {}), ("show_in_earmark", {"sound_id": 99999999}), ("no_such_tool", {}),
              ("add_to_resolve", {}), ("add_to_resolve", {"items": []}), ("add_to_resolve", {"items": [{"sound_id": 99999999}]}),
              ("add_to_resolve", {"items": [{}]}), ("add_to_resolve", {"items": ["x"]}),
              ("save_timeline_file", {}), ("save_timeline_file", {"items": [{"sound_id": 99999999}]})]
    # Timeline files, in the servers' stand-in home folders.
    a, b, c = sample[:3]
    # Resolve, if it's open: its status and previews, which place nothing. (Offline sounds are refused.)
    online = [i for i in sample if os.path.exists(json.loads(swift.call("get_sound", {"sound_id": i})["content"][0]["text"])["sound"]["path"])][:3]
    if len(online) == 3:
        calls += [("resolve_status", {}),
                  ("add_to_resolve", {"preview": True, "items": [{"sound_id": online[0]}, {"sound_id": online[1], "start": 0.1, "end": 0.5, "at": 3.5, "track": "free"},
                                                                 {"sound_id": online[2], "at": "01:00:10:00", "track": 1}]}),
                  ("add_to_resolve", {"preview": "yes", "items": [{"sound_id": online[0], "track": 99}, {"sound_id": online[0], "start": 5000, "end": 5000.01}]})]
    calls += [("save_timeline_file", {"items": [{"sound_id": a}, {"sound_id": b, "start": 0.1, "end": 0.6, "at": 30}, {"sound_id": c, "at": 30}],
                                      "frame_rate": rate, "name": f"Test: {n}", "start_timecode": tc})
              for n, (rate, tc) in enumerate([("25", "01:00:00:00"), ("29.97 DF", "01:00:00;00"), ("23.976", "00:00:00:00"), (29.97, "01:00:00:00")])]
    calls += [("save_timeline_file", {"items": [{"sound_id": a}], "name": "Again"}), ("save_timeline_file", {"items": [{"sound_id": a}], "name": "Again"}),
              ("save_timeline_file", {"items": [{"sound_id": a}], "frame_rate": "12"}),
              ("save_timeline_file", {"items": [{"sound_id": a}], "start_timecode": "nonsense"}),
              ("save_timeline_file", {"items": [{"sound_id": a}], "name": "  /  "})]
    return calls, sample


def mcp_mode(database, count):
    work = tempfile.mkdtemp(prefix="earmark-mcp-compare-")
    homes = {"swift": f"{work}/swift", "rust": f"{work}/rust"}
    for h in homes.values():
        os.makedirs(h)
    swift = McpServer(os.path.join(ROOT, "app/.build/release/earmark-mcp"), database, homes["swift"])
    rust = McpServer(os.path.join(ROOT, "engine/target/release/earmark-mcp"), database, homes["rust"])
    bad = 0
    try:
        for version in ["2025-06-18"]:
            info_s, info_r = swift.initialize(version), rust.initialize(version)
            for key in ["protocolVersion", "instructions", "serverInfo"]:
                if info_s.get(key) != info_r.get(key):
                    bad += 1
                    print(f"initialize {key}:\n  swift {info_s.get(key)}\n  rust  {info_r.get(key)}")
        print("capabilities:", info_s["capabilities"], "/", info_r["capabilities"])
        tools_s, tools_r = swift.request("tools/list")["result"]["tools"], rust.request("tools/list")["result"]["tools"]
        if [t["name"] for t in tools_s] != [t["name"] for t in tools_r]:
            bad += 1
            print("tool lists differ")
        for a, b in zip(tools_s, tools_r):
            for key in ["title", "description", "inputSchema", "annotations"]:
                if a.get(key) != b.get(key):
                    bad += 1
                    print(f"{a['name']} {key}:\n  swift {a.get(key)}\n  rust  {b.get(key)}")
        print(f"tools: {len(tools_r)}")

        calls, sample = mcp_calls(swift, count)
        swift.seconds = 0.0
        kinds, same_text = {}, 0
        for name, arguments in calls:
            a, b = swift.call(name, arguments), rust.call(name, arguments)
            kinds[name] = kinds.get(name, 0) + 1
            if name == "library_overview":
                # Swift's order among subcategories with as many sounds comes from its dictionary.
                for x in (a, b):
                    text = json.loads(x["content"][0]["text"])
                    for c in text["categories"]:
                        c["subcategories"].sort(key=lambda s: (-s["sounds"], s["catID"]))
                    x["content"][0]["text"] = json.dumps(text, sort_keys=True)
            text_a = a.get("content", [{}])[0].get("text", "").replace(homes["swift"], "HOME")
            text_b = b.get("content", [{}])[0].get("text", "").replace(homes["rust"], "HOME")
            same_text += text_a == text_b
            if text_a != text_b and same_text + 8 > kinds_total(kinds):
                print(f"not the same bytes: {name} {arguments}: {first_difference(text_a, text_b)}")
            problem = None
            if bool(a.get("isError")) != bool(b.get("isError")):
                problem = f"isError {a.get('isError')} / {b.get('isError')}"
            elif a.get("isError"):
                problem = None if text_a == text_b else "error text"
            else:
                parsed_a, parsed_b = json.loads(text_a), json.loads(text_b)
                if parsed_a != parsed_b:
                    problem = "answer"
                elif name != "library_overview" and json.loads(text_b) != json.loads(
                        json.dumps(b.get("structuredContent")).replace(homes["rust"], "HOME")):
                    problem = "structured content isn't the text"
            if problem:
                bad += 1
                if bad < 12:
                    print(f"{name} {arguments}: {problem}\n  swift {first_difference(text_a, text_b)}")
        print("calls:", kinds, f"{same_text} of {len(calls)} identical to the byte")

        # The files they saved.
        files = {k: sorted(os.path.relpath(os.path.join(d, f), h) for d, _, fs in os.walk(h) for f in fs) for k, h in homes.items()}
        print("saved:", files["rust"])
        if files["swift"] != files["rust"]:
            bad += 1
            print("saved files differ:", files)
        for f in files["rust"]:
            if f in files["swift"]:
                text_a = open(os.path.join(homes["swift"], f), encoding="utf-8").read()
                text_b = open(os.path.join(homes["rust"], f), encoding="utf-8").read()
                if text_a != text_b:
                    bad += 1
                    print(f"{f}: {first_difference(text_a, text_b)}")
        print(f"differences: {bad}")
        print(f"first answer: Swift {swift.first:.2f} s, Rust {rust.first:.2f} s; "
              f"all calls: Swift {swift.seconds:.1f} s, Rust {rust.seconds:.1f} s")
        return bad
    finally:
        swift.stop()
        rust.stop()
        shutil.rmtree(work)


def kinds_total(kinds):
    return sum(kinds.values())


def first_difference(a, b):
    n = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    return f"at {n}:\n    {a[max(0, n - 60):n + 120]!r}\n    {b[max(0, n - 60):n + 120]!r}"


def names_mode(database, count):
    """Names sorted and capitalised, from the library, the UCS list and made up."""
    db = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    real = [r[0] for r in db.execute("SELECT DISTINCT fileName FROM sound")]
    real += [r[0] for r in db.execute("SELECT DISTINCT fxName FROM sound WHERE fxName IS NOT NULL")]
    labels = [r[0] for r in db.execute("SELECT DISTINCT category || ' / ' || subcategory FROM sound WHERE category IS NOT NULL")]
    with open(os.path.join(ROOT, "app/Sources/EarmarkCore/Resources/ucs_v8.2.1.csv"), encoding="utf-8") as f:
        labels += [" / ".join(line.split(",")[:2]) for line in f]
    random.seed(11)
    alphabet = list("aabbeeooAABBEOzZ   --__..,'()&#+019") + ["é", "É", "è", "ê", "ñ", "ü", "ç", "00", "10", "2", "007"]
    made = ["".join(random.choice(alphabet) for _ in range(random.randint(1, 9))) for _ in range(count)]
    bad = 0
    for label, names in [("library names", real), ("categories", labels), ("made-up names", made)]:
        names = sorted({n for n in names if n and "\n" not in n and "\r" not in n})
        text = "\n".join(names) + "\n"
        a, b = run([SWIFT, "names"], text)[0], run([RUST, "names"], text)[0]
        wrong_caps = sum(x != y for x, y in zip(a["capitalized"], b["capitalized"]))
        wrong_order = sum(canonical(x) != canonical(y) for x, y in zip(a["sorted"], b["sorted"]))
        print(f"{label}: {len(names)}, {wrong_order} out of place, {wrong_caps} capitalised differently")
        for x, y in [p for p in zip(a["capitalized"], b["capitalized"]) if p[0] != p[1]][:8]:
            print(f"  capitalised {x!r} / {y!r}")
        for x, y in [p for p in zip(a["sorted"], b["sorted"]) if canonical(p[0]) != canonical(p[1])][:8]:
            print(f"  at this place {x!r} / {y!r}")
        bad += wrong_caps + wrong_order
    return bad


def canonical(s):
    return unicodedata.normalize("NFC", s)


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
    elif mode == "map":
        bad = map_mode(arg, sys.argv[3] if len(sys.argv) > 3 else None)
    elif mode == "groups":
        bad = groups_mode(arg)
    elif mode == "categories":
        bad = compare(run([SWIFT, "categories", arg]), run([RUST, "categories", arg]), "categories")
    elif mode == "music":
        bad = music_mode(arg, sys.argv[3], int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 30)
    elif mode == "timeline":
        bad = timeline_mode(arg)
    elif mode == "anafiles":
        bad = anafiles_mode(arg)
    elif mode == "db":
        bad = db_mode(arg, sys.argv[3], sys.argv[4], sys.argv[5])
    elif mode == "names":
        bad = names_mode(arg, int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 20000)
    elif mode == "mcp":
        bad = mcp_mode(arg, int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 3000)
    else:
        sys.exit(__doc__)
    sys.exit(1 if bad else 0)


main()
