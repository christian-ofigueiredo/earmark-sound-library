"""Zero-shot UCS categories: compare a sound's embedding with text
descriptions of all 753 UCS subcategories."""

from __future__ import annotations

import numpy as np

from . import ucs

UCS_TEXT_TAG = "ucs-v8.2.1-p1"


def ucs_prompts() -> tuple[list, list[list[str]]]:
    """Entries and several phrasings per subcategory (averaged later)."""
    entries = list(ucs.load_ucs().values())
    prompts = []
    for e in entries:
        sub, cat = e.subcategory.lower(), e.category.lower()
        expl = e.explanation.split(".")[0].strip()
        syn = ", ".join(s.lower() for s in e.synonyms[:6])
        ps = [f"{sub} {cat}", f"the sound of {sub}, {cat}", f"{cat} sound effect: {syn}"]
        if expl:
            ps.append(expl)
        prompts.append(ps)
    return entries, prompts


def softmax(x: np.ndarray, t: float = 0.01) -> np.ndarray:
    z = (x - x.max(axis=-1, keepdims=True)) / t
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)
