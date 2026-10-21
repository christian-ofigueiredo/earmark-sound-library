#!/usr/bin/env python3
"""Tempo and key for every song in a folder.

Tempo: Beat This! (CPJKU, ISMIR 2024) – finds every beat and downbeat; three
       trained versions are averaged for extra reliability.
Key:   S-KEY (Deezer, ICASSP 2025), with a classic key-profile estimate as a
       second opinion. Disagreements are flagged for a listen.

Results go to a report you can sort and filter (BPM range, compatible keys),
plus a sidecar file (music_analysis.json) and CSV. The songs are only read,
never changed. In the report you can correct/confirm values and download them
as a CSV; pass that back with --truth to measure accuracy on your music.

Examples:
    python analyze_music.py ~/Music/Library
    python analyze_music.py ~/Music/Library --truth my_checked_songs.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import pickle
import sys
import time
from pathlib import Path

import numpy as np
import soxr
from tqdm import tqdm

from soundlab import report as R
from soundlab.audio import (DEFAULT_OUTPUT_ROOT, AudioLoadError, ensure_output_outside_inputs, file_signature,
                            file_uri, find_audio_files, load_audio, pick_device, relative_label)
from soundlab.metadata import extract
from soundlab.music import (BEAT_SR, KeyEstimator, TempoEstimator, camelot, classic_key, key_label, key_relation,
                            mirex_score, parse_key)

ANALYSIS_VERSION = 3
MAX_SECONDS = 20 * 60


def load_cache(root: Path) -> tuple[Path, dict]:
    path = root / "cache" / "music.pkl"
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(path, "rb") as f:
            return path, pickle.load(f)
    except Exception:  # noqa: BLE001
        return path, {}


def save_cache(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".tmp")
    with open(tmp, "wb") as f:
        pickle.dump(data, f, protocol=pickle.HIGHEST_PROTOCOL)
    os.replace(tmp, path)


def analyse_song(path: Path, tempo: TempoEstimator, key: KeyEstimator) -> dict:
    x, sr = load_audio(path, sr=44100, max_seconds=MAX_SECONDS)
    if x.size < sr * 2 or float(np.max(np.abs(x))) < 1e-5:
        raise AudioLoadError("silent or shorter than 2 seconds")
    x22 = soxr.resample(x, sr, BEAT_SR, quality="VHQ").astype(np.float32)
    t = tempo(x22)
    xk = x22 if key.sr == BEAT_SR else soxr.resample(x, sr, key.sr, quality="VHQ").astype(np.float32)
    k = key(xk)
    c = classic_key(x22, BEAT_SR)
    return {"duration": len(x) / sr, "tempo": t, "skey": k, "classic": c, "tempo_model": tempo.describe()}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folders", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, help="report folder (default ~/SoundLab/music-<time>)")
    ap.add_argument("--truth", type=Path, help="CSV with columns file,bpm,key to measure accuracy")
    ap.add_argument("--device", default="auto")
    ap.add_argument("--fast", action="store_true", help="one tempo model instead of three")
    ap.add_argument("--cache", type=Path, default=DEFAULT_OUTPUT_ROOT)
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    roots = [p.expanduser().resolve() for p in args.folders]
    out = ensure_output_outside_inputs(args.out or DEFAULT_OUTPUT_ROOT / f"music-{R.timestamp()}", roots)
    ensure_output_outside_inputs(args.cache, roots)
    files = find_audio_files(roots)
    if not files:
        sys.exit("No audio files found.")
    print(f"{len(files)} songs.")
    t0 = time.time()

    cache_path, cache = load_cache(args.cache)
    mode = "fast" if args.fast else "ens"
    keyf = lambda p: f"music{ANALYSIS_VERSION}{mode}|{p}|{file_signature(p)}"  # noqa: E731
    todo = [p for p in files if keyf(p) not in cache]
    device = pick_device(args.device)
    tempo = key = None
    if todo:
        print(f"Loading models on {device}… (first run downloads them)")
        try:
            tempo = TempoEstimator(device, ensemble=not args.fast)
            key = KeyEstimator(device)
        except Exception as e:  # noqa: BLE001
            if device == "cpu":
                raise
            print(f"  {device} failed ({e}); using CPU instead.")
            device = "cpu"
            tempo = TempoEstimator(device, ensemble=not args.fast)
            key = KeyEstimator(device)
        print(f"  {tempo.describe()}")
        if "community copy" in tempo.describe():
            print("  Note: the official Beat This! download server was unreachable, so a community copy of the "
                  "same weights (from Hugging Face) is used, and only one of the three tempo models.")
    errors = {}
    for i, p in enumerate(tqdm(todo, unit="song", desc="Analysing")):
        try:
            try:
                cache[keyf(p)] = analyse_song(p, tempo, key)
            except (RuntimeError, NotImplementedError) as e:
                if tempo.device == "cpu" and key.device == "cpu":
                    raise
                print(f"\n{device} failed on {p.name} ({str(e)[:120]}); continuing on CPU.")
                tempo.to_cpu()
                key.to_cpu()
                cache[keyf(p)] = analyse_song(p, tempo, key)
        except Exception as e:  # noqa: BLE001
            errors[p] = str(e)[:300]
        if i % 20 == 19:
            save_cache(cache_path, cache)
    if todo:
        save_cache(cache_path, cache)

    truth = {}
    if args.truth:
        with open(args.truth, newline="", encoding="utf-8-sig") as f:
            for r in csv.DictReader(f):
                name = (r.get("file") or r.get("filename") or "").strip()
                if name:
                    truth[Path(name).name.lower()] = r

    tracks = []
    for p in files:
        res = cache.get(keyf(p))
        if res is None:
            continue
        meta = extract(p)["fields"]
        t, k, c = res["tempo"], res["skey"], res["classic"]
        kk, ck = tuple(k["key"]), tuple(c["key"])
        rel = key_relation(kk, ck)
        tag_key = parse_key(meta.get("key"))
        try:
            tag_bpm = float(str(meta.get("bpm", "")).split(";")[0]) if meta.get("bpm") else None
        except ValueError:
            tag_bpm = None
        flags = []
        # The classic method is much weaker than S-KEY, so a disagreement only
        # earns a flag when S-KEY itself isn't very sure.
        if k["confidence"] < 0.6:
            flags.append("low key confidence")
        elif rel != "same" and k["confidence"] < 0.85:
            flags.append(f"key unsure: second opinion says {key_label(*ck)} ({rel})")
        if t.get("bpm") is None:
            flags.append("no steady beat found")
        elif t["stability"] == "variable":
            flags.append("tempo changes")
        st = os.stat(p)
        tr = {
            "file": relative_label(p, roots), "path": str(p), "uri": file_uri(p), "size": st.st_size,
            "mtime": st.st_mtime, "duration": round(res["duration"], 2),
            "title": meta.get("fxname") or p.stem, "artist": meta.get("designer", ""), "album": meta.get("library", ""),
            "bpm": t.get("bpm"), "bpm_range": t.get("bpm_range"), "tempo_stability": t.get("stability"),
            "beats_per_bar": t.get("beats_per_bar"), "tempo_confidence": t.get("tempo_confidence"),
            "key": key_label(*kk), "key_pc": kk[0], "key_minor": kk[1], "camelot": camelot(*kk),
            "key_confidence": round(k["confidence"], 3),
            "key_second_opinion": key_label(*ck), "key_agreement": rel,
            "tag_bpm": tag_bpm, "tag_key": key_label(*tag_key) if tag_key else (meta.get("key") or None),
            "flags": flags, "beats": t.get("beats", []), "downbeats": t.get("downbeats", []),
        }
        ref = truth.get(p.name.lower())
        if ref:
            tr["truth_bpm"] = float(ref["bpm"]) if (ref.get("bpm") or "").strip() else None
            tr["truth_key"] = parse_key(ref.get("key"))
        tracks.append(tr)

    # ---------------- accuracy
    def tempo_ok(est, ref, octave=False):
        if est is None or not ref:
            return None
        factors = (1, 2, 0.5, 3, 1 / 3) if octave else (1,)
        return any(abs(est - ref * f) <= 0.04 * ref * f for f in factors)

    evals = {}
    for label, getter in (("your checked values", lambda tr: (tr.get("truth_bpm"), tr.get("truth_key"))),
                          ("file tags", lambda tr: (tr["tag_bpm"], parse_key(tr["tag_key"])))):
        bpm_hits = [tempo_ok(tr["bpm"], getter(tr)[0]) for tr in tracks if getter(tr)[0]]
        bpm_hits2 = [tempo_ok(tr["bpm"], getter(tr)[0], True) for tr in tracks if getter(tr)[0]]
        key_scores = [mirex_score((tr["key_pc"], tr["key_minor"]), getter(tr)[1]) for tr in tracks if getter(tr)[1]]
        cls_scores = [mirex_score(parse_key(tr["key_second_opinion"]), getter(tr)[1]) for tr in tracks if getter(tr)[1]]
        if bpm_hits or key_scores:
            evals[label] = {
                "bpm_n": len(bpm_hits), "bpm_acc": float(np.mean(bpm_hits)) if bpm_hits else None,
                "bpm_acc_octave": float(np.mean(bpm_hits2)) if bpm_hits2 else None,
                "key_n": len(key_scores), "key_exact": float(np.mean([s == 1.0 for s in key_scores])) if key_scores else None,
                "key_mirex": float(np.mean(key_scores)) if key_scores else None,
                "classic_key_mirex": float(np.mean(cls_scores)) if cls_scores else None,
            }

    # ---------------- sidecar + CSV
    for tr in tracks:
        if "truth_key" in tr:
            tr["truth_key"] = key_label(*tr["truth_key"]) if tr["truth_key"] else None
    sidecar = {
        "format": "soundlab-music-analysis", "version": 1, "created": R.timestamp(),
        "folders": [str(r) for r in roots],
        "models": {"tempo": "; ".join(sorted({cache[keyf(p)].get("tempo_model", "Beat This!") for p in files
                                              if keyf(p) in cache})) or "Beat This!",
                   "key": "S-KEY (Deezer, ICASSP 2025)",
                   "key_second_opinion": "Krumhansl-Kessler profiles on harmonic chroma"},
        "evaluation": evals, "tracks": tracks, "errors": {str(k): v for k, v in errors.items()},
    }
    (out / "music_analysis.json").write_text(json.dumps(sidecar, ensure_ascii=False, indent=1), encoding="utf-8")
    with open(out / "music_analysis.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        cols = ["file", "title", "artist", "duration", "bpm", "tempo_stability", "beats_per_bar", "tempo_confidence",
                "key", "camelot", "key_confidence", "key_second_opinion", "key_agreement", "tag_bpm", "tag_key"]
        w.writerow(cols)
        for tr in tracks:
            w.writerow([tr.get(c) for c in cols])

    html_path = out / "music_report.html"
    R.write_and_open(html_path, render_html(sidecar, time.time() - t0), open_it=not args.no_open)
    print(f"\nDone. {len(tracks)} songs analysed" + (f", {len(errors)} failed" if errors else "") + ".")
    for label, e in evals.items():
        parts = []
        if e["bpm_acc"] is not None:
            parts.append(f"BPM within 4%: {e['bpm_acc']:.0%} ({e['bpm_acc_octave']:.0%} allowing half/double) of {e['bpm_n']}")
        if e["key_mirex"] is not None:
            parts.append(f"key exact {e['key_exact']:.0%}, MIREX score {e['key_mirex']:.0%} of {e['key_n']}"
                         f" (classic method {e['classic_key_mirex']:.0%})")
        print(f"Compared with {label}: " + "; ".join(parts))
    print(f"Report: {html_path}\nSidecar: {out / 'music_analysis.json'}")


# ---------------------------------------------------------------- HTML

MUSIC_JS = r"""
const T = DATA.tracks;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const mult = {};  // per-row half/double
const ST = {};    // per-row edits: {b, k, c}
function camelotNeighbours(c){ const m = c.match(/(\d+)([AB])/); if(!m) return []; const n=+m[1], l=m[2];
  const w = k => ((k+11)%12)+1; return [c, `${w(n+1)}${l}`, `${w(n-1)}${l}`, `${n}${l==='A'?'B':'A'}`]; }
