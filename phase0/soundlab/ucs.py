"""Universal Category System (UCS) v8.2.1 list (public domain), bundled as CSV."""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

UCS_CSV = Path(__file__).resolve().parent.parent / "data" / "ucs_v8.2.1.csv"


@dataclass(frozen=True)
class UCSEntry:
    category: str
    subcategory: str
    catid: str
    catshort: str
    explanation: str
    synonyms: tuple[str, ...]

    @property
    def label(self) -> str:
        return f"{self.category} / {self.subcategory}"


@lru_cache(maxsize=1)
def load_ucs() -> dict[str, UCSEntry]:
    """CatID (lowercase) -> entry."""
    entries = {}
    with open(UCS_CSV, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            syn = tuple(s.strip() for s in row["Synonyms"].split(",") if s.strip())
            e = UCSEntry(row["Category"], row["SubCategory"], row["CatID"], row["CatShort"],
                         row["Explanation"], syn)
            entries[e.catid.lower()] = e
    return entries


@lru_cache(maxsize=1)
def categories() -> dict[str, list[UCSEntry]]:
    out: dict[str, list[UCSEntry]] = {}
    for e in load_ucs().values():
        out.setdefault(e.category, []).append(e)
    return out


def lookup_catid(value: str | None) -> UCSEntry | None:
    if not value:
        return None
    return load_ucs().get(value.strip().lower())


def lookup_category(category: str | None, subcategory: str | None) -> UCSEntry | None:
    """Match free-text Category/SubCategory fields against UCS."""
    if not category:
        return None
    cat = category.strip().upper()
    sub = (subcategory or "").strip().upper()
    if "-" in cat and not sub:  # "WHOOSHES-WHOOSH" style CategoryFull
        cat, sub = (p.strip() for p in cat.split("-", 1))
    for e in categories().get(cat, []):
        if e.subcategory.upper() == sub:
            return e
    return None


_SPLIT = re.compile(r"_")


def parse_ucs_filename(stem: str) -> dict | None:
    """UCS filenames: CatID_FXName_CreatorID_SourceID[_UserData].
    Returns None when the first part isn't a known CatID."""
    parts = _SPLIT.split(stem)
    if len(parts) < 2:
        return None
    first = parts[0]
    # UCS allows a user category suffix after a dash: "WHSH-Mine"
    catid = first.split("-", 1)[0]
    entry = lookup_catid(catid)
    # Accept the exact CatID ("AMBForst") or an all-caps variant ("AMBFORST"),
    # but not ordinary words that happen to match ("rain_01.wav").
    if entry is None or not (catid == entry.catid or catid.isupper()):
        return None
    out = {"catid": entry.catid, "category": entry.category, "subcategory": entry.subcategory}
    if len(parts) > 1:
        out["fxname"] = parts[1].strip()
    if len(parts) > 2:
        out["creator_id"] = parts[2].strip()
    if len(parts) > 3:
        out["source_id"] = parts[3].strip()
    if len(parts) > 4:
        out["user_data"] = "_".join(parts[4:]).strip()
    return out
