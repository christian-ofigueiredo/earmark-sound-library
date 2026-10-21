#!/usr/bin/env python3
"""Group sound effects by category, then by how similar they sound.

Layer 1  vendor metadata: UCS category from iXML/bext/filename (BOOM etc.).
Layer 2  AI fills the gaps: files without a category get one from the audio
         (zero-shot against all 753 UCS subcategories), with a confidence.
Layer 3  similarity groups inside each category (e.g. all whooshes), using the
         AI embedding (texture) plus "shape" features (length, envelope,
         brightness movement). Each group gets a name.

Output: an interactive HTML report (sound map, groups, "find similar") plus
groups.csv / groups.json. Your sound folders are only read, never changed.

Examples:
    python group_sounds.py "/Volumes/SFX" --category WHOOSH
    python group_sounds.py "/Volumes/SFX/BOOM" --limit 2000
    python group_sounds.py "/Volumes/SFX" --model pe-av-large+clap-general   (both models combined)
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from tqdm import tqdm

from soundlab import grouping as G
from soundlab import report as R
from soundlab import ucs
from soundlab.analysis import Analyzer, embedding_matrix, parse_models, similarity_space
from soundlab.audio import DEFAULT_OUTPUT_ROOT, ensure_output_outside_inputs, file_uri, find_audio_files, relative_label
from soundlab.embeddings import DEFAULT_MODEL
from soundlab.features import describe_shape
from soundlab.metadata import extract
from soundlab.zeroshot import UCS_TEXT_TAG, softmax, ucs_prompts

# Share of the similarity that comes from shape features, by grouping scope.
# Inside one subcategory (all whooshes) shape is what tells sounds apart;
# across very different sounds it mostly adds noise.
DEFAULT_SHAPE_WEIGHT = {"subcategory": 0.3, "category": 0.15, "all": 0.1}


def select_files(files, metas, category: str | None, match: str | None, limit: int | None):
    if category:
        wanted = {w.strip().upper() for w in category.split(",") if w.strip()}

        def cat_ok(m):
            u = m["ucs"]
            if not u:
                return False
            return bool({u["catid"].upper(), u["category"].upper(), u["subcategory"].upper(),
                         f'{u["category"]}/{u["subcategory"]}'.upper()} & wanted)

        files = [f for f in files if cat_ok(metas[f])]
        print(f"{len(files)} files in categories {', '.join(sorted(wanted))}.")
    if match:
        q = match.lower()
        files = [f for f in files if q in " ".join([f.name, *metas[f]["fields"].values()]).lower()]
        print(f"{len(files)} files match '{match}'.")
    if limit and len(files) > limit:
        files = sorted(random.Random(42).sample(files, limit))
        print(f"Using a random sample of {len(files)} files.")
    return files


# ---------------------------------------------------------------- main

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folders", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, help="report folder (default ~/SoundLab/groups-<time>)")
    ap.add_argument("--model", default=DEFAULT_MODEL,
                    help=f"embedding model (default {DEFAULT_MODEL}); combine models with '+', "
                         "e.g. pe-av-large+clap-general")
    ap.add_argument("--device", default="auto", help="auto | mps | cpu | cuda")
    ap.add_argument("--half", action="store_true", help="half precision (less memory, tiny quality cost)")
    ap.add_argument("--category", help="only these UCS categories/subcategories/CatIDs, comma-separated "
                                       "(e.g. WHOOSH or SWOOSHES or WHSH,DSGNWhsh)")
    ap.add_argument("--match", help="only files whose name/description/keywords contain this text")
    ap.add_argument("--limit", type=int, help="analyse a random sample of this many files")
    ap.add_argument("--group-within", choices=["subcategory", "category", "all"], default="subcategory",
                    help="make similarity groups inside each UCS subcategory (default), category, or across all")
    ap.add_argument("--min-group-size", type=int, default=5)
    ap.add_argument("--fine", action="store_true", help="more, smaller groups")
    ap.add_argument("--shape-weight", type=float, default=None,
                    help="0 = only AI texture, 1 = only shape (default 0.3 inside a subcategory, "
                         "0.15 inside a category, 0.1 across all)")
    ap.add_argument("--attach-leftovers", action="store_true",
                    help="put sounds that fit no group into the closest group when reasonably similar")
    ap.add_argument("--cache", type=Path, default=DEFAULT_OUTPUT_ROOT, help="cache folder root (default ~/SoundLab)")
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    models = parse_models(args.model)
    shape_w = DEFAULT_SHAPE_WEIGHT[args.group_within] if args.shape_weight is None else args.shape_weight
    roots = [p.expanduser().resolve() for p in args.folders]
    out = ensure_output_outside_inputs(args.out or DEFAULT_OUTPUT_ROOT / f"groups-{R.timestamp()}", roots)
    ensure_output_outside_inputs(args.cache, roots)
    t0 = time.time()

    files = find_audio_files(roots)
    if not files:
        sys.exit("No audio files found.")
    print(f"{len(files)} audio files. Reading metadata…")
    with ThreadPoolExecutor(max_workers=8) as pool:
        metas = dict(zip(files, pool.map(extract, files)))
    files = select_files(files, metas, args.category, args.match, args.limit)
    if len(files) < 2:
        sys.exit("Need at least 2 files to group.")

    analyzer = Analyzer(models, args.cache, args.device, args.half)
    results, errors = analyzer.analyze(files)
    files = [f for f in files if f in results]
    if len(files) < 2:
        sys.exit("Too few files could be analysed.")
    E = embedding_matrix(results, files, models)
    feats = [results[f]["feats"] for f in files]

    # ---------------- layer 2: AI categories
    entries, prompts = ucs_prompts()
    T = analyzer.text(UCS_TEXT_TAG, prompts)
    probs = softmax(E @ T.T)
    top3 = np.argsort(-probs, axis=1)[:, :3]

    info = []
    for i, f in enumerate(files):
        vendor = metas[f]["ucs"]
        ai = [(entries[j], float(probs[i, j])) for j in top3[i]]
        e, src = (ucs.lookup_catid(vendor["catid"]), "vendor") if vendor else (ai[0][0], "ai")
        if args.group_within == "subcategory":
            bucket, label = e.catid, f"{e.category} / {e.subcategory}"
        elif args.group_within == "category":
            bucket = label = e.category
        else:
            bucket, label = "ALL", "All sounds"
        info.append({"entry": e, "src": src, "ai": ai, "bucket": bucket, "bucket_label": label})
    by_bucket = defaultdict(list)
    for i, inf in enumerate(info):
        by_bucket[inf["bucket"]].append(i)

    # ---------------- layer 3: similarity groups
    D = analyzer.text("descriptors-v1", [[w, f"a {w} sound", f"{w} sound effect"] for w in G.DESCRIPTORS])
    library_scores = (E @ D.T).mean(axis=0)
    catid_words = {c.lower() for c in ucs.load_ucs()}
    groups = []
    labels_global = np.full(len(files), -1)
    coords = np.zeros((len(files), 2))
    print(f"Grouping {len(files)} sounds in {len(by_bucket)} categories…")
    for bucket, idx in tqdm(sorted(by_bucket.items(), key=lambda kv: -len(kv[1])), desc="Grouping", unit="cat"):
        idx = np.array(idx)
        Xb = similarity_space(E[idx], [feats[i] for i in idx], shape_w) if len(idx) > 2 else E[idx]
        lab = G.cluster(Xb, args.min_group_size, args.fine)
        if args.attach_leftovers:
            lab = G.attach_leftovers(Xb, lab, 0.5)
        coords[idx] = G.layout_2d(Xb) if len(idx) >= 3 else np.c_[np.linspace(0.2, 0.8, len(idx)), np.full(len(idx), 0.5)]
        local_ids = sorted(set(lab))
        centres = {g: E[idx[lab == g]].mean(axis=0) for g in local_ids if g >= 0}
        ai_words = G.descriptor_names(centres, D, library_scores)
        texts = {g: [" ".join([files[i].stem.replace("_", " "), metas[files[i]]["fields"].get("fxname", ""),
                               metas[files[i]]["fields"].get("description", ""),
                               metas[files[i]]["fields"].get("keywords", "")]) for i in idx[lab == g]]
                 for g in local_ids if g >= 0}
        kw_words = G.keyword_names(texts, exclude=catid_words)
        ref = {k: (float(np.percentile([feats[i][k] for i in idx], 33)), float(np.percentile([feats[i][k] for i in idx], 67)))
               for k in ("duration_s", "centroid_hz")}
        for g in local_ids:
            members = idx[lab == g]
            gid = len(groups)
            labels_global[members] = gid
            if g < 0:
                name, aw, dw, kw = "Didn't fit a group", [], [], []
            else:
                mean_f = {k: float(np.mean([feats[i][k] for i in members])) for k in feats[members[0]]}
                dw = describe_shape(mean_f, ref)
                aw = ai_words.get(g, [])
                kw = kw_words.get(g, [])
                words = []
                for word in dw[:2] + aw:
                    if word not in words and len(words) < 3:
                        words.append(word)
                name = " · ".join(word.capitalize() for word in words) or f"Group {g + 1}"
            groups.append({"id": gid, "bucket": bucket, "name": name, "ai_words": aw, "shape_words": dw,
                           "keywords": kw, "members": [int(i) for i in members], "leftover": bool(g < 0)})

    # "find similar" across everything analysed
    nn_idx, nn_sim = G.nearest_neighbours(similarity_space(E, feats, 0.1) if len(files) > 2 else E, k=8)

    # ---------------- outputs
    rows = []
    for i, f in enumerate(files):
        inf = info[i]
        fields = metas[f]["fields"]
        g = groups[labels_global[i]]
        rows.append({
            "i": i, "name": f.name, "rel": relative_label(f, roots), "path": str(f), "uri": file_uri(f),
            "dur": round(feats[i]["duration_s"], 2), "bucket": inf["bucket"], "src": inf["src"],
            "cat": inf["entry"].label, "catid": inf["entry"].catid,
            "ai": [[e.label, e.catid, round(p, 3)] for e, p in inf["ai"]],
            "desc": fields.get("description", ""), "kw": fields.get("keywords", ""),
            "group": int(labels_global[i]), "group_name": g["name"],
            "x": round(float(coords[i, 0]), 4), "y": round(float(coords[i, 1]), 4),
            "nn": [[int(j), round(float(s), 3)] for j, s in zip(nn_idx[i], nn_sim[i])],
        })
    buckets = []
    for bucket, idx in sorted(by_bucket.items(), key=lambda kv: -len(kv[1])):
        buckets.append({"id": bucket, "label": info[idx[0]]["bucket_label"], "n": len(idx),
                        "ai_n": sum(1 for i in idx if info[i]["src"] == "ai"),
                        "groups": [g["id"] for g in groups if g["bucket"] == bucket]})

    with open(out / "groups.csv", "w", newline="", encoding="utf-8") as fh:
        wr = csv.writer(fh)
        wr.writerow(["path", "category", "catid", "category_source", "ai_category", "ai_confidence",
                     "group_id", "group_name", "duration_s", "map_x", "map_y"])
        for r in rows:
            wr.writerow([r["path"], r["cat"], r["catid"], r["src"], r["ai"][0][0], r["ai"][0][2],
                         r["group"], r["group_name"], r["dur"], r["x"], r["y"]])
    settings = {k: (str(v) if isinstance(v, Path) else v) for k, v in vars(args).items() if k != "folders"}
    settings["shape_weight"] = shape_w
    payload = {
        "version": 1, "tool": "group_sounds.py", "model": args.model, "created": R.timestamp(),
        "settings": settings, "roots": [str(r) for r in roots], "buckets": buckets, "groups": groups,
        "files": rows, "errors": {str(k): v for k, v in errors.items()},
    }
    (out / "groups.json").write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

    html_path = out / "groups_report.html"
    R.write_and_open(html_path, render_html(payload, time.time() - t0), open_it=not args.no_open)
    n_real = sum(1 for g in groups if not g["leftover"])
    print(f"\nDone in {time.time() - t0:.0f}s. {len(files)} sounds, {len(buckets)} categories, {n_real} groups.")
    if errors:
        print(f"{len(errors)} files could not be analysed (listed in the report).")
    print(f"Report: {html_path}")


# ---------------------------------------------------------------- HTML

APP_JS = r"""
const D = DATA; const files = D.files; const groups = D.groups;
const palette = ['#d1495b','#2e86ab','#3c9d5d','#edae49','#8e5ac8','#00a6a6','#e07a5f','#5d6d7e','#c2185b',
  '#6a994e','#bc6c25','#4361ee','#9d4edd','#f28482','#2a9d8f','#e9c46a'];