function render(){
  const q = document.getElementById('q').value.toLowerCase();
  const lo = parseFloat(document.getElementById('bmin').value) || 0, hi = parseFloat(document.getElementById('bmax').value) || 1e9;
  const kc = document.getElementById('kc').value; const ok = kc ? camelotNeighbours(kc) : null;
  const onlyFlags = document.getElementById('flagged').checked;
  const rows = T.map((t,i)=>[t,i]).filter(([t,i]) => {
    const b = t.bpm ? t.bpm * (mult[i]||1) : null;
    if (q && !(t.title+' '+t.artist+' '+t.file).toLowerCase().includes(q)) return false;
    if ((lo>0 || hi<1e9) && (b===null || b<lo || b>hi)) return false;
    if (ok && !ok.includes(t.camelot)) return false;
    if (onlyFlags && !t.flags.length) return false;
    return true; });
  document.getElementById('count').textContent = `${rows.length} of ${T.length} songs`;
  document.getElementById('rows').innerHTML = rows.map(([t,i]) => {
    const b = t.bpm ? +(t.bpm*(mult[i]||1)).toFixed(1) : null;
    const tag = (t.tag_bpm||t.tag_key) ? `<span class="muted small">${t.tag_bpm?esc(t.tag_bpm)+' BPM ':''}${esc(t.tag_key||'')}</span>` : '';
    const truth = (t.truth_bpm||t.truth_key) ? `<div class="small">✓ ${t.truth_bpm?esc(t.truth_bpm)+' BPM ':''}${esc(t.truth_key||'')}</div>` : '';
    return `<tr><td><button class="play" onclick="playFile(this, ${esc(JSON.stringify(t.uri))})">▶</button></td>
      <td><b>${esc(t.title)}</b><div class="muted small">${esc(t.artist)}${t.artist?' · ':''}<span class="mono">${esc(t.file)}</span></div></td>
      <td data-v="${t.duration}">${fmt(t.duration)}</td>
      <td data-v="${b??0}"><input class="ed" id="b${i}" value="${esc(ST[i]?.b ?? b ?? '')}" size="5" oninput="edit(${i},'b',this.value)">
        <div class="small"><a href="#" onclick="setMult(${i},0.5);return false">½×</a> <a href="#" onclick="setMult(${i},2);return false">2×</a>
        <span class="muted">${esc(t.tempo_stability||'')}${t.tempo_stability!=='steady'&&t.bpm_range?' '+t.bpm_range[0]+'–'+t.bpm_range[1]:''}${t.beats_per_bar?' · '+t.beats_per_bar+'/bar':''}</span></div></td>
      <td data-v="${t.camelot}"><input class="ed" id="k${i}" value="${esc(ST[i]?.k ?? t.key)}" size="9" oninput="edit(${i},'k',this.value)">
        <div class="small"><span class="chip">${esc(t.camelot)}</span> <span class="muted">${Math.round(t.key_confidence*100)}%</span></div></td>
      <td class="small">${t.key_agreement==='same'?'<span class="good">agrees</span>':`<span class="warn">${esc(t.key_second_opinion)} (${esc(t.key_agreement)})</span>`}</td>
      <td>${tag}${truth}</td>
      <td class="small warn">${t.flags.map(esc).join('<br>')}</td>
      <td><input type="checkbox" id="c${i}" title="I checked this one" ${ST[i]?.c?'checked':''} onchange="edit(${i},'c',this.checked)"></td></tr>`; }).join('');
}
function fmt(s){ s=Math.round(s); return Math.floor(s/60)+':'+String(s%60).padStart(2,'0'); }
function setMult(i,m){ mult[i] = (mult[i]||1)*m; ST[i] = ST[i]||{}; delete ST[i].b; ST[i].c = true; render(); }
function edit(i, field, v){ ST[i] = ST[i]||{}; ST[i][field] = v; if (field !== 'c'){ ST[i].c = true;
  const c = document.getElementById('c'+i); if (c) c.checked = true; } }
