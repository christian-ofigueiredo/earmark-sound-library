#!/usr/bin/env python3
"""Show what metadata your sound packs already contain.

Reads the WAV/AIFF/MP3/... headers (BWF bext, iXML incl. Soundminer USER
fields, RIFF INFO, ID3, XMP, ACID/smpl loop info), UCS-style filenames, and
vendor spreadsheets. Never modifies anything in the sound folders.

Example:
    python inspect_metadata.py "/Volumes/SFX/BOOM Library" "/Volumes/SFX/Other Pack"
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from tqdm import tqdm

from soundlab import report as R
from soundlab.audio import DEFAULT_OUTPUT_ROOT, ensure_output_outside_inputs, file_uri, find_audio_files
from soundlab.metadata import NORMALIZED_FIELDS, extract, find_vendor_docs, match_sheet

FIELD_LABELS = {
    "description": "Description", "fxname": "FX name / title", "category": "Category",
    "subcategory": "Subcategory", "catid": "UCS CatID", "keywords": "Keywords", "library": "Library",
    "manufacturer": "Manufacturer", "designer": "Designer", "notes": "Notes", "bpm": "BPM", "key": "Key",
}


def short_source(source: str) -> str:
    """'iXML BWFXML/USER/DESCRIPTION' -> 'iXML USER'; "folder name 'X'" -> 'folder name'."""
    if source.startswith("iXML ") and "/" in source:
        parts = source[5:].split("/")
        return "iXML " + (parts[1] if len(parts) > 2 else parts[0])
    if source.startswith("folder name"):
        return "folder name"
    return source


def pack_of(path: Path, roots: list[Path]) -> str:
    """The first folder level under the input folder, e.g. the pack name."""
    for r in roots:
        try:
            rel = path.relative_to(r)
        except ValueError:
            continue
        return rel.parts[0] if len(rel.parts) > 1 else r.name
    return path.parent.name


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folders", nargs="+", type=Path, help="sound folders or files to inspect")
    ap.add_argument("--out", type=Path, default=None, help="where to write the report (default ~/SoundLab/metadata-<time>)")
    ap.add_argument("--no-open", action="store_true", help="don't open the report when done")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    roots = [p.expanduser().resolve() for p in args.folders]
    out = ensure_output_outside_inputs(args.out or DEFAULT_OUTPUT_ROOT / f"metadata-{R.timestamp()}", roots)

    print("Finding audio files…")
    files = find_audio_files(roots)
    if not files:
        sys.exit("No audio files found.")
    print(f"{len(files)} files. Reading headers (read-only)…")

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        records = list(tqdm(pool.map(extract, files), total=len(files), unit="file"))

    # Vendor documents and spreadsheets, per input folder.
    print("Looking for vendor spreadsheets and documents…")
    docs_info = []
    sheet_values: dict[str, dict] = {}
    for r in roots:
        if not r.is_dir():
            continue
        r_files = [f for f in files if r in f.parents]
        for d in find_vendor_docs(r):
            info = {"doc": str(d), "match": None}
            if d.suffix.lower() in (".csv", ".tsv", ".txt", ".xlsx"):
                m = match_sheet(d, r_files)
                if m:
                    info["match"] = {k: v for k, v in m.items() if k != "rows"}
                    for name, vals in m["rows"].items():
                        sheet_values.setdefault(name, {}).update(vals)
            docs_info.append(info)

    rows = []
    for path, rec in zip(files, records):
        fields = dict(rec["fields"])
        sources = dict(rec["sources"])
        for k, v in sheet_values.get(path.name.lower(), {}).items():
            if k not in fields and v:
                fields[k] = v
                sources[k] = "vendor spreadsheet"
        rows.append({"path": path, "pack": pack_of(path, roots), "rec": rec, "fields": fields, "sources": sources})

    # ---------------------------------------------------------------- machine-readable output
    with open(out / "metadata.jsonl", "w", encoding="utf-8") as f:
        for row in rows:
            rec = row["rec"]
            f.write(json.dumps({
                "path": str(row["path"]), "pack": row["pack"], "fields": row["fields"], "sources": row["sources"],
                "ucs": rec["ucs"], "technical": rec["raw"].get("technical"), "chunks": rec["raw"].get("chunks"),
                "raw": rec["raw"].get("fields"), "warnings": rec["raw"].get("warnings"),
            }, ensure_ascii=False, default=str) + "\n")
    with open(out / "metadata.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["path", "pack", *NORMALIZED_FIELDS, "duration_s", "samplerate", "channels", "bits"])
        for row in rows:
            t = row["rec"]["raw"].get("technical") or {}
            w.writerow([str(row["path"]), row["pack"], *[row["fields"].get(k, "") for k in NORMALIZED_FIELDS],
                        t.get("Duration"), t.get("SampleRate"), t.get("Channels"), t.get("BitsPerSample")])

    # ---------------------------------------------------------------- statistics
    n = len(rows)
    coverage = {k: sum(1 for r in rows if r["fields"].get(k)) for k in NORMALIZED_FIELDS}
    source_counts = {k: Counter(short_source(r["sources"][k]) for r in rows if k in r["sources"])
                     for k in NORMALIZED_FIELDS}
    ucs_count = sum(1 for r in rows if r["rec"]["ucs"])
    ucs_sources = Counter(short_source(r["rec"]["ucs"]["source"] or "") for r in rows if r["rec"]["ucs"])
    total_dur = sum((r["rec"]["raw"].get("technical") or {}).get("Duration") or 0 for r in rows)
    chunk_counts = Counter(c["id"] for r in rows for c in r["rec"]["raw"].get("chunks", []))
    ixml_paths = Counter()
    ixml_examples = {}
    other_examples = {}
    for r in rows:
        raw = r["rec"]["raw"].get("fields", {})
        for group in ("iXML", "XMP", "INFO", "ID3", "tags", "AIFF", "acid", "smpl", "other_chunks"):
            for k, v in (raw.get(group) or {}).items():
                key = f"{group}: {k}"
                ixml_paths[key] += 1
                if key not in ixml_examples:
                    ixml_examples[key] = str(v)[:160]
        for k, v in (raw.get("bext") or {}).items():
            key = f"bext: {k}"
            ixml_paths[key] += 1
            ixml_examples.setdefault(key, str(v)[:160])
        for k, v in (raw.get("other_chunks") or {}).items():
            other_examples.setdefault(k, v)
    fmt_counts = Counter()
    for r in rows:
        t = r["rec"]["raw"].get("technical") or {}
        if t.get("SampleRate"):
            sr = t["SampleRate"]
            fmt_counts[f"{sr / 1000:g} kHz · {t.get('BitsPerSample') or '?'}-bit · {t.get('Channels') or '?'} ch"] += 1
    warnings = Counter(w.split(" (")[0] for r in rows for w in r["rec"]["raw"].get("warnings", []))
    cat_counts = Counter(r["rec"]["ucs"]["category"] for r in rows if r["rec"]["ucs"])
    catid_counts = Counter(f'{r["rec"]["ucs"]["category"]} / {r["rec"]["ucs"]["subcategory"]}'
                           for r in rows if r["rec"]["ucs"])
    by_pack = defaultdict(list)
    for r in rows:
        by_pack[r["pack"]].append(r)

    # ---------------------------------------------------------------- HTML
    body = [R.cards([
        (f"{n:,}", "audio files"),
        (R.fmt_duration(total_dur), "total duration"),
        (f"{ucs_count / n:.0%}", "have a UCS category"),
        (f"{coverage['description'] / n:.0%}", "have a description"),
        (f"{coverage['keywords'] / n:.0%}", "have keywords"),
        (f"{len(by_pack)}", "packs / top folders"),
    ])]
    body.append('<div class="note">Nothing in your sound folders was changed. This report and the CSV/JSON files are in '
                f'<span class="mono">{R.esc(out)}</span>.</div>')

    body.append("<h2>What's filled in</h2><table><thead><tr><th>Field</th><th>Files</th><th></th>"
                "<th>Where it comes from</th></tr></thead><tbody>")
    for k in NORMALIZED_FIELDS:
        srcs = ", ".join(f"{R.esc(s)} ({c:,})" for s, c in source_counts[k].most_common(4))
        body.append(f"<tr><td>{FIELD_LABELS[k]}</td><td>{coverage[k]:,}</td><td>{R.bar(coverage[k] / n)}</td>"
                    f"<td class='muted'>{srcs}</td></tr>")
    body.append("</tbody></table>")
    if ucs_sources:
        body.append("<p class='muted'>UCS category found via: " +
                    ", ".join(f"{R.esc(s)} ({c:,})" for s, c in ucs_sources.most_common()) + "</p>")

    body.append("<h2>By pack</h2><div class='scroll'><table><thead><tr><th class='sortable' onclick='sortTable(this)'>Pack</th>"
                "<th class='sortable' onclick='sortTable(this)'>Files</th>" +
                "".join(f"<th class='sortable' onclick='sortTable(this)'>{FIELD_LABELS[k]}</th>"
                        for k in ("description", "catid", "keywords", "fxname", "library", "manufacturer")) +
                "</tr></thead><tbody>")
    for pack, prs in sorted(by_pack.items(), key=lambda kv: -len(kv[1])):
        m = len(prs)
        cells = []
        for k in ("description", "catid", "keywords", "fxname", "library", "manufacturer"):
            c = sum(1 for r in prs if r["fields"].get(k))
            cls = "good" if c / m > 0.9 else "warn" if c / m > 0.3 else "bad"
            cells.append(f"<td data-v='{c / m:.3f}' class='{cls}'>{c / m:.0%}</td>")
        body.append(f"<tr><td>{R.esc(pack)}</td><td data-v='{m}'>{m:,}</td>{''.join(cells)}</tr>")
    body.append("</tbody></table></div>")

    if cat_counts:
        body.append("<h2>UCS categories</h2><div class='scroll'><table><thead><tr><th>Category / Subcategory</th>"
                    "<th>Files</th><th></th></tr></thead><tbody>")
        top = catid_counts.most_common(60)
        mx = top[0][1]
        for name, c in top:
            body.append(f"<tr><td>{R.esc(name)}</td><td>{c:,}</td><td>{R.bar(c / mx)}</td></tr>")
        body.append("</tbody></table></div>")
        if len(catid_counts) > 60:
            body.append(f"<p class='muted'>…and {len(catid_counts) - 60} more subcategories (see metadata.csv).</p>")

    body.append("<h2>Formats</h2><table><tbody>" + "".join(
        f"<tr><td>{R.esc(k)}</td><td>{c:,}</td></tr>" for k, c in fmt_counts.most_common(20)) + "</tbody></table>")

    body.append("<h2>Every raw field found</h2><p class='muted'>This is what the app's importer needs to read. "
                "Counts are files containing the field.</p><div class='scroll'><table><thead><tr><th>Field</th>"
                "<th>Files</th><th>Example</th></tr></thead><tbody>")
    for key, c in sorted(ixml_paths.items(), key=lambda kv: (-kv[1], kv[0]))[:400]:
        body.append(f"<tr><td class='mono'>{R.esc(key)}</td><td>{c:,}</td><td class='muted'>{R.esc(ixml_examples[key])}</td></tr>")
    body.append("</tbody></table></div>")
    body.append("<h3 style='margin-top:14px'>Chunk types</h3><p class='mono'>" +
                ", ".join(f"{R.esc(k)} ({c:,})" for k, c in chunk_counts.most_common()) + "</p>")

    if docs_info:
        body.append("<h2>Vendor documents</h2><table><thead><tr><th>File</th><th>Lists the audio files?</th></tr></thead><tbody>")
        for d in docs_info[:200]:
            m = d["match"]
            desc = (f"<span class='good'>yes</span> — {m['match_rate']:.0%} of rows match by column "
                    f"'{R.esc(m['filename_column'])}'; columns used: {R.esc(', '.join(f'{k}←{v}' for k, v in m['mapped_columns'].items()) or 'none recognised')}"
                    if m else "<span class='muted'>no</span>")
            body.append(f"<tr><td class='mono'>{R.esc(Path(d['doc']).name)}</td><td>{desc}</td></tr>")
        body.append("</tbody></table>")

    if warnings:
        body.append("<h2>Warnings</h2><table><tbody>" + "".join(
            f"<tr><td>{R.esc(w)}</td><td>{c:,}</td></tr>" for w, c in warnings.most_common(30)) + "</tbody></table>")

    body.append("<h2>Sample files</h2><div class='scroll'><table><thead><tr><th></th><th>File</th><th>Category</th>"
                "<th>Description</th><th>Keywords</th></tr></thead><tbody>")
    step = max(1, n // 80)
    for r in rows[::step][:80]:
        f = r["fields"]
        ucsinfo = r["rec"]["ucs"]
        cat = f"{ucsinfo['category']} / {ucsinfo['subcategory']}" if ucsinfo else f.get("category", "")
        body.append(f"<tr><td>{R.play_button(file_uri(r['path']))}</td><td class='mono'>{R.esc(r['path'].name)}</td>"
                    f"<td>{R.esc(cat)}</td><td>{R.esc(f.get('description', ''))[:300]}</td>"
                    f"<td class='muted'>{R.esc(f.get('keywords', ''))[:200]}</td></tr>")
    body.append("</tbody></table></div>")

    html_path = out / "metadata_report.html"
    R.write_and_open(html_path, R.page("Sound library metadata", f"{n:,} files in {len(roots)} folder(s)",
                                       "\n".join(body)), open_it=not args.no_open)
    print(f"\nDone. Report: {html_path}\nData: {out / 'metadata.csv'} and metadata.jsonl")
    print(f"UCS category found for {ucs_count:,} of {n:,} files ({ucs_count / n:.0%}); "
          f"description for {coverage['description'] / n:.0%}.")


if __name__ == "__main__":
    main()