function colorFor(g){ const gr = groups[g]; if (!gr || gr.leftover) return '#9a9a9a';
  const local = D.buckets.find(b=>b.id===gr.bucket).groups.filter(x=>!groups[x].leftover).indexOf(g);
  return palette[local % palette.length]; }
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let current = null;
function renderBuckets(filter=''){
  const el = document.getElementById('buckets'); const f = filter.toLowerCase();
  el.innerHTML = D.buckets.filter(b => !f || b.label.toLowerCase().includes(f) || b.id.toLowerCase().includes(f))
    .map(b => `<div class="bk ${current===b.id?'sel':''}" onclick="selectBucket('${esc(b.id)}')">
      <span>${esc(b.label)}</span><span class="muted">${b.n}${b.ai_n?` <span class="chip ai" title="category suggested by AI">${b.ai_n} AI</span>`:''}</span></div>`).join('');
}
function fileRow(i, extra=''){
  const f = files[i]; const ai = f.src==='ai' ? `<span class="chip ai" title="AI suggestion: ${esc(f.ai.map(a=>a[0]+' '+Math.round(a[2]*100)+'%').join(', '))}">AI ${Math.round(f.ai[0][2]*100)}%</span>` : '';
  return `<tr id="f${i}"><td><button class="play" onclick="playFile(this, ${esc(JSON.stringify(f.uri))})">▶</button></td>
    <td><div class="mono">${esc(f.name)}</div><div class="muted small">${esc(f.desc).slice(0,160)}</div></td>
    <td class="muted">${f.dur}s</td><td>${ai}${extra}</td>
    <td><button class="sim" onclick="showSimilar(${i})" title="find similar sounds">≈</button></td></tr>`;
}
function selectBucket(id){
  current = id; renderBuckets(document.getElementById('bsearch').value);
  const b = D.buckets.find(x=>x.id===id);
  document.getElementById('btitle').textContent = `${b.label} — ${b.n} sounds, ${b.groups.filter(g=>!groups[g].leftover).length} groups`;
  const gl = b.groups.map(g => groups[g]).sort((a,b2)=> (a.leftover-b2.leftover) || (b2.members.length-a.members.length));
  document.getElementById('groups').innerHTML = gl.map(g => `<div class="group"><div class="gh"><span class="dot" style="background:${colorFor(g.id)}"></span>
      <h3>${esc(g.name)}</h3><span class="muted">${g.members.length} sounds</span></div>
      <div>${g.ai_words.map(w=>`<span class="chip ai" title="AI description">${esc(w)}</span>`).join('')}
      ${g.shape_words.map(w=>`<span class="chip" title="from length/brightness/envelope">${esc(w)}</span>`).join('')}
      ${g.keywords.map(w=>`<span class="chip kw" title="from vendor metadata">#${esc(w)}</span>`).join('')}</div>
      <details ${gl.length<=3?'open':''}><summary>Show sounds</summary><table><tbody>${g.members.map(i=>fileRow(i)).join('')}</tbody></table></details></div>`).join('');
  drawMap();
}
const cv = document.getElementById('map'); const ctx = cv.getContext('2d'); let pts = [];
function drawMap(){
  const dpr = window.devicePixelRatio || 1; const w = cv.clientWidth, h = cv.clientHeight;
  cv.width = w*dpr; cv.height = h*dpr; ctx.setTransform(dpr,0,0,dpr,0,0); ctx.clearRect(0,0,w,h);
  const b = D.buckets.find(x=>x.id===current); if (!b) return;
  const idx = b.groups.flatMap(g=>groups[g].members); const pad = 18;
  pts = idx.map(i => ({i, x: pad + files[i].x*(w-2*pad), y: pad + files[i].y*(h-2*pad)}));
  for (const p of pts){ ctx.beginPath(); ctx.arc(p.x, p.y, 5, 0, 7); ctx.fillStyle = colorFor(files[p.i].group);
    ctx.globalAlpha = 0.85; ctx.fill(); ctx.globalAlpha = 1; }
}
function nearestPt(e){ const r = cv.getBoundingClientRect(); const x = e.clientX-r.left, y = e.clientY-r.top;
  let best=null, bd=144; for (const p of pts){ const d=(p.x-x)**2+(p.y-y)**2; if (d<bd){bd=d;best=p;} } return best; }
const tip = document.getElementById('tip');
cv.addEventListener('mousemove', e => { const p = nearestPt(e); if (!p){ tip.style.display='none'; cv.style.cursor='default'; return; }
  const f = files[p.i]; tip.style.display='block'; tip.style.left=(e.pageX+12)+'px'; tip.style.top=(e.pageY+12)+'px';
  tip.innerHTML = `<b>${esc(f.name)}</b><br>${esc(groups[f.group].name)} · ${f.dur}s`; cv.style.cursor='pointer'; });
cv.addEventListener('mouseleave', ()=> tip.style.display='none');
const mapBtn = document.createElement('button');
cv.addEventListener('click', e => { const p = nearestPt(e); if (p){ playFile(mapBtn, files[p.i].uri); showSimilar(p.i); } });
function showSimilar(i){
  const f = files[i]; const panel = document.getElementById('similar');
  panel.innerHTML = `<h3>Similar to <span class="mono">${esc(f.name)}</span></h3><p class="muted">Closest sounds across everything analysed (texture + shape).</p>
    <table><tbody>${fileRow(i, ' <span class="chip">this one</span>')}${f.nn.map(([j,s]) => fileRow(j, ` <span class="chip" title="similarity">${Math.round(s*100)}%</span> <span class="muted small">${esc(files[j].cat)}</span>`)).join('')}</tbody></table>`;
  panel.scrollIntoView({behavior:'smooth', block:'nearest'});
}
document.getElementById('bsearch').addEventListener('input', e => renderBuckets(e.target.value));
window.addEventListener('resize', drawMap);
renderBuckets(); if (D.buckets.length) selectBucket(D.buckets[0].id);
"""

APP_CSS = """
.layout{display:grid;grid-template-columns:260px 1fr;gap:16px;align-items:start}
@media (max-width:800px){.layout{grid-template-columns:1fr}}
.side{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:8px;max-height:80vh;overflow:auto;position:sticky;top:8px}
.side input{width:100%;margin-bottom:6px}
.bk{display:flex;justify-content:space-between;gap:6px;padding:5px 8px;border-radius:6px;cursor:pointer;font-size:13px}
.bk:hover{background:var(--chip)}.bk.sel{background:var(--accent-soft)}
#map{width:100%;height:380px;background:var(--panel);border:1px solid var(--line);border-radius:10px;display:block}
.group{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin:10px 0}
.gh{display:flex;align-items:center;gap:8px;margin-bottom:4px}.dot{width:12px;height:12px;border-radius:50%;flex:none}
.group table{border:none;margin-top:6px}.small{font-size:12px}
button.sim{border:1px solid var(--line);background:var(--panel);color:var(--text);border-radius:6px;cursor:pointer}
#tip{position:absolute;display:none;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:6px 8px;
font-size:12px;pointer-events:none;box-shadow:0 2px 8px rgba(0,0,0,.15);z-index:9}
#similar{margin-top:14px}.chip.kw{background:transparent;border:1px solid var(--line)}
"""


def render_html(payload: dict, seconds: float) -> str:
    files, groups, buckets = payload["files"], payload["groups"], payload["buckets"]
    n_groups = sum(1 for g in groups if not g["leftover"])
    n_ai = sum(1 for f in files if f["src"] == "ai")
    low = sum(1 for f in files if f["src"] == "ai" and f["ai"][0][2] < 0.5)
    body = [R.cards([
        (f"{len(files):,}", "sounds analysed"), (f"{len(buckets)}", "categories"), (f"{n_groups}", "similarity groups"),
        (f"{n_ai:,}", "categorised by AI"), (payload["model"], "AI model"), (R.fmt_duration(seconds), "analysis time"),
    ])]
    body.append("<div class='note'><b>How to read this:</b> pick a category on the left. The map places similar sounds "
                "close together (colour = group); hover to see names, click a dot to play it and list its closest "
                "matches. <span class='chip ai'>AI</span> marks categories guessed by the AI where the vendor gave none"
                f"{f' ({low} of them with low confidence)' if low else ''}. Nothing in your sound folders was changed.</div>")
    body.append("<div class='layout'><div class='side'><input id='bsearch' type='search' placeholder='Filter categories'>"
                "<div id='buckets'></div></div><div><h2 id='btitle' style='margin-top:0'></h2><canvas id='map'></canvas>"
                "<div id='similar'></div><div id='groups'></div></div></div><div id='tip'></div>")
    if payload["errors"]:
        body.append("<h2>Files that couldn't be analysed</h2><table><tbody>" + "".join(
            f"<tr><td class='mono'>{R.esc(Path(p).name)}</td><td class='muted'>{R.esc(e)}</td></tr>"
            for p, e in list(payload["errors"].items())[:300]) + "</tbody></table>")
    data = json.dumps({"files": files, "groups": groups, "buckets": buckets}, ensure_ascii=False).replace("</", "<\\/")
    scope = {"subcategory": "inside each UCS subcategory", "category": "inside each UCS category",
             "all": "across all sounds"}[payload["settings"]["group_within"]]
    html = R.page("Sound groups", f"model {payload['model']} · grouped {scope}", "\n".join(body),
                  extra_js=f"const DATA = {data};\n{APP_JS}")
    return html.replace("</style>", APP_CSS + "</style>", 1)


if __name__ == "__main__":
    main()