function exportChecked(){
  const lines = ['file,bpm,key'];
  T.forEach((t,i) => { if (!ST[i]?.c) return;
    const b = ST[i].b ?? (t.bpm ? +(t.bpm*(mult[i]||1)).toFixed(1) : ''), k = ST[i].k ?? t.key;
    lines.push([t.file, b, k].map(v => '"'+String(v).replace(/"/g,'""')+'"').join(',')); });
  if (lines.length === 1){ alert('Tick the songs you have checked (editing a value ticks it automatically).'); return; }
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([lines.join('\n')], {type:'text/csv'}));
  a.download = 'checked_songs.csv'; a.click();
}
['q','bmin','bmax','kc','flagged'].forEach(id => document.getElementById(id).addEventListener('input', render));
render();
"""


def render_html(sidecar: dict, seconds: float) -> str:
    tracks = sidecar["tracks"]
    n = len(tracks)
    bpms = [t["bpm"] for t in tracks if t["bpm"]]
    agree = sum(1 for t in tracks if t["key_agreement"] == "same")
    flagged = sum(1 for t in tracks if t["flags"])
    body = [R.cards([
        (f"{n}", "songs"), (f"{np.median(bpms):.0f}" if bpms else "–", "median BPM"),
        (f"{agree / n:.0%}" if n else "–", "key methods agree"), (f"{flagged}", "flagged for a listen"),
        (R.fmt_duration(seconds), "run time"),
    ])]
    for label, e in sidecar["evaluation"].items():
        parts = []
        if e["bpm_acc"] is not None:
            parts.append(f"BPM within 4%: <b>{e['bpm_acc']:.0%}</b> ({e['bpm_acc_octave']:.0%} counting half/double "
                         f"tempo) on {e['bpm_n']} songs")
        if e["key_mirex"] is not None:
            parts.append(f"key exactly right: <b>{e['key_exact']:.0%}</b>, MIREX score {e['key_mirex']:.0%} on "
                         f"{e['key_n']} songs (classic method: {e['classic_key_mirex']:.0%})")
        body.append(f"<div class='note'><b>Compared with {R.esc(label)}:</b> " + "; ".join(parts) + "</div>")
    body.append("<div class='note'>Filter by BPM or by keys that mix well (Camelot: same, ±1, relative). "
                "<b>½× / 2×</b> fixes half/double-tempo readings. Edit any BPM or key you disagree with, tick the songs "
                "you've checked, then <b>Download checked songs</b> and run "
                "<span class='mono'>analyze_music.py … --truth checked_songs.csv</span> to measure accuracy. "
                "Your music files were not changed.</div>")
    cams = sorted({t["camelot"] for t in tracks}, key=lambda c: (int(c[:-1]), c[-1]))
    body.append("<div style='display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:10px 0'>"
                "<input id='q' type='search' placeholder='Search title / artist / file'>"
                "<label>BPM <input id='bmin' type='number' style='width:70px' placeholder='min'> – "
                "<input id='bmax' type='number' style='width:70px' placeholder='max'></label>"
                "<label>Mixes with <select id='kc'><option value=''>any key</option>" +
                "".join(f"<option>{c}</option>" for c in cams) + "</select></label>"
                "<label><input id='flagged' type='checkbox'> only flagged</label>"
                "<span id='count' class='muted'></span>"
                "<button onclick='exportChecked()' style='margin-left:auto'>Download checked songs (CSV)</button></div>")
    body.append("<div class='scroll'><table><thead><tr><th></th><th class='sortable' onclick='sortTable(this)'>Song</th>"
                "<th class='sortable' onclick='sortTable(this)'>Length</th><th class='sortable' onclick='sortTable(this)'>BPM</th>"
                "<th class='sortable' onclick='sortTable(this)'>Key</th><th>Second opinion</th><th>Tags / checked</th>"
                "<th>Flags</th><th title='checked'>✓</th></tr></thead><tbody id='rows'></tbody></table></div>")
    if sidecar["errors"]:
        body.append("<h2>Songs that couldn't be analysed</h2><table><tbody>" + "".join(
            f"<tr><td class='mono'>{R.esc(Path(p).name)}</td><td class='muted'>{R.esc(e)}</td></tr>"
            for p, e in sidecar["errors"].items()) + "</tbody></table>")
    slim = [{k: v for k, v in t.items() if k not in ("beats", "downbeats", "path")} for t in tracks]
    data = json.dumps({"tracks": slim}, ensure_ascii=False).replace("</", "<\\/")
    html = R.page("Music tempo & key", f"{n} songs · {sidecar['models']['tempo']}", "\n".join(body),
                  extra_js=f"const DATA = {data};\n{MUSIC_JS}")
    return html.replace("</style>", "input.ed{width:auto}.small{font-size:12px}a{color:var(--accent)}</style>", 1)


if __name__ == "__main__":
    main()
