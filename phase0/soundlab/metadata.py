"""Turn raw chunks/tags into one normalized record per file.

Commercial packs (BOOM, etc.) usually embed Soundminer-style fields in iXML
(USER section), a BWF 'bext' description, and/or UCS-style filenames. This
module merges all of those, remembering where each value came from.
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

from . import ucs
from .riff import read_file_metadata

NORMALIZED_FIELDS = [
    "description", "fxname", "category", "subcategory", "catid", "keywords",
    "library", "manufacturer", "designer", "notes", "bpm", "key",
]

# iXML leaf names (case-insensitive), most specific first.
IXML_NAMES = {
    "description": ["DESCRIPTION", "BWF_DESCRIPTION", "NOTE"],
    "fxname": ["FXNAME", "TRACKTITLE", "TITLE"],
    "category": ["CATEGORY"],
    "subcategory": ["SUBCATEGORY"],
    "catid": ["CATID"],
    "categoryfull": ["CATEGORYFULL"],
    "keywords": ["KEYWORDS"],
    "library": ["LIBRARY", "SHOW", "PROJECT"],
    "manufacturer": ["MANUFACTURER", "VENDOR", "BWF_ORIGINATOR", "ORIGINATOR"],
    "designer": ["DESIGNER", "CREATORID", "RECORDIST"],
    "notes": ["NOTES"],
    "bpm": ["BPM", "TEMPO"],
    "key": ["KEY", "MUSICALKEY", "INITIALKEY"],
}
# Preferred iXML sections when the same leaf name appears more than once.
IXML_SECTION_ORDER = ["USER", "ASWG", "STEINBERG", "BEXT", ""]

GENERIC_TAG_NAMES = {
    "description": ["comment", "comm", "©cmt", "description", "tit3", "desc"],
    "fxname": ["title", "tit2", "©nam"],
    "keywords": ["keywords", "tags"],
    "library": ["album", "talb", "©alb"],
    "manufacturer": ["publisher", "tpub", "label", "organization"],
    "designer": ["artist", "tpe1", "©art", "composer", "tcom", "©wrt"],
    "category": ["genre", "tcon", "©gen"],
    "bpm": ["bpm", "tbpm", "tmpo"],
    "key": ["initialkey", "tkey", "key"],
}


def _ixml_find(ixml: dict, names: list[str]) -> tuple[str, str] | None:
    if not ixml:
        return None
    for name in names:
        hits = [(k, v) for k, v in ixml.items()
                if "@" not in k and k.split("/")[-1].upper() == name and v.strip()]
        if not hits:
            continue
        for section in IXML_SECTION_ORDER:
            for k, v in hits:
                parts = [p.upper() for p in k.split("/")[:-1]]
                if not section or section in parts:
                    return v, k
    return None


def _tag_key(k: str) -> str:
    k = k.lower()
    k = k.split(":")[-1] if k.startswith("----:") else k  # MP4 freeform
    k = k.split("::")[0]  # ID3 COMM::eng
    if k.startswith("txxx:"):
        k = k[5:]
    if k.startswith("comm"):
        k = "comm"
    return k


def _generic_find(tags: dict, names: list[str]) -> tuple[str, str] | None:
    if not tags:
        return None
    norm = {}
    for k, v in tags.items():
        norm.setdefault(_tag_key(k), (v, k))
    for n in names:
        if n in norm and str(norm[n][0]).strip():
            return str(norm[n][0]).strip(), norm[n][1]
    return None


def normalize(raw: dict, path: Path) -> dict:
    """Return {'fields': {...}, 'sources': {...}, 'ucs': {...}|None}."""
    fields: dict[str, str] = {}
    sources: dict[str, str] = {}

    def put(name: str, value, source: str):
        if value is None:
            return
        value = str(value).strip()
        if value and name not in fields:
            fields[name] = value
            sources[name] = source

    f = raw.get("fields", {})
    ixml = f.get("iXML", {})
    for name, cands in IXML_NAMES.items():
        hit = _ixml_find(ixml, cands)
        if hit:
            put(name, hit[0], f"iXML {hit[1]}")

    bext = f.get("bext", {})
    put("description", bext.get("Description"), "bext Description")
    put("manufacturer", bext.get("Originator"), "bext Originator")

    xmp = f.get("XMP", {})
    if xmp:
        for k, v in xmp.items():
            leaf = k.split("/")[-1].lower()
            if leaf == "description" or k.endswith("description/Alt/li"):
                put("description", v, f"XMP {k}")
            elif k.endswith("title/Alt/li"):
                put("fxname", v, f"XMP {k}")
            elif k.endswith("subject/Bag/li"):
                put("keywords", v.replace(" | ", ", "), f"XMP {k}")
            elif leaf in ("tempo",):
                put("bpm", v, f"XMP {k}")
            elif leaf in ("key",):
                put("key", v, f"XMP {k}")

    info = f.get("INFO", {})
    put("fxname", info.get("Title"), "INFO INAM")
    put("description", info.get("Comment") or info.get("Subject"), "INFO ICMT/ISBJ")
    put("keywords", info.get("Keywords"), "INFO IKEY")
    put("library", info.get("Product"), "INFO IPRD")
    put("designer", info.get("Artist") or info.get("Engineer"), "INFO IART/IENG")
    put("category", info.get("Genre"), "INFO IGNR")

    acid = f.get("acid", {})
    if acid.get("Tempo") and not acid.get("OneShot"):
        put("bpm", acid["Tempo"], "acid chunk")

    for group in ("ID3", "tags"):
        tags = f.get(group, {})
        for name, cands in GENERIC_TAG_NAMES.items():
            hit = _generic_find(tags, cands)
            if hit:
                put(name, hit[0], f"{group} {hit[1]}")

    aiff = f.get("AIFF", {})
    put("fxname", aiff.get("Title"), "AIFF NAME")
    put("description", aiff.get("Annotation") or aiff.get("Comments"), "AIFF ANNO/COMT")
    put("designer", aiff.get("Author"), "AIFF AUTH")

    # UCS: explicit CatID, then Category/SubCategory text, then filename, then folder names.
    entry = ucs.lookup_catid(fields.get("catid"))
    ucs_source = sources.get("catid") if entry else None
    if entry is None:
        entry = ucs.lookup_category(fields.get("category") or fields.get("categoryfull"),
                                    fields.get("subcategory"))
        ucs_source = sources.get("category") if entry else None
    parsed = ucs.parse_ucs_filename(Path(path).stem)
    if parsed:
        put("fxname", parsed.get("fxname"), "UCS filename")
        put("designer", parsed.get("creator_id"), "UCS filename")
        put("library", parsed.get("source_id"), "UCS filename")
        if entry is None:
            entry = ucs.lookup_catid(parsed["catid"])
            ucs_source = "UCS filename"
    if entry is None:
        # Folder names only count when they are unmistakably UCS: an exact-case
        # CatID ("WHSH", "AMBForst") or "CATEGORY-SUBCATEGORY" in capitals.
        # Ordinary names like "test" or "Fire" are ignored.
        for parent in list(Path(path).parents)[:3]:
            name = parent.name.strip()
            e = ucs.lookup_catid(name.split("_")[0])
            if e and e.catid == name.split("_")[0]:
                entry, ucs_source = e, f"folder name '{name}'"
                break
            if name.isupper() and "-" in name:
                e = ucs.lookup_category(name, None)
                if e:
                    entry, ucs_source = e, f"folder name '{name}'"
                    break

    ucs_info = None
    if entry is not None:
        ucs_info = {"catid": entry.catid, "category": entry.category,
                    "subcategory": entry.subcategory, "source": ucs_source}
        put("catid", entry.catid, ucs_source)
        put("category", entry.category, ucs_source)
        put("subcategory", entry.subcategory, ucs_source)

    fields.pop("categoryfull", None)
    sources.pop("categoryfull", None)
    return {"fields": fields, "sources": sources, "ucs": ucs_info}


def extract(path: Path) -> dict:
    """Raw + normalized metadata for one file (read-only)."""
    raw = read_file_metadata(path)
    norm = normalize(raw, path)
    return {"raw": raw, **norm}


# ---------------------------------------------------------------- vendor spreadsheets

DOC_EXTS = {".pdf", ".xlsx", ".xls", ".csv", ".tsv", ".txt", ".rtf", ".numbers", ".docx", ".html", ".htm"}

SHEET_HEADER_MAP = {
    "description": ["description", "desc", "bwdescription", "file description"],
    "fxname": ["fxname", "fx name", "title", "track title", "name"],
    "category": ["category"],
    "subcategory": ["subcategory", "sub category", "sub-category"],
    "catid": ["catid", "cat id"],
    "keywords": ["keywords", "keyword", "tags"],
    "library": ["library", "collection"],
    "manufacturer": ["manufacturer", "vendor", "publisher"],
    "designer": ["designer", "sound designer", "recordist"],
}


def find_vendor_docs(root: Path) -> list[Path]:
    docs = []
    for p in Path(root).rglob("*"):
        if p.is_file() and p.suffix.lower() in DOC_EXTS and not p.name.startswith("."):
            docs.append(p)
    return sorted(docs)


def _read_table(path: Path, max_rows: int = 200000) -> list[list[str]]:
    ext = path.suffix.lower()
    rows: list[list[str]] = []
    if ext in (".csv", ".tsv", ".txt"):
        raw = path.read_bytes()[:50_000_000]
        text = None
        for enc in ("utf-8-sig", "cp1252", "latin-1"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        if text is None:
            return []
        try:
            dialect = csv.Sniffer().sniff(text[:20000], delimiters=",;\t|")
        except csv.Error:
            dialect = csv.excel_tab if ext == ".tsv" else csv.excel
        for i, r in enumerate(csv.reader(text.splitlines(), dialect)):
            if i >= max_rows:
                break
            rows.append([c.strip() for c in r])
    elif ext == ".xlsx":
        import openpyxl

        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        ws = wb.worksheets[0]
        for i, r in enumerate(ws.iter_rows(values_only=True)):
            if i >= max_rows:
                break
            rows.append(["" if c is None else str(c).strip() for c in r])
        wb.close()
    return rows


def match_sheet(path: Path, audio_files: list[Path]) -> dict | None:
    """If a spreadsheet lists the audio files, return per-file values from it.

    Returns {'doc', 'header', 'filename_column', 'match_rate', 'mapped_columns',
    'rows': {filename_lower: {field: value}}} or None."""
    try:
        rows = _read_table(path)
    except Exception:  # noqa: BLE001
        return None
    if len(rows) < 2:
        return None
    header_i = next((i for i, r in enumerate(rows[:30]) if sum(1 for c in r if c) >= 2), None)
    if header_i is None:
        return None
    header = rows[header_i]
    body = rows[header_i + 1:]
    names = {}
    for a in audio_files:
        names[a.name.lower()] = a
        names[a.stem.lower()] = a
    best = (0.0, None)
    for col in range(len(header)):
        vals = [r[col] for r in body if col < len(r) and r[col]]
        if not vals:
            continue
        hits = sum(1 for v in vals if Path(v.replace("\\", "/")).name.lower() in names)
        rate = hits / len(vals)
        if rate > best[0]:
            best = (rate, col)
    rate, fcol = best
    if fcol is None or rate < 0.3:
        return None
    mapped = {}
    for field, aliases in SHEET_HEADER_MAP.items():
        for ci, h in enumerate(header):
            if re.sub(r"\s+", " ", h.lower()).strip() in aliases and ci != fcol:
                mapped[field] = ci
                break
    per_file = {}
    for r in body:
        if fcol >= len(r) or not r[fcol]:
            continue
        key = Path(r[fcol].replace("\\", "/")).name.lower()
        a = names.get(key)
        if a is None:
            continue
        per_file[a.name.lower()] = {f: r[ci] for f, ci in mapped.items() if ci < len(r) and r[ci]}
    return {
        "doc": str(path),
        "header": header,
        "filename_column": header[fcol] if fcol < len(header) else str(fcol),
        "match_rate": rate,
        "mapped_columns": {f: header[ci] for f, ci in mapped.items()},
        "rows": per_file,
    }
